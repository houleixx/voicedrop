import Foundation
import zlib

enum VolcASRProtocol {
    struct ParsedMessage: Equatable {
        var text: String
        var isFinal: Bool
        var isError: Bool
        var errorCode: UInt32?
        var errorMessage: String?
    }

    private static let protocolVersion: UInt8 = 0b0001
    private static let defaultHeaderSize: UInt8 = 0b0001
    private static let fullClient: UInt8 = 0b0001
    private static let audioOnly: UInt8 = 0b0010
    private static let fullServer: UInt8 = 0b1001
    private static let errorResponse: UInt8 = 0b1111
    private static let positiveSequence: UInt8 = 0b0001
    private static let negativeSequence: UInt8 = 0b0011
    private static let jsonSerialization: UInt8 = 0b0001
    private static let noSerialization: UInt8 = 0b0000
    private static let gzipCompression: UInt8 = 0b0001

    static func buildFullClientPayload(appUserID: String, sampleRate: Int) -> Data {
        let payload: [String: Any] = [
            "user": ["uid": appUserID],
            "audio": [
                "format": "pcm",
                "rate": sampleRate,
                "bits": 16,
                "channel": 1,
                "codec": "raw",
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_punc": true,
                "enable_itn": true,
                "show_utterances": true,
            ],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return frame(
            messageType: fullClient,
            flags: positiveSequence,
            serialization: jsonSerialization,
            compression: gzipCompression,
            sequence: 1,
            payload: gzip(json)
        )
    }

    static func buildAudioPayload(_ pcm: Data, sequence: Int32, isLast: Bool) -> Data {
        frame(
            messageType: audioOnly,
            flags: isLast ? negativeSequence : positiveSequence,
            serialization: noSerialization,
            compression: gzipCompression,
            sequence: isLast ? -abs(sequence) : abs(sequence),
            payload: gzip(pcm)
        )
    }

    static func parseServerMessage(_ data: Data) throws -> ParsedMessage {
        guard data.count >= 8 else {
            return ParsedMessage(text: "", isFinal: false, isError: true, errorCode: nil, errorMessage: "ASR response too short")
        }

        let messageType = (data[1] >> 4) & 0x0f
        let flags = data[1] & 0x0f
        let serialization = (data[2] >> 4) & 0x0f
        let compression = data[2] & 0x0f

        var offset = 4
        if flags & 0x01 != 0 || flags & 0x02 != 0 {
            guard data.count >= offset + 4 else {
                return ParsedMessage(text: "", isFinal: false, isError: true, errorCode: nil, errorMessage: "ASR response missing sequence")
            }
            offset += 4
        }

        if messageType == errorResponse {
            guard data.count >= offset + 8 else {
                return ParsedMessage(text: "", isFinal: false, isError: true, errorCode: nil, errorMessage: "ASR error response too short")
            }
            let code = readUInt32(data, offset)
            let size = Int(readUInt32(data, offset + 4))
            let bodyStart = offset + 8
            let bodyEnd = min(data.count, bodyStart + size)
            let body = decodeBody(data.subdata(in: bodyStart..<bodyEnd), compression: compression)
            return ParsedMessage(
                text: "",
                isFinal: true,
                isError: true,
                errorCode: code,
                errorMessage: String(data: body, encoding: .utf8)
            )
        }

        guard messageType == fullServer, data.count >= offset + 4 else {
            return ParsedMessage(text: "", isFinal: false, isError: false, errorCode: nil, errorMessage: nil)
        }

        let size = Int(readUInt32(data, offset))
        let bodyStart = offset + 4
        let bodyEnd = min(data.count, bodyStart + size)
        let body = decodeBody(data.subdata(in: bodyStart..<bodyEnd), compression: compression)
        guard serialization == jsonSerialization,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ParsedMessage(text: "", isFinal: flags & 0x02 != 0, isError: false, errorCode: nil, errorMessage: nil)
        }

        let result = obj["result"] as? [String: Any]
        let text = (result?["text"] as? String)
            ?? ((result?["utterances"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        return ParsedMessage(text: text, isFinal: flags & 0x02 != 0, isError: false, errorCode: nil, errorMessage: nil)
    }

    static func int32Bytes(_ value: Int32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: MemoryLayout<Int32>.size)
    }

    static func uint32Bytes(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: MemoryLayout<UInt32>.size)
    }

    private static func frame(
        messageType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        compression: UInt8,
        sequence: Int32,
        payload: Data
    ) -> Data {
        var data = Data([
            (protocolVersion << 4) | defaultHeaderSize,
            (messageType << 4) | flags,
            (serialization << 4) | compression,
            0x00,
        ])
        data.append(int32Bytes(sequence))
        data.append(uint32Bytes(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    private static func decodeBody(_ data: Data, compression: UInt8) -> Data {
        compression == gzipCompression ? gunzip(data) : data
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let slice = data[offset..<(offset + 4)]
        return slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func gzip(_ data: Data) -> Data {
        return data.withUnsafeBytes { sourceBuffer in
            var stream = z_stream()
            let outputCapacity = max(64, data.count / 2)
            var output = Data(count: outputCapacity)
            var result = Data()

            let initStatus = deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                MAX_WBITS + 16,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else { return data }
            defer { deflateEnd(&stream) }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: sourceBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                output.withUnsafeMutableBytes { outBuffer in
                    stream.next_out = outBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputCapacity)
                    deflate(&stream, Z_FINISH)
                    let produced = outputCapacity - Int(stream.avail_out)
                    if produced > 0 {
                        result.append(outBuffer.bindMemory(to: UInt8.self).baseAddress!, count: produced)
                    }
                }
            } while stream.avail_out == 0

            return result
        }
    }

    private static func gunzip(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        return data.withUnsafeBytes { sourceBuffer in
            var stream = z_stream()
            let outputCapacity = max(1024, data.count * 4)
            var output = Data(count: outputCapacity)
            var result = Data()

            let initStatus = inflateInit2_(
                &stream,
                MAX_WBITS + 16,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else { return data }
            defer { inflateEnd(&stream) }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: sourceBuffer.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            var status: Int32 = Z_OK
            while status == Z_OK {
                output.withUnsafeMutableBytes { outBuffer in
                    stream.next_out = outBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(outputCapacity)
                    status = inflate(&stream, Z_NO_FLUSH)
                    let produced = outputCapacity - Int(stream.avail_out)
                    if produced > 0 {
                        result.append(outBuffer.bindMemory(to: UInt8.self).baseAddress!, count: produced)
                    }
                }
            }
            return status == Z_STREAM_END ? result : data
        }
    }
}
