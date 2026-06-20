import SwiftUI

/// Browse the user's recordings (pulled from R2) and the articles mined from
/// them. Presented as a sheet from the record screen — the record flow itself
/// is never blocked by this.
struct LibraryView: View {
    /// True while this tab is the selected one. Switching to it triggers a fresh
    /// server pull, so newly-mined articles show up without a manual swipe-down.
    var active: Bool = true

    @State private var store = LibraryStore()
    @State private var confirmDelete: Recording?
    @State private var confirmReprocess: Recording?   // easter egg: long-press 已成文

    var body: some View {
        NavigationStack {
            Group {
                if store.loading && store.recordings.isEmpty {
                    ProgressView().tint(.white)
                } else if let err = store.error, store.recordings.isEmpty {
                    message("加载失败", err)
                } else if store.recordings.isEmpty {
                    message("还没有录音", "录一条，过会儿服务器会自动转写并挖成文章。")
                } else {
                    List(store.recordings) { rec in
                        NavigationLink {
                            RecordingDetailView(store: store, recording: rec)
                        } label: {
                            row(rec)
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                confirmDelete = rec
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(.red)   // the TabView's .tint(.white) would otherwise override the destructive red
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await store.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("我的录音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await store.load() }
        .onChange(of: active) { _, nowActive in
            if nowActive { Task { await store.load() } }
        }
        .alert("删除这条录音？", isPresented: .init(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { rec in
            Button("删除", role: .destructive) {
                Task { await store.delete(rec) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("音频和已挖出的文章都会从云端删除，不可恢复。")
        }
        // Easter egg: long-press the 已成文 badge to scrap the article and re-mine.
        .alert("重新处理这篇文章？", isPresented: .init(
            get: { confirmReprocess != nil },
            set: { if !$0 { confirmReprocess = nil } }
        ), presenting: confirmReprocess) { rec in
            Button("删除文章并重新生成", role: .destructive) {
                Task { await store.deleteArticle(rec) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("会删掉已生成的文章、保留录音，下个周期重新挖一遍。")
        }
    }

    private func row(_ rec: Recording) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.displayTitle).foregroundStyle(.white).font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    if let d = rec.durationLabel {
                        Text(d).foregroundStyle(.white.opacity(0.4)).font(.caption2.monospaced())
                    }
                    if rec.hasArticles {
                        Label("已成文", systemImage: "doc.text")
                            .foregroundStyle(.green.opacity(0.85)).font(.caption2)
                            .contentShape(Rectangle())
                            .onLongPressGesture { confirmReprocess = rec }
                    } else if rec.isEmpty {
                        Label("无语音", systemImage: "speaker.slash")
                            .foregroundStyle(.white.opacity(0.35)).font(.caption2)
                    } else {
                        Text("待处理").foregroundStyle(.orange.opacity(0.8)).font(.caption2)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func message(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).foregroundStyle(.white.opacity(0.8)).font(.headline)
            Text(subtitle).foregroundStyle(.white.opacity(0.45)).font(.callout)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }
}
