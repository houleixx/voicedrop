import SwiftUI
import zlib

// MARK: - Phase

enum ExportPhase: Equatable {
    case idle
    case running(completed: Int, total: Int, current: String)
    case zipping
    case done(URL)
    case failed(String)
}

// MARK: - Manager

@MainActor
@Observable
final class ExportManager {
    var phase: ExportPhase = .idle

    func reset() { phase = .idle }

    func export(recordings: [Recording], store: LibraryStore) async {
        guard !recordings.isEmpty else { phase = .failed("没有录音可以导出"); return }
        let total = recordings.count

        let tmpID = UUID().uuidString
        let srcDir     = FileManager.default.temporaryDirectory.appendingPathComponent("vd-src-\(tmpID)")
        let audioDir   = srcDir.appendingPathComponent("audio")
        let readDir    = srcDir.appendingPathComponent("recordings")
        let photosDir  = srcDir.appendingPathComponent("photos")
        do {
            try FileManager.default.createDirectory(at: audioDir,  withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: readDir,   withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        } catch { phase = .failed("创建临时目录失败"); return }

        var docsMap: [(rec: Recording, doc: ArticleDoc?)] = []

        for (i, rec) in recordings.enumerated() {
            phase = .running(completed: i, total: total, current: rec.articleTitle ?? rec.displayTitle)

            if let data = try? await store.downloadData(rec.audioName) {
                try? data.write(to: audioDir.appendingPathComponent("\(rec.stem).m4a"))
            }

            var doc: ArticleDoc? = nil
            if rec.hasArticles {
                doc = await store.fetchDoc(rec)
                if let d = doc {
                    // Download photos the bodies reference (the body is the source
                    // of truth; resolve [[photo:<token>]] → key via ArticleBody).
                    var downloadedPhotoPaths: [String] = []
                    var photoKeys: [String] = []
                    for a in d.resolvedArticles {
                        for seg in ArticleBody.segments(a.body) {
                            if case .photo(let token) = seg,
                               let key = ArticleBody.resolvePhotoKey(token, photos: d.photos ?? []),
                               !photoKeys.contains(key) {
                                photoKeys.append(key)
                            }
                        }
                    }
                    for key in photoKeys {
                        if let data = try? await store.downloadData(key) {
                            // key = "photos/<sessionTs>/<captureTs>.jpg" — preserve sub-path
                            let dest = srcDir.appendingPathComponent(key)
                            try? FileManager.default.createDirectory(
                                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                            if (try? data.write(to: dest)) != nil { downloadedPhotoPaths.append(key) }
                        }
                    }
                    try? recordingHTMLData(rec: rec, doc: d, downloadedPhotos: downloadedPhotoPaths)
                        .write(to: readDir.appendingPathComponent("\(rec.stem).html"))
                }
                if let srt = try? await store.downloadData(rec.srtKey) {
                    try? srt.write(to: readDir.appendingPathComponent("\(rec.stem).srt"))
                }
            }
            docsMap.append((rec: rec, doc: doc))
        }

        try? indexHTMLData(recordings: docsMap).write(to: srcDir.appendingPathComponent("index.html"))

        phase = .zipping

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicedrop-export-\(df.string(from: Date())).zip")
        try? FileManager.default.removeItem(at: zipURL)

        do {
            let src = srcDir, dst = zipURL
            try await Task.detached(priority: .userInitiated) { try writeZip(from: src, to: dst) }.value
            try? FileManager.default.removeItem(at: srcDir)
            phase = .done(zipURL)
        } catch {
            phase = .failed("打包失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - ZIP writer (Store / no compression)

private extension Data {
    mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }
    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
}

private func crc32Of(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { raw in
        guard let p = raw.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return 0 }
        return UInt32(zlib.crc32(0, p, uInt(raw.count)))
    }
}

private func writeZip(from srcDir: URL, to outURL: URL) throws {
    let fm = FileManager.default
    guard fm.createFile(atPath: outURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    let fh = try FileHandle(forWritingTo: outURL)

    struct E { let off: UInt32; let name: String; let size: UInt32; let crc: UInt32 }
    var es: [E] = []

    let en = fm.enumerator(at: srcDir, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = en?.nextObject() as? URL {
        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let name = String(u.path.dropFirst(srcDir.path.count + 1))
        let data = try Data(contentsOf: u, options: .mappedIfSafe)
        let crc  = crc32Of(data)
        let off  = UInt32(fh.offsetInFile)
        let nd   = Data(name.utf8)

        var lh = Data()
        lh.appendLE32(0x04034B50); lh.appendLE16(20); lh.appendLE16(0); lh.appendLE16(0)
        lh.appendLE16(0); lh.appendLE16(0); lh.appendLE32(crc)
        lh.appendLE32(UInt32(data.count)); lh.appendLE32(UInt32(data.count))
        lh.appendLE16(UInt16(nd.count)); lh.appendLE16(0); lh.append(nd)
        try fh.write(contentsOf: lh)
        try fh.write(contentsOf: data)
        es.append(E(off: off, name: name, size: UInt32(data.count), crc: crc))
    }

    let cdOff = UInt32(fh.offsetInFile)
    for e in es {
        let nd = Data(e.name.utf8)
        var ch = Data()
        ch.appendLE32(0x02014B50); ch.appendLE16(20); ch.appendLE16(20)
        ch.appendLE16(0); ch.appendLE16(0); ch.appendLE16(0); ch.appendLE16(0)
        ch.appendLE32(e.crc); ch.appendLE32(e.size); ch.appendLE32(e.size)
        ch.appendLE16(UInt16(nd.count)); ch.appendLE16(0); ch.appendLE16(0)
        ch.appendLE16(0); ch.appendLE16(0); ch.appendLE32(0); ch.appendLE32(e.off); ch.append(nd)
        try fh.write(contentsOf: ch)
    }

    let cdSz = UInt32(fh.offsetInFile) - cdOff
    var eocd = Data()
    eocd.appendLE32(0x06054B50); eocd.appendLE16(0); eocd.appendLE16(0)
    eocd.appendLE16(UInt16(es.count)); eocd.appendLE16(UInt16(es.count))
    eocd.appendLE32(cdSz); eocd.appendLE32(cdOff); eocd.appendLE16(0)
    try fh.write(contentsOf: eocd)
    try fh.close()
}

// MARK: - HTML generation

private func indexHTMLData(recordings: [(rec: Recording, doc: ArticleDoc?)]) -> Data {
    let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.dateFormat = "yyyy年M月d日"
    let dateStr = df.string(from: Date())
    let articleCount = recordings.filter { $0.doc != nil }.count

    var cards = ""
    for (rec, doc) in recordings {
        let title   = doc?.resolvedArticles.first?.title ?? rec.displayTitle
        let preview = doc?.resolvedArticles.first.map { a -> String in
            let t = ArticleBody.stripMarkers(a.body).replacingOccurrences(of: "\n", with: " ")
            return t.count > 120 ? String(t.prefix(120)) + "…" : t
        } ?? ""
        let dur     = rec.durationLabel.map { " · \($0)" } ?? ""
        let badge   = doc != nil
            ? "<span class=\"badge done\">已成文</span>"
            : "<span class=\"badge empty\">无文章</span>"
        let readBtn = doc != nil
            ? "<a class=\"btn\" href=\"recordings/\(rec.stem).html\">读文章</a>" : ""
        let audioBtn = "<a class=\"btn audio\" href=\"audio/\(rec.stem).m4a\">听录音</a>"

        cards += """
        <div class="card">
          <div class="card-top">
            <div class="tile"><svg width="22" height="14" viewBox="0 0 22 14"><rect x="0" y="3" width="3" height="8" rx="1.5" fill="#CFC6B6"/><rect x="4.75" y="0" width="3" height="14" rx="1.5" fill="#CFC6B6"/><rect x="9.5" y="2" width="3" height="10" rx="1.5" fill="#CFC6B6"/><rect x="14.25" y="4" width="3" height="6" rx="1.5" fill="#CFC6B6"/><rect x="19" y="1" width="3" height="12" rx="1.5" fill="#CFC6B6"/></svg></div>
            <div class="ci"><div class="ct">\(h(title))</div><div class="cm">\(h(rec.displayTitle))\(dur)</div></div>
          </div>
          \(preview.isEmpty ? "" : "<div class=\"cp\">\(h(preview))</div>")
          <div class="row">\(badge)<div class="links">\(readBtn)\(audioBtn)</div></div>
        </div>\n
        """
    }

    let html = """
    <!DOCTYPE html>
    <html lang="zh"><head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>VoiceDrop 导出</title>
    <style>
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
    body{background:#FAF6EF;color:#2A2521;font-family:-apple-system,"PingFang SC","Helvetica Neue",sans-serif;min-height:100vh}
    .hdr{padding:18px 0 14px;border-bottom:1px solid #ECE3D5;background:#FAF6EF;position:sticky;top:0;z-index:9}
    .hi{max-width:680px;margin:0 auto;padding:0 24px;display:flex;justify-content:space-between;align-items:center}
    .logo{display:flex;align-items:center;gap:10px}
    .lw{font-size:16px;font-weight:700;color:#2A2521}
    .lw em{color:#D8593B;font-style:normal}
    .ed{font-size:13px;color:#A89E8E}
    .stats{max-width:680px;margin:0 auto;padding:16px 24px 4px;display:flex;gap:28px}
    .sn{font-size:22px;font-weight:700;color:#2A2521;line-height:1}
    .sl{font-size:12px;color:#A89E8E;margin-top:3px;letter-spacing:.4px}
    .wrap{max-width:680px;margin:0 auto;padding:14px 24px 64px}
    .card{background:#fff;border-radius:5px;border:1px solid #ECE3D5;padding:16px 18px;margin-bottom:10px;transition:box-shadow .12s}
    .card:hover{box-shadow:0 2px 12px rgba(42,37,33,.07)}
    .card-top{display:flex;align-items:flex-start;gap:12px}
    .tile{width:40px;height:40px;border-radius:8px;background:#F6EFE3;flex-shrink:0;display:flex;align-items:center;justify-content:center}
    .ci{flex:1;min-width:0}
    .ct{font-size:16px;font-weight:600;color:#2A2521;line-height:1.45;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
    .cm{font-size:13px;color:#A89E8E;margin-top:3px}
    .cp{font-size:14px;color:#4A443C;line-height:1.6;margin-top:10px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
    .row{margin-top:12px;display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px}
    .badge{font-size:11.5px;font-weight:600;padding:2px 9px;border-radius:4px;letter-spacing:.4px}
    .badge.done{background:#EAF1EC;color:#3C5A47}
    .badge.empty{background:#F1ECE3;color:#8A8175}
    .links{display:flex;gap:8px;flex-wrap:wrap}
    .btn{font-size:13px;font-weight:500;color:#D8593B;text-decoration:none;padding:5px 14px;border:1px solid #F6E4DC;border-radius:8px;background:#FDF8F5}
    .btn:hover{background:#F6E4DC}
    .btn.audio{color:#6E8576;border-color:#D5E3D9;background:#F4F8F5}
    .btn.audio:hover{background:#EAF1EC}
    </style></head>
    <body>
    <header class="hdr"><div class="hi">
      <div class="logo">
        <svg width="30" height="17" viewBox="0 0 30 17" fill="#E5392E"><rect x="0" y="5" width="3.2" height="7" rx="1.6"/><rect x="5" y="1" width="3.2" height="15" rx="1.6"/><rect x="10" y="3" width="3.2" height="11" rx="1.6"/><rect x="15" y="6" width="3.2" height="5" rx="1.6"/><rect x="20" y="2" width="3.2" height="13" rx="1.6"/><rect x="25" y="4" width="3.2" height="9" rx="1.6"/></svg>
        <span class="lw">Voice<em>Drop</em> 口述</span>
      </div>
      <span class="ed">\(dateStr)</span>
    </div></header>
    <div class="stats">
      <div><div class="sn">\(recordings.count)</div><div class="sl">条录音</div></div>
      <div><div class="sn">\(articleCount)</div><div class="sl">篇文章</div></div>
    </div>
    <div class="wrap">\n\(cards)</div>
    </body></html>
    """
    return Data(html.utf8)
}

private func recordingHTMLData(rec: Recording, doc: ArticleDoc, downloadedPhotos: [String] = []) -> Data {
    let articles = doc.resolvedArticles
    let title    = articles.first?.title ?? rec.displayTitle
    let dur      = rec.durationLabel.map { " · \($0)" } ?? ""

    // Build a set for fast lookup of successfully downloaded keys
    let downloaded = Set(downloadedPhotos)

    var sections = ""
    for (i, a) in articles.enumerated() {
        var bodyHTML = ""
        for seg in ArticleBody.segments(a.body) {
            switch seg {
            case .text(let t):
                let paras = t.components(separatedBy: "\n\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for p in paras {
                    bodyHTML += "<p>\(h(p.replacingOccurrences(of: "\n", with: " ")))</p>\n"
                }
            case .photo(let token):
                // token = relative key (new) or legacy 1-based index → resolve to a key.
                if let key = ArticleBody.resolvePhotoKey(token, photos: doc.photos ?? []),
                   downloaded.contains(key) {
                    // article is in recordings/, photos are at root level
                    bodyHTML += "<img class=\"photo\" src=\"../\(key)\" loading=\"lazy\">\n"
                }
            }
        }
        sections += (i > 0 ? "<hr>\n" : "") + "<h1>\(h(a.title))</h1>\n<div class=\"body\">\(bodyHTML)</div>\n"
    }

    let transcript = doc.transcript.map {
        "<details class=\"xc\"><summary>原始转录</summary><p class=\"xcp\">\(h($0))</p></details>"
    } ?? ""

    let html = """
    <!DOCTYPE html>
    <html lang="zh"><head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>\(h(title))</title>
    <style>
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
    body{background:#F0EDE7;color:#2B2823;font-family:-apple-system,"PingFang SC","Helvetica Neue",sans-serif;min-height:100vh}
    .nav{max-width:680px;margin:0 auto;padding:16px 24px 0}
    .back{font-size:14px;font-weight:500;color:#D8593B;text-decoration:none}
    .back:hover{opacity:.75}
    .wrap{max-width:680px;margin:0 auto;padding:20px 24px 64px}
    .meta{font-size:13px;color:#9A9387;margin-bottom:20px}
    audio{width:100%;margin-bottom:28px;border-radius:8px}
    hr{border:none;border-top:1px solid #E5DFD5;margin:28px 0}
    h1{font-size:23px;font-weight:600;color:#2B2823;line-height:1.45;margin-bottom:16px}
    .body p{font-size:16px;color:#494339;line-height:1.9;margin-bottom:18px}
    .xc{margin-top:32px;border-top:1px solid #E5DFD5;padding-top:20px}
    .xc summary{font-size:14px;font-weight:600;color:#9A9387;cursor:pointer;margin-bottom:12px;list-style:none}
    .xc summary::before{content:"▶  "}
    details[open].xc summary::before{content:"▼  "}
    .xcp{font-size:14px;color:#9A9387;line-height:1.8;white-space:pre-wrap}
    .photo{width:100%;border-radius:10px;margin-bottom:18px;display:block}
    </style></head>
    <body>
    <div class="nav"><a class="back" href="../index.html">← 所有录音</a></div>
    <div class="wrap">
      <div class="meta">\(h(rec.displayTitle))\(dur)</div>
      <audio controls src="../audio/\(rec.stem).m4a"></audio>
      \(sections)
      \(transcript)
    </div>
    </body></html>
    """
    return Data(html.utf8)
}

private func h(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
}
