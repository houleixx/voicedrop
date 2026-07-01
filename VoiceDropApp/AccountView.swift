import SwiftUI
import UIKit

/// 账户详情 — the anonymous identity, its keys, data counts, and reset.
struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = LibraryStore()
    @State private var settings = SettingsStore()
    @State private var idCopied = false
    @State private var tokenCopied = false
    @State private var openingArticles = false
    @State private var showDeviceLink = false

    private var auth: AuthStore { AuthStore.shared }
    private var recordingCount: Int { store.recordings.count }
    private var minedCount: Int { store.recordings.filter(\.hasArticles).count }

    private var maskedToken: String {
        let t = auth.bearer
        guard t.count > 16 else { return t }
        return "\(t.prefix(10))••••••\(t.suffix(4))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavSquare(systemName: "chevron.left", size: 36) { dismiss() }
                Text("账户").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identityCard
                    group("数据") { dataCard }
                    group("转移与同步") { transferCard }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.load() }
        .sheet(isPresented: $showDeviceLink) { DeviceLinkView() }
    }

    // MARK: Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: Theme.R.tile).fill(Theme.inkTile).frame(width: 46, height: 46)
                    .overlay(Image(systemName: "checkmark.shield.fill").font(.system(size: 20)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text("账户").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("在这台设备上自动生成，不需要用户名或密码。")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Rectangle().fill(Theme.dividerInCard).frame(height: 1)

            keyField(label: "你的 ID", value: auth.anonId, masked: false, copied: idCopied) {
                UIPasteboard.general.string = auth.anonId
                idCopied = true
                Task { try? await Task.sleep(nanoseconds: 1_800_000_000); idCopied = false }
            }

            keyField(label: "访问令牌", value: maskedToken, masked: true, copied: tokenCopied) {
                UIPasteboard.general.string = auth.bearer
                tokenCopied = true
                Task { try? await Task.sleep(nanoseconds: 1_800_000_000); tokenCopied = false }
            }

            Rectangle().fill(Theme.dividerInCard).frame(height: 1)

            if auth.isAuthenticated {
                HStack {
                    Label("已用 Apple 登录", systemImage: "applelogo")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("退出登录") { auth.signOut() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
            } else {
                Button {
                    Task { await auth.signInWithApple() }
                } label: {
                    Label("用 Apple 登录（同步设备 · 参与社区）", systemImage: "applelogo")
                        .font(.system(size: 15)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            Button { showDeviceLink = true } label: {
                Label("登录已有账号", systemImage: "iphone.and.arrow.forward")
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .cardChromeShadow()
    }

    private func keyField(label: String, value: String, masked: Bool, copied: Bool, copy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12.5, weight: .semibold)).tracking(1).foregroundStyle(Theme.sectionLabel)
            HStack(spacing: 10) {
                Text(value).font(.system(size: masked ? 14 : 15, design: .monospaced))
                    .foregroundStyle(masked ? Theme.secondary : Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        if masked { Text(copied ? "已复制" : "复制").font(.system(size: 13, weight: .semibold)) }
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 11).padding(.horizontal, 13)
            .background(Theme.appBG, in: RoundedRectangle(cornerRadius: Theme.R.input))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.input).stroke(Theme.borderChrome, lineWidth: 1))
        }
    }

    // MARK: Data

    private var dataCard: some View {
        SettingsCard {
            dataRow("录音", "\(recordingCount) 条", trailingChevron: false)
            settingsRowDivider
            dataRow("成文", "\(minedCount) 篇", trailingChevron: false)
            settingsRowDivider
            Button {
                guard !openingArticles else { return }
                Task {
                    openingArticles = true; defer { openingArticles = false }
                    if let url = try? await settings.articlesPageURL() { await UIApplication.shared.open(url) }
                }
            } label: {
                HStack {
                    Text("查看全部文章").font(.system(size: 16)).foregroundStyle(Theme.ink)
                    Spacer()
                    if openingArticles { ProgressView() } else { settingsChevron }
                }
                .padding(.vertical, 14).padding(.horizontal, 15).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func dataRow(_ title: String, _ value: String, trailingChevron: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 16)).foregroundStyle(Theme.ink)
            Spacer()
            Text(value).font(.system(size: 14)).foregroundStyle(Theme.secondary)
            if trailingChevron { settingsChevron }
        }
        .padding(.vertical, 14).padding(.horizontal, 15)
    }

    // MARK: Transfer / sync

    private var transferCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                HStack {
                    Text("iCloud 钥匙串同步").font(.system(size: 16)).foregroundStyle(Theme.ink)
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Theme.greenDone).frame(width: 6, height: 6)
                        Text("已开启").font(.system(size: 13)).foregroundStyle(Theme.greenDone)
                    }
                }
                .padding(.vertical, 14).padding(.horizontal, 15)
            }
            Text("换新机时，登录同一 Apple 账户即可自动恢复；ID 随 iCloud 钥匙串备份。")
                .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }


    @ViewBuilder private func group<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionLabel(label)
            content()
        }
    }
}
