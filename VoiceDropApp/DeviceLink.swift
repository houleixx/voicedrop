import Foundation
import CryptoKit

// MARK: - End-to-end crypto for device-link (X25519 -> HKDF-SHA256 -> AES-GCM).
// The server only relays pubkey + the {epk, sealed} blob — never the plaintext token.
enum DeviceLinkCrypto {
    private static let salt = Data("voicedrop-device-link/v1".utf8)
    private static let info = Data("anon-token".utf8)

    // New device: ephemeral keypair; pubB64 is sent in /agent/link/start.
    static func newKeypair() -> (priv: Curve25519.KeyAgreement.PrivateKey, pubB64: String) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return (priv, b64url(priv.publicKey.rawRepresentation))
    }

    // New device: decrypt the blob from the old device into the anon_… token.
    static func decrypt(epkB64: String, sealedB64: String, priv: Curve25519.KeyAgreement.PrivateKey) throws -> String {
        let epk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: b64urlDecode(epkB64))
        let shared = try priv.sharedSecretFromKeyAgreement(with: epk)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(combined: b64urlDecode(sealedB64))
        return String(decoding: try AES.GCM.open(box, using: key), as: UTF8.self)
    }

    // Old device: encrypt its anon_… token to the new device's public key.
    static func encrypt(token: String, toPubB64 pub: String) throws -> (epkB64: String, sealedB64: String) {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let newPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: b64urlDecode(pub))
        let shared = try eph.sharedSecretFromKeyAgreement(with: newPub)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data(token.utf8), using: key)
        return (b64url(eph.publicKey.rawRepresentation), b64url(sealed.combined!))
    }

    // base64url helpers (no padding)
    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func b64urlDecode(_ s: String) -> Data {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t) ?? Data()
    }

    #if DEBUG
    // One-shot round-trip self-check; call from app launch in DEBUG, confirm console, then remove.
    static func selfTest() {
        let (priv, pub) = newKeypair()
        do {
            let (epk, sealed) = try encrypt(token: "anon_roundtrip_demo", toPubB64: pub)
            let out = try decrypt(epkB64: epk, sealedB64: sealed, priv: priv)
            print("DeviceLinkCrypto.selfTest:", out == "anon_roundtrip_demo" ? "OK" : "FAIL")
        } catch { print("DeviceLinkCrypto.selfTest ERROR:", error) }
    }
    #endif
}

import SwiftUI

// MARK: - Old-device side: show the 4-digit code, then release the token on link_release.
@MainActor
@Observable
final class DeviceLinkResponder {
    struct Pending: Identifiable { let id = UUID(); let pairingId: String; let code: String; let pubkey: String }
    var pending: Pending?
    var status: String = ""   // transient toast text after release/cancel

    private let base = URL(string: "https://jianshuo.dev/agent/link")!

    func present(pairingId: String, code: String, pubkey: String) {
        pending = Pending(pairingId: pairingId, code: code, pubkey: pubkey)
        status = ""
    }

    // Fired when the new device entered the correct code (server pushed link_release).
    func release(pairingId: String) {
        guard let p = pending, p.pairingId == pairingId else { return }
        Task {
            do {
                let (epk, sealed) = try DeviceLinkCrypto.encrypt(token: AuthStore.shared.anonToken, toPubB64: p.pubkey)
                try await post("complete", body: ["pairingId": pairingId, "blob": ["epk": epk, "sealed": sealed]])
                status = "已在新设备登录"
            } catch {
                status = "登录失败"
            }
            pending = nil
        }
    }

    func cancel() {
        guard let p = pending else { return }
        let pid = p.pairingId
        pending = nil
        Task { try? await post("cancel", body: ["pairingId": pid]) }
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        req.setBearer(AuthStore.shared.bearer)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard resp.isOK else { throw URLError(.badServerResponse) }
    }
}

struct DeviceLinkApprovalSheet: View {
    @Bindable var responder: DeviceLinkResponder
    let pending: DeviceLinkResponder.Pending

    var body: some View {
        VStack(spacing: 22) {
            Text("有新设备想登录你的账号").font(.system(size: 18, weight: .semibold))
            Text("在新设备上输入下面的验证码").font(.system(size: 14)).foregroundStyle(.secondary)
            Text(pending.code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .tracking(8)
            Text("不是你本人操作？点「不是我」。").font(.system(size: 12)).foregroundStyle(.secondary)
            Button(role: .destructive) { responder.cancel() } label: {
                Text("不是我").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
        .presentationDetents([.height(320)])
    }
}

// MARK: - New-device side: enter old account's 6-hex, then the 4-digit code, adopt the token.
@MainActor
@Observable
final class DeviceLinkStore: NSObject, URLSessionWebSocketDelegate {
    enum Phase { case enterId, enterCode, working, done, error }
    var phase: Phase = .enterId
    var message: String = ""

    private let httpBase = URL(string: "https://jianshuo.dev/agent/link")!
    private var priv: Curve25519.KeyAgreement.PrivateKey?
    private var pairingId: String?
    private var ws: URLSessionWebSocketTask?
    private var wsSession: URLSession?

    func reset() { closeSocket(); priv = nil; pairingId = nil; phase = .enterId; message = "" }

    // Step 1: send the 6-hex prefix + ephemeral pubkey; open the wait-socket.
    func start(prefix: String) {
        let hex = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard hex.range(of: "^[0-9a-f]{6}$", options: .regularExpression) != nil else {
            message = "请输入 6 位代码（设置→账户里那串）"; return
        }
        phase = .working; message = ""
        let (p, pub) = DeviceLinkCrypto.newKeypair()
        priv = p
        Task {
            do {
                let r = try await postJSON("start", ["prefix": hex, "pubkey": pub])
                if (r["ok"] as? Bool) != true {
                    message = (r["reason"] as? String) == "no_match" ? "没找到这个账号，确认老设备设置页的 6 位码" : "发起失败"
                    phase = .error; return
                }
                guard let pid = r["pairingId"] as? String else { phase = .error; message = "发起失败"; return }
                pairingId = pid
                openSocket(pairingId: pid)
                phase = .enterCode
            } catch { phase = .error; message = "网络错误" }
        }
    }

    // Step 2: submit the 4-digit code shown on the old device.
    func submit(code: String) {
        guard phase == .enterCode else { return }
        guard let pid = pairingId, code.range(of: "^[0-9]{4}$", options: .regularExpression) != nil else {
            message = "请输入 4 位验证码"; return
        }
        phase = .working; message = ""
        Task {
            do {
                let r = try await postJSON("verify", ["pairingId": pid, "code": code])
                if (r["ok"] as? Bool) == true {
                    message = "正在接收账号…"   // wait for link_ready on the socket
                } else if (r["dead"] as? Bool) == true || (r["expired"] as? Bool) == true {
                    phase = .error; message = "验证已失效，请重新发起"
                } else {
                    let rem = r["remaining"] as? Int ?? 0
                    phase = .enterCode; message = "验证码不对，还可试 \(rem) 次"
                }
            } catch { phase = .error; message = "网络错误" }
        }
    }

    private func openSocket(pairingId: String) {
        var comps = URLComponents(string: "wss://jianshuo.dev/agent/link/socket")!
        comps.queryItems = [URLQueryItem(name: "pairingId", value: pairingId)]
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        wsSession = session
        let task = session.webSocketTask(with: comps.url!)
        ws = task
        task.resume()
        receive()
    }

    private func receive() {
        ws?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(s) }
                    self.receive()
                case .failure(let err):
                    if (err as NSError).code != URLError.cancelled.rawValue {
                        self.phase = .error
                        self.message = "连接断开，请重新发起"
                    }
                }
            }
        }
    }

    private func closeSocket() {
        ws?.cancel()
        ws = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
    }

    private func handle(_ s: String) {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = o["type"] as? String else { return }
        switch type {
        case "link_ready":
            guard let blob = o["blob"] as? [String: Any],
                  let epk = blob["epk"] as? String, let sealed = blob["sealed"] as? String,
                  let priv = self.priv else { phase = .error; message = "解密失败"; return }
            do {
                let token = try DeviceLinkCrypto.decrypt(epkB64: epk, sealedB64: sealed, priv: priv)
                AuthStore.shared.adoptToken(token)
                NotificationCenter.default.post(name: .vdDidAdoptAccount, object: nil)
                phase = .done; message = "登录成功"
                closeSocket()
            } catch { phase = .error; message = "解密失败" }
        case "link_cancelled": phase = .error; message = "对方已拒绝"; closeSocket()
        case "link_expired": phase = .error; message = "已超时，请重新发起"; closeSocket()
        default: break
        }
    }

    private func postJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: httpBase.appending(path: path))
        req.httpMethod = "POST"
        req.setBearer(AuthStore.shared.bearer)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard resp.isOK else { throw URLError(.badServerResponse) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

extension Notification.Name { static let vdDidAdoptAccount = Notification.Name("VDDidAdoptAccount") }

struct DeviceLinkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = DeviceLinkStore()
    @State private var idInput = ""
    @State private var codeInput = ""

    var body: some View {
        VStack(spacing: 20) {
            switch store.phase {
            case .enterId, .working where store.message.isEmpty:
                Text("登录已有账号").font(.system(size: 20, weight: .semibold))
                Text("在老设备「设置 → 账户」看到的 6 位代码").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("6 位代码", text: $idInput)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.system(size: 22, design: .monospaced)).multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                Button("继续") { store.start(prefix: idInput) }.buttonStyle(.borderedProminent)
            case .enterCode:
                Text("输入验证码").font(.system(size: 20, weight: .semibold))
                Text("老设备上弹出的 4 位验证码").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("4 位", text: $codeInput)
                    .keyboardType(.numberPad).font(.system(size: 28, design: .monospaced))
                    .multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                Button("验证") { store.submit(code: codeInput) }.buttonStyle(.borderedProminent)
            case .working:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("登录成功").font(.system(size: 18, weight: .semibold))
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            case .error:
                Image(systemName: "xmark.circle.fill").font(.system(size: 40)).foregroundStyle(.red)
                Button("重试") { codeInput = ""; idInput = ""; store.reset() }.buttonStyle(.bordered)
            }
            if !store.message.isEmpty { Text(store.message).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .padding(28)
        .presentationDetents([.medium])
    }
}
