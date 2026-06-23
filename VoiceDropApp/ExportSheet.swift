import SwiftUI

/// Bottom sheet shown while exporting all recordings: idle → running → zipping → done/failed.
struct ExportSheet: View {
    let manager: ExportManager
    let recordings: [Recording]
    let store: LibraryStore

    @State private var shareItem: ExportShareItem?

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.faint).frame(width: 36, height: 4)
                .padding(.top, 12).padding(.bottom, 4)
            contentView
                .padding(.horizontal, 24).padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.appBG)
        .task { if case .idle = manager.phase { await manager.export(recordings: recordings, store: store) } }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
    }

    @ViewBuilder private var contentView: some View {
        switch manager.phase {
        case .idle:
            spinnerView("正在准备…")
        case .running(let done, let total, let current):
            runningView(done: done, total: total, current: current)
        case .zipping:
            spinnerView("正在打包…")
        case .done(let url):
            doneView(url: url)
        case .failed(let msg):
            failedView(msg: msg)
        }
    }

    private func spinnerView(_ label: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.accent).scaleEffect(1.3).padding(.top, 16)
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.secondary)
        }.padding(.vertical, 28)
    }

    private func runningView(done: Int, total: Int, current: String) -> some View {
        VStack(spacing: 0) {
            Text("正在导出数据")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.top, 32).padding(.bottom, 22)
            ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Theme.accent)
            HStack {
                Text(current).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer()
                Text("\(done) / \(total)").font(.system(size: 13)).foregroundStyle(Theme.metaChrome)
            }.padding(.top, 8)
        }.padding(.bottom, 16)
    }

    private func doneView(url: URL) -> some View {
        VStack(spacing: 0) {
            Circle().fill(Color(hex: "EAF1EC")).frame(width: 56, height: 56)
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(hex: "3C5A47")))
                .padding(.top, 32)
            Text("导出完成")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.top, 16)
            if let size = zipSizeLabel(url) {
                Text(size).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 4)
            }
            Button { shareItem = ExportShareItem(url: url) } label: {
                Label("分享 / 保存到本地", systemImage: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
        }
    }

    private func failedView(msg: String) -> some View {
        VStack(spacing: 0) {
            Circle().fill(Theme.accentSoft).frame(width: 56, height: 56)
                .overlay(Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent))
                .padding(.top, 32)
            Text("导出失败")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                .padding(.top, 16)
            Text(msg).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).padding(.top, 4)
            Button {
                manager.reset()
                Task { await manager.export(recordings: recordings, store: store) }
            } label: {
                Text("重试")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.R.primary))
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
        }
    }

    private func zipSizeLabel(_ url: URL) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
        else { return nil }
        let mb = Double(size) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : "\(size / 1024) KB"
    }
}

private struct ExportShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
