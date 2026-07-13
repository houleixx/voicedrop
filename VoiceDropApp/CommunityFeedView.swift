import SwiftUI

/// VD社区双排瀑布流（design_handoff_community_feed 方向 1a，2026-07-13）。
/// 小红书式混排：照片帖用图封面（高度随原图宽高比 → 瀑布错落），纯文字帖用
/// 暖色渐变排版封面撑场。每卡露作者 + 投币数（主指标）+ 回应数（>0 才显示）。
/// 卡片素材（hasPhoto/coverPhotoKey/preview）由 community/list 服务端补齐——
/// 旧服务端响应缺这些字段时全部走文字卡兜底，不额外拉全文。
struct CommunityFeedView: View {
    let store: CommunityStore
    let onSelect: (CommunityPost) -> Void
    let onUnshare: (CommunityPost) -> Void

    enum FeedTab { case reco, latest, replies }
    @State private var tab: FeedTab = .reco
    /// coverPhotoKey → 实测宽高比（w/h）。图片加载后回填，masonry 用它重新估高。
    @State private var coverAspects: [String: CGFloat] = [:]

    static let pageBG = Color(hex: "F3EFE7")   // 比 readBG 略深，衬白卡

    private var posts: [CommunityPost] {
        switch tab {
        case .reco:    return store.posts        // reco 排序（applyRanking 后的顺序）
        case .latest:  return store.timeOrdered  // 服务端原始顺序（纯时间序，不经 reco）
        case .replies: return store.posts.filter { $0.replyTo != nil }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabRow
            GeometryReader { geo in
                let colWidth = (geo.size.width - 12 * 2 - 9) / 2
                let (left, right) = split(posts, colWidth: colWidth)
                ScrollView {
                    HStack(alignment: .top, spacing: 9) {
                        column(left, width: colWidth)
                        column(right, width: colWidth)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .refreshable { await store.load() }
            }
        }
        .background(Self.pageBG)
    }

    // MARK: 分段 tab（推荐 / 最新 / 回应）

    private var tabRow: some View {
        HStack(spacing: 18) {
            tabLabel(String(localized: "推荐"), .reco)
            tabLabel(String(localized: "最新"), .latest)
            tabLabel(String(localized: "回应"), .replies)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func tabLabel(_ title: String, _ t: FeedTab) -> some View {
        Button { tab = t } label: {
            Text(title)
                .font(.system(size: 15, weight: tab == t ? .semibold : .regular))
                .foregroundStyle(tab == t ? Theme.ink : Theme.metaChrome)
        }
        .buttonStyle(.plain)
    }

    // MARK: Masonry（两列贪心：每帖进当前较矮的一列）

    private func split(_ posts: [CommunityPost], colWidth: CGFloat) -> ([CommunityPost], [CommunityPost]) {
        var left: [CommunityPost] = [], right: [CommunityPost] = []
        var hLeft: CGFloat = 0, hRight: CGFloat = 0
        for p in posts {
            let h = estimatedHeight(p, width: colWidth)
            if hLeft <= hRight { left.append(p); hLeft += h + 9 }
            else { right.append(p); hRight += h + 9 }
        }
        return (left, right)
    }

    /// 估算卡高——只为左右列均衡，不必精确。中文字宽 ≈ 字号。
    private func estimatedHeight(_ post: CommunityPost, width: CGFloat) -> CGFloat {
        let title = post.title ?? ""
        if let key = post.coverPhotoKey {
            let aspect = coverAspects[key] ?? 1.0          // 未加载时按占位 1:1
            let titleLines = min(2, max(1, Int(ceil(CGFloat(title.count) * 14.5 / max(width - 22, 1)))))
            return width / aspect + CGFloat(titleLines) * 21 + 20 + 30 + (post.replyTo != nil ? 28 : 0)
        }
        let titleLines = min(3, max(1, Int(ceil(CGFloat(title.count) * 16 / max(width - 26, 1)))))
        let previewLines = (post.preview?.isEmpty ?? true) ? 0
            : min(2, max(1, Int(ceil(CGFloat(post.preview!.count) * 12.5 / max(width - 26, 1)))))
        return CGFloat(titleLines) * 24 + CGFloat(previewLines) * 20
            + (post.replyTo != nil ? 30 : 0) + 20 + 27 + (previewLines > 0 ? 8 : 0)
    }

    private func column(_ posts: [CommunityPost], width: CGFloat) -> some View {
        LazyVStack(spacing: 9) {
            ForEach(posts) { post in
                Button { onSelect(post) } label: {
                    card(post, width: width)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if post.mine == true {
                        Button(role: .destructive) { onUnshare(post) } label: {
                            Label("取消分享", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .frame(width: width)
    }

    @ViewBuilder private func card(_ post: CommunityPost, width: CGFloat) -> some View {
        if let key = post.coverPhotoKey {
            PhotoCoverCard(post: post, store: store, coverKey: key, width: width) { aspect in
                if coverAspects[key] != aspect { coverAspects[key] = aspect }
            }
        } else {
            TextCoverCard(post: post, store: store)
        }
    }
}

// MARK: - 卡片阴影（两种卡同款）

private extension View {
    func feedCardShadow() -> some View {
        shadow(color: Color(red: 120/255, green: 90/255, blue: 50/255).opacity(0.08), radius: 5, y: 2)
    }
}

// MARK: - A. 照片封面卡

private struct PhotoCoverCard: View {
    let post: CommunityPost
    let store: CommunityStore
    let coverKey: String        // 完整 R2 key，走公开 /photo/<key>
    let width: CGFloat
    let onAspect: (CGFloat) -> Void

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 9) {
                if post.replyTo != nil { ReplyBadge() }
                Text(post.title ?? String(localized: "(无题)"))
                    .font(.system(size: 14.5))          // 用户拍板：标题细体不加粗
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(14.5 * 0.45 - 4)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FeedMetaRow(post: post, store: store)
            }
            .padding(EdgeInsets(top: 10, leading: 11, bottom: 11, trailing: 11))
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .feedCardShadow()
        .task(id: coverKey) {
            guard image == nil else { return }
            if let img = await store.photoImage(fullKey: coverKey, preferThumb: true) {
                image = img
                onAspect(img.size.width / max(img.size.height, 1))
            }
        }
    }

    /// 封面：宽撑满列、高按原图宽高比（瀑布错落的来源）。占位 1:1、Theme.card 底。
    @ViewBuilder private var cover: some View {
        if let img = image {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(img.size.width / max(img.size.height, 1), contentMode: .fit)
                .frame(width: width)
        } else {
            Rectangle().fill(Theme.card)
                .frame(width: width, height: width)
                .overlay(ProgressView().tint(Theme.accent))
        }
    }
}

// MARK: - B. 文字封面卡（暖色渐变排版封面）

private struct TextCoverCard: View {
    let post: CommunityPost
    let store: CommunityStore

    /// 暖色封面色板（README 分类色板）：帖子无分类，按 shareId 稳定 hash 分配，
    /// 同一帖每次一致。
    private static let palettes: [(top: Color, bottom: Color)] = [
        (Color(hex: "FBEFE0"), Color(hex: "F6E3CE")),   // 暖橙
        (Color(hex: "EDE7DC"), Color(hex: "E2DACB")),   // 灰褐
        (Color(hex: "E7EDE3"), Color(hex: "D6E0CE")),   // 暖绿
    ]

    private var palette: (top: Color, bottom: Color) {
        let h = post.shareId.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palettes[h % Self.palettes.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if post.replyTo != nil { ReplyBadge() }
                Text(post.title ?? String(localized: "(无题)"))
                    .font(.system(size: 16))            // 用户拍板：标题细体不加粗
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(16 * 0.5 - 4)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let preview = post.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(hex: "8A7B63"))
                        .lineSpacing(12.5 * 0.6 - 4)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(EdgeInsets(top: 15, leading: 13, bottom: 12, trailing: 13))
            FeedMetaRow(post: post, store: store)
                .padding(EdgeInsets(top: 0, leading: 13, bottom: 12, trailing: 13))
        }
        .background(LinearGradient(colors: [palette.top, palette.bottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .feedCardShadow()
    }
}

// MARK: - 回应角标（胶囊，正文区顶部）

private struct ReplyBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 9, weight: .semibold))
            Text("回应").font(.system(size: 11))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Theme.accentSoft, in: Capsule())
    }
}

// MARK: - 元信息行：[头像 20] [作者名 flex] [⚡投币] [💬回应（>0 才显示）]

private struct FeedMetaRow: View {
    let post: CommunityPost
    let store: CommunityStore

    /// 头像底色：按作者名稳定 hash 取暖色，同一作者每次一致。
    private static let avatarColors: [Color] = [
        Color(hex: "D8A25B"), Color(hex: "8A9A88"), Color(hex: "B5794C"),
        Color(hex: "7A6E9A"), Color(hex: "5E8A6A"), Color(hex: "C98A2E"),
    ]

    private var author: String { post.author ?? String(localized: "匿名") }

    private var avatarColor: Color {
        let h = author.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.avatarColors[h % Self.avatarColors.count]
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(avatarColor)
                .frame(width: 20, height: 20)
                .overlay(Text(String(author.prefix(1)))
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            Text(author)
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 被赞数（红心，主指标，始终显示）——来自 rank 响应的 likes
            HStack(spacing: 3) {
                Image(systemName: "heart.fill").font(.system(size: 10))
                Text("\(store.likeCounts[post.shareId] ?? 0)").font(.system(size: 12))
            }
            .foregroundStyle(Theme.accent)
            // 回应数（>0 才显示）
            if let replies = store.replyCounts[post.shareId], replies > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left").font(.system(size: 10))
                    Text("\(replies)").font(.system(size: 12))
                }
                .foregroundStyle(Theme.secondary)
            }
        }
    }
}
