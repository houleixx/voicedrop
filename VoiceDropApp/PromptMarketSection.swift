// PromptMarketSection.swift — 提示词管理页的「社区热门」段 + 详情页。
// 设计：design_handoff_prompt_manager 第 8 轮定稿（8a 列表续接 + 8b 详情）。
// 2026-07-22 提示词退出社区 feed 后，这里是提示词公共曝光的唯一入口，数据端
// GET /agent/prompt-market?sort=hot|new&scope=text|image（agent/src/prompt-market.js）。
//
// 显示纪律（建硕 2026-07-22 拍板）：社区行与详情一律**平铺**展示——分享带
// folder/action 结构（groupPath）时不渲染层级；「加入」走既有 POST /agent/prompts/import，
// 服务端会把 groupPath 落进同名分组（导入尊重结构，展示不体现）。
// 效果示例（example）异步后置：模型留字段位，无数据整块隐藏（设计稿同款约定）。
import SwiftUI

// MARK: - 数据

struct MarketItem: Decodable, Identifiable, Equatable {
    let code: String
    let label: String
    let appliesTo: [String]
    let kind: String?
    let author: String
    let importCount: Int
    let createdAt: String?
    /// 效果示例——异步后置的留位字段：服务端暂不下发，下发后 8b 详情自动出块。
    let example: MarketExample?
    var id: String { code }

    enum CodingKeys: String, CodingKey { case code, label, appliesTo, kind, author, importCount, createdAt, example }
}

struct MarketExample: Decodable, Equatable {
    let input: String?
    let output: String?
    let imageKey: String?
    let source: String?
}

enum MarketFilter: String, CaseIterable {
    case hot, new, text, image
    var title: String {
        switch self {
        case .hot: return String(localized: "热门")
        case .new: return String(localized: "最新")
        case .text: return String(localized: "文字")
        case .image: return String(localized: "配图")
        }
    }
    var query: String {
        switch self {
        case .hot: return "sort=hot"
        case .new: return "sort=new"
        case .text: return "sort=hot&scope=text"
        case .image: return "sort=hot&scope=image"
        }
    }
}

@MainActor
@Observable
final class PromptMarketModel {
    var items: [MarketItem] = []
    var loading = false
    var failed = false
    var filter: MarketFilter = .hot

    func load() async {
        loading = items.isEmpty
        failed = false
        var req = URLRequest(url: URL(string: "\(API.agentBase.absoluteString)/prompt-market?\(filter.query)&limit=30")!)
        req.setBearer(AuthStore.shared.bearer)
        struct R: Decodable { let items: [MarketItem] }
        if let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
           let decoded = try? JSONDecoder().decode(R.self, from: data) {
            items = decoded.items
        } else if items.isEmpty {
            failed = true
        }
        loading = false
    }
}

// MARK: - 8a 列表段（PromptManagerView 的正常态 List 里作为一个 Section 的内容挂入）

struct PromptMarketSection: View {
    @Bindable var model: PromptMarketModel
    let store: PromptStore
    /// 导入成功后回调（code, 新条目 id）——父视图滚动高亮新行。
    var onImported: (String, String) -> Void
    @State private var detail: MarketItem?
    @State private var importing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("社区热门")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.sectionLabel)
                .padding(.leading, 4)
            chipRow
            content
        }
        .task { await model.load() }
        .onChange(of: model.filter) { _, _ in Task { await model.load() } }
        .sheet(item: $detail) { item in
            PromptMarketDetailView(item: item, store: store,
                                   imported: PromptLogic.containsImport(code: item.code, in: store.items)) { newID in
                detail = nil
                onImported(item.code, newID)
                Task { await model.load() }
            }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(MarketFilter.allCases, id: \.self) { f in
                Button {
                    model.filter = f
                } label: {
                    Text(f.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(model.filter == f ? .white : Theme.bodyInk)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(
                            Capsule().fill(model.filter == f ? Color(hex: "2B2823") : Color.white)
                        )
                        .overlay(
                            Capsule().stroke(model.filter == f ? Color.clear : Color(hex: "E5DCCB"), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.padding(.vertical, 24)
        } else if model.failed {
            Text("社区热门加载失败，下拉重试")
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
        } else if model.items.isEmpty {
            Text("还没有人分享提示词")
                .font(.system(size: 13)).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                    marketRow(item)
                    if i < model.items.count - 1 {
                        Rectangle().fill(Theme.dividerInCard).frame(height: 1).padding(.leading, 61)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderChrome, lineWidth: 1))
        }
    }

    private func marketRow(_ item: MarketItem) -> some View {
        let imported = PromptLogic.containsImport(code: item.code, in: store.items)
        return HStack(alignment: .center, spacing: 12) {
            marketTile(item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label).font(.system(size: 15)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subline(item))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.sectionLabel).lineLimit(1)
            }
            Spacer(minLength: 8)
            if imported {
                HStack(spacing: 4) {
                    Text("已导入").font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.chevron)
                }
            } else if importing.contains(item.code) {
                ProgressView().tint(Theme.accent).scaleEffect(0.8)
            } else {
                Button {
                    Task { await quickImport(item) }
                } label: {
                    Text("导入")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .overlay(Capsule().stroke(Color(hex: "EBC4B7"), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 15)
        .contentShape(Rectangle())
        .onTapGesture { detail = item }
    }

    private func marketTile(_ item: MarketItem) -> some View {
        let isImage = item.appliesTo == ["image"]
        return RoundedRectangle(cornerRadius: Theme.R.tile)
            .fill(isImage ? Theme.accentSoft : Color(hex: "EAF1EC"))
            .frame(width: 34, height: 34)
            .overlay(
                Image(systemName: isImage ? "photo" : "text.alignleft")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isImage ? Theme.accent : Color(hex: "5E8A6A"))
            )
    }

    private func subline(_ item: MarketItem) -> String {
        let by = item.author.isEmpty ? String(localized: "匿名") : item.author
        return "\(by) · \(String(localized: "导入")) \(item.importCount)"
    }

    private func quickImport(_ item: MarketItem) async {
        importing.insert(item.code)
        defer { importing.remove(item.code) }
        if case .success(let out) = await store.importPrompt(code: item.code) {
            onImported(item.code, out.item.id)
            Analytics.capture("社区热门快捷导入", ["码": item.code])
        }
    }
}

// MARK: - 8b 详情页（sheet；示例块留位，无数据隐藏）

struct PromptMarketDetailView: View {
    let item: MarketItem
    let store: PromptStore
    let imported: Bool
    var onImported: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var errorText: String?

    private var isImage: Bool { item.appliesTo == ["image"] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    typeBadge
                    Text(item.label)
                        .font(.system(size: 23, weight: .semibold)).foregroundStyle(Theme.ink)
                    authorLine
                    statsCard
                    promptCard
                    exampleBlock   // example 留位：现阶段服务端不下发 → EmptyView
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 18).padding(.top, 22)
            }
            footer
        }
        .background(Theme.appBG)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var typeBadge: some View {
        Text(isImage ? "配图提示词" : "文字提示词")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(isImage ? Theme.accent : Color(hex: "5E8A6A"))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(isImage ? Theme.accentSoft : Color(hex: "EAF1EC"), in: RoundedRectangle(cornerRadius: 4))
    }

    private var authorLine: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: "D8A25B"))
                .frame(width: 24, height: 24)
                .overlay(Text(String((item.author.isEmpty ? "友" : item.author).prefix(1)))
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
            Text(item.author.isEmpty ? String(localized: "匿名分享者") : item.author)
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }

    private var statsCard: some View {
        // 「好评」格已砍（建硕 2026-07-22：没有 rating 数据，占位没意义；真要做时再加回）。
        HStack(spacing: 0) {
            statCell(String(item.importCount), String(localized: "被导入"))
            statDivider
            statCell(appliesText, String(localized: "适用于"))
        }
        .padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderChrome, lineWidth: 1))
    }

    private var appliesText: String {
        if item.appliesTo.count > 1 { return String(localized: "都行") }
        return item.appliesTo.first == "image" ? String(localized: "图片") : String(localized: "文字")
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(Theme.dividerInCard).frame(width: 1, height: 30)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("提示词全文")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.sectionLabel)
            Text(promptFullText)
                .font(.system(size: 14)).foregroundStyle(Color(hex: "5B5349"))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.borderChrome, lineWidth: 1))
        }
    }

    /// 详情正文用 market 列表已有的数据渲染标题/统计；全文需要单独拉（列表端点不带
    /// instruction，省流量）。打开时 GET /agent/prompt-share/<code> 补全。
    @State private var fullPrompt: String?
    private var promptFullText: String {
        fullPrompt ?? String(localized: "加载中…")
    }

    @ViewBuilder
    private var exampleBlock: some View {
        // example 异步后置：服务端下发后这里出 before→after 块；现在恒 nil = 整块隐藏。
        if let ex = item.example, (ex.output ?? ex.imageKey) != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("效果示例").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.sectionLabel)
                if let input = ex.input, !input.isEmpty {
                    Text(input).font(.system(size: 13)).foregroundStyle(Theme.faint)
                }
                if let output = ex.output, !output.isEmpty {
                    Text(output).font(.system(size: 13)).foregroundStyle(Theme.bodyInk)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let e = errorText {
                Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
            Button {
                Task { await performImport() }
            } label: {
                Text(imported ? "已在我的提示词里" : "加入我的提示词")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(imported ? Theme.faint : Theme.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(imported || busy)
            .overlay { if busy { ProgressView().tint(.white) } }
        }
        .padding(.horizontal, 18).padding(.top, 10)
        .padding(.bottom, 12)
        .background(Theme.appBG)
        .task {
            // 全文补拉（平铺展示：groupPath 不渲染，导入时服务端自会落组）
            var req = URLRequest(url: URL(string: "\(API.agentBase.absoluteString)/prompt-share/\(item.code)")!)
            req.setBearer(AuthStore.shared.bearer)
            struct R: Decodable { let prompt: String }
            if let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
               let d = try? JSONDecoder().decode(R.self, from: data) {
                fullPrompt = d.prompt
            } else {
                fullPrompt = String(localized: "（全文加载失败）")
            }
        }
    }

    private func performImport() async {
        busy = true
        defer { busy = false }
        switch await store.importPrompt(code: item.code) {
        case .success(let out):
            Analytics.capture("社区热门详情导入", ["码": item.code])
            onImported(out.item.id)
        case .failure(let err):
            errorText = err.message
        }
    }
}
