import Foundation
import Observation

/// importPrompt 返回类型中的错误。
struct PromptError: Error, Equatable {
    let message: String
}

// Prompt Manager Phase 2（iOS）—— 模型 + 纯逻辑（Task 2）+ 网络/缓存层（Task 3）。
// spec: docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §9
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 2/3

// MARK: - 模型

/// 服务端 resolved 节点（`GET /agent/prompts` 的 items 数组元素）。
/// 未知字段（如 `imageParams`）不声明 = Codable 自动忽略，不炸解码。
struct PromptNode: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var type: String            // "action" | "group"
    var label: String
    var origin: String          // "system" | "custom" | "user"（服务端派生，客户端只读它画标）
    var prompt: String? = nil
    var appliesTo: [String]? = nil   // action 才有
    var kind: String? = nil
    var forkedFrom: String? = nil
    var children: [PromptNode]? = nil // group 才有
}

enum PromptAnchor: String {
    case text
    case image
}

// MARK: - 纯逻辑（全部 static，可单测）

enum PromptLogic {
    /// resolved 树 → PUT 的 raw 形状。origin==system 只写 {"ref":id}（+group 递归 children），
    /// 引用绝不携带内容字段；custom/user 写全字段实体。
    static func rawItems(_ nodes: [PromptNode]) -> [[String: Any]] {
        nodes.map(rawItem)
    }

    private static func rawItem(_ node: PromptNode) -> [String: Any] {
        if node.origin == "system" {
            var dict: [String: Any] = ["ref": node.id]
            if node.type == "group", let children = node.children {
                dict["children"] = rawItems(children)
            }
            return dict
        }

        var dict: [String: Any] = [
            "id": node.id,
            "type": node.type,
            "label": node.label,
        ]
        if let forkedFrom = node.forkedFrom {
            dict["forkedFrom"] = forkedFrom
        }
        if node.type == "group" {
            dict["children"] = rawItems(node.children ?? [])
        } else {
            if let prompt = node.prompt {
                dict["prompt"] = prompt
            }
            if let appliesTo = node.appliesTo {
                dict["appliesTo"] = appliesTo
            }
            if let kind = node.kind {
                dict["kind"] = kind
            }
        }
        return dict
    }

    /// 系统项实体化：新 p_ id + forkedFrom + origin=custom，内容字段原样保留。
    static func fork(_ node: PromptNode) -> PromptNode {
        var copy = node
        copy.id = newUserID()
        copy.forkedFrom = node.id
        copy.origin = "custom"
        return copy
    }

    /// "p_" + 8 位 base36（小写字母+数字），格式与服务端实体 id 校验（`^p_[a-z0-9]{6,}$`）兼容。
    static func newUserID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = (0..<8).map { _ in alphabet.randomElement()! }
        return "p_" + String(suffix)
    }

    /// Task 6：粘贴/深链里抠出 7 位魔法数字。边界用负向前后瞻（与服务端解析器同一套
    /// 边界规则）：裸 8 位数字（比如手机号片段）里不会误抠出前 7 位——`(?<![0-9])` /
    /// `(?![0-9])` 保证匹配两侧都不是数字。找不到 → nil。
    static func extractShareCode(_ s: String) -> String? {
        let pattern = #"(?<![0-9])[1-9][0-9]{6}(?![0-9])"#
        guard let range = s.range(of: pattern, options: .regularExpression) else { return nil }
        return String(s[range])
    }

    /// Task 6 Part B: PromptImportSheet 输入框变化处理——区分敲键盘（TYPING）vs 粘贴/自动补全
    /// （PASTING），防止盲目 prefix(7) 误把 8 位手机号的前 7 位当成魔法数字。
    ///
    /// TYPING 路径（incoming 相对 previous 只在末尾增减≤1个字符）：
    ///   保留原有简单逻辑——只过滤数字，封顶 7 位。数字小键盘打不出非数字，这里是保险。
    ///
    /// PASTING 路径（其它任何变化：粘贴、autofill、长度跳跃）：
    ///   专属走 extractShareCode（服务端同款边界正则）。
    ///   - 匹配成功 → 返回抠出的码。
    ///   - 匹配失败 → 拒绝粘贴，保留原值（防止 "12345678" 闯入导入流程）。
    static func mergeCodeInput(previous: String, incoming: String) -> String {
        // 无变化
        if incoming == previous { return incoming }

        // 检测 TYPING：单个字符在末尾增加或删除
        let isTyping: Bool
        if incoming.count == previous.count + 1 {
            // 末尾增加一个字符？
            isTyping = incoming.hasPrefix(previous)
        } else if incoming.count == previous.count - 1 {
            // 末尾删除一个字符？
            isTyping = previous.hasPrefix(incoming)
        } else {
            isTyping = false
        }

        if isTyping {
            // TYPING 路径：简单过滤数字 + 封顶 7 位
            let filtered = String(incoming.filter(\.isNumber).prefix(7))
            return filtered
        } else {
            // PASTING 路径：只走 extractShareCode 的边界检验，不做盲目截断
            if let extracted = extractShareCode(incoming) {
                return extracted
            }
            // 找不到有效码 → 拒绝粘贴，保留原值
            return previous
        }
    }

    /// 扁平化树 → 顶层 + 全部嵌套子项的 id 序列（保序）。用于排序态冲突检测：
    /// 进入排序前的 id 序列 vs 完成时的 id 序列，任何不同都意味着列表被别处更新。
    static func flattenIDs(_ items: [PromptNode]) -> [String] {
        items.flatMap { node -> [String] in
            var ids = [node.id]
            if node.type == "group" {
                ids += (node.children ?? []).map(\.id)
            }
            return ids
        }
    }

    /// 纯函数删除：在整棵树（顶层 + 组内子项）里找到 id 对应节点并摘除，返回新数组 +
    /// 被删的节点；删除一个分组连它的 children 一起带走（组本身就是一个节点）；
    /// 找不到该 id → 原数组原样返回 + nil。零索引状态——调用方（PromptStore.delete）
    /// 靠这个纯函数 + 整树快照做删除/回滚，不用自己记 (topIndex, childIndex)。
    static func removing(_ items: [PromptNode], id: String) -> ([PromptNode], PromptNode?) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            var copy = items
            let node = copy.remove(at: i)
            return (copy, node)
        }
        for (gi, group) in items.enumerated() where group.type == "group" {
            if let ci = group.children?.firstIndex(where: { $0.id == id }) {
                var copy = items
                var children = copy[gi].children ?? []
                let node = children.remove(at: ci)
                copy[gi].children = children
                return (copy, node)
            }
        }
        return (items, nil)
    }

    /// 原位替换：找到 id 对应节点（顶层或组内子项）换成 `newNode`，位置不变——`newNode.id`
    /// 可以和原 id 不同（fork 换新 p_ id 时就是这样）。找不到该 id → 原数组原样返回。
    /// 与 `removing` 对称，同样是零索引状态的纯函数，供 `PromptStore.replace` 做
    /// 快照/保存/失败回滚（不用自己记 (topIndex, childIndex)）。
    static func replacing(_ items: [PromptNode], id: String, with newNode: PromptNode) -> [PromptNode] {
        if let i = items.firstIndex(where: { $0.id == id }) {
            var copy = items
            copy[i] = newNode
            return copy
        }
        for (gi, group) in items.enumerated() where group.type == "group" {
            if let ci = group.children?.firstIndex(where: { $0.id == id }) {
                var copy = items
                var children = copy[gi].children ?? []
                children[ci] = newNode
                copy[gi].children = children
                return copy
            }
        }
        return items
    }

    // MARK: - Task 7：拖动排序 / 拖进拖出分组（全部纯函数，PromptManagerView 排序态 draft 上调用）

    /// 顶层重排：把 `fromTop` 位置的节点挪到 `toTop`（语义与 SwiftUI `.onMove`/
    /// `Array.move(fromOffsets:toOffset:)` 一致——`toTop` 是"移除前"的插入基准位，
    /// 需要在移除后按位置关系整体减一再插入，与该 API 的标准实现一致）。
    /// `fromTop` 越界 → 原数组原样返回。
    static func moving(_ items: [PromptNode], fromTop: Int, toTop: Int) -> [PromptNode] {
        guard items.indices.contains(fromTop) else { return items }
        var copy = items
        let node = copy.remove(at: fromTop)
        var dest = toTop
        if fromTop < dest { dest -= 1 }
        dest = max(0, min(dest, copy.count))
        copy.insert(node, at: dest)
        return copy
    }

    /// 组内重排：定位到 `groupID` 的 children 数组，在其上复用 `moving` 的同一套算法。
    /// 找不到该组（或它不是 group）→ 原数组原样返回。
    static func movingWithinGroup(_ items: [PromptNode], groupID: String, fromChild: Int, toChild: Int) -> [PromptNode] {
        guard let gi = items.firstIndex(where: { $0.id == groupID && $0.type == "group" }) else { return items }
        var copy = items
        copy[gi].children = moving(copy[gi].children ?? [], fromTop: fromChild, toTop: toChild)
        return copy
    }

    /// 拖进分组：把 `actionID` 对应节点（不论当前在顶层还是另一个组里）挪到 `groupID`
    /// 这个组的 children 末尾。**两级封顶**：`actionID` 本身若是个 group（type=="group"）
    /// → 返回 nil（调用方据此忽略 + 触觉反馈，不落地这次 drop）。目标 `groupID` 不存在 /
    /// 不是 group / 与 actionID 相同 → 同样返回 nil。
    static func movingIntoGroup(_ items: [PromptNode], actionID: String, groupID: String) -> [PromptNode]? {
        guard actionID != groupID else { return nil }
        let (afterRemoval, removed) = removing(items, id: actionID)
        guard let node = removed, node.type != "group" else { return nil }
        guard let gi = afterRemoval.firstIndex(where: { $0.id == groupID && $0.type == "group" }) else { return nil }
        var copy = afterRemoval
        var children = copy[gi].children ?? []
        children.append(node)
        copy[gi].children = children
        return copy
    }

    /// 拖出分组：把 `childID` 从它所在的组里摘除，插回顶层数组的 `toTopIndex` 位置
    /// （越界会被夹到 [0, count] 合法范围）。找不到该 id → 原数组原样返回。
    static func movingOutOfGroup(_ items: [PromptNode], childID: String, toTopIndex: Int) -> [PromptNode] {
        let (afterRemoval, removed) = removing(items, id: childID)
        guard let node = removed else { return items }
        var copy = afterRemoval
        let idx = max(0, min(toTopIndex, copy.count))
        copy.insert(node, at: idx)
        return copy
    }

    /// 5b 过滤：action 按 appliesTo 命中锚点；group 保留命中的子项，全不命中则整组消失。
    static func filter(_ items: [PromptNode], for anchor: PromptAnchor) -> [PromptNode] {
        items.compactMap { filterNode($0, for: anchor) }
    }

    private static func filterNode(_ node: PromptNode, for anchor: PromptAnchor) -> PromptNode? {
        if node.type == "group" {
            let filteredChildren = filter(node.children ?? [], for: anchor)
            guard !filteredChildren.isEmpty else { return nil }
            var copy = node
            copy.children = filteredChildren
            return copy
        }
        guard let appliesTo = node.appliesTo, appliesTo.contains(anchor.rawValue) else { return nil }
        return node
    }

    /// 过滤结果 → ConfigMenu 现有输入形状。每个顶层 group 自成一个 section（视觉厚分隔）；
    /// 连续的顶层散 action 合并为一个共享 section；顺序保持。
    static func menuConfig(_ items: [PromptNode], for anchor: PromptAnchor) -> UIMenuConfig {
        let filtered = filter(items, for: anchor)
        var sections: [[UIMenuNode]] = []
        var pendingLoose: [UIMenuNode] = []

        for item in filtered {
            if item.type == "group" {
                if !pendingLoose.isEmpty {
                    sections.append(pendingLoose)
                    pendingLoose = []
                }
                sections.append([toMenuNode(item)])
            } else {
                pendingLoose.append(toMenuNode(item))
            }
        }
        if !pendingLoose.isEmpty {
            sections.append(pendingLoose)
        }
        return UIMenuConfig(groups: sections)
    }

    private static func toMenuNode(_ node: PromptNode) -> UIMenuNode {
        if node.type == "group" {
            let children = (node.children ?? []).map(toMenuNode)
            return UIMenuNode(id: node.id, label: node.label, type: "submenu", children: children, instruction: nil)
        }
        return UIMenuNode(id: node.id, label: node.label, type: nil, children: nil, instruction: node.prompt)
    }
}

// MARK: - 网络/缓存层

/// GET/PUT/restore-defaults 共用的响应外壳 {schema, items}。
private struct PromptsResponse: Decodable {
    let schema: Int
    let items: [PromptNode]
}

extension PromptLogic {
    /// Data → items，解码失败返回 nil（三级回退链的每一环都靠它判断"这环能不能用"）。
    static func decodeItems(_ data: Data) -> [PromptNode]? {
        try? JSONDecoder().decode(PromptsResponse.self, from: data).items
    }

    /// 三级回退的裁决：本次 GET 成功 → 用它；否则退回缓存；否则内置。任何一级解码
    /// 失败都静默落到下一级——长按永远有菜单。纯函数，不碰网络/UserDefaults，
    /// 调用方（PromptStore）负责把 Data 喂进来，方便单测。
    static func effectiveItems(fetched: Data?, cached: Data?, builtin: [PromptNode]) -> [PromptNode] {
        if let fetched, let items = decodeItems(fetched) { return items }
        if let cached, let items = decodeItems(cached) { return items }
        return builtin
    }

    /// 内置默认 = 服务端 DEFAULT_PROMPT_TEMPLATE 的解析形态，三级回退最后一环
    /// （网络 + 缓存都失败时兜底）。12 条 prompt 文案从已删除的旧长按菜单配置 store
    /// 的内置默认逐字搬（同一批调优过的文案）；sys_cartoon_explainer 是那份旧内置
    /// 默认里没有的一条，文案从服务端 GET /agent/prompts 原样拉取补全，与服务端模板一致。
    static let builtin: [PromptNode] = {
        guard let data = builtinJSON.data(using: .utf8),
              let nodes = try? JSONDecoder().decode([PromptNode].self, from: data) else {
            return []
        }
        return nodes
    }()

    private static let builtinJSON = #"""
    [
      {
        "id": "sys_style",
        "type": "group",
        "label": "图片风格",
        "origin": "system",
        "children": [
          {
            "id": "sys_cartoon",
            "type": "action",
            "label": "卡通",
            "origin": "system",
            "prompt": "把这张图（[[photo:{{KEY}}]]）重画成宫崎骏动画的手绘卡通风格，构图和主体不变，正文其他内容都不要动。",
            "appliesTo": [
              "image"
            ],
            "kind": "image"
          },
          {
            "id": "sys_ad",
            "type": "action",
            "label": "广告",
            "origin": "system",
            "prompt": "把这张图（[[photo:{{KEY}}]]）重新设计成一则商品广告。请从专业设计师的角度，结合本篇文章的内容和受众，打造一个精致、洗练的视觉设计。整体风格要现代、极简，不使用文字，可以加一些别的代替文字的元素。请通过合理的版式构成，最大限度地突出商品的魅力。正文其他内容都不要动。",
            "appliesTo": [
              "image"
            ],
            "kind": "image"
          },
          {
            "id": "sys_watercolor",
            "type": "action",
            "label": "水彩",
            "origin": "system",
            "prompt": "把这张图（[[photo:{{KEY}}]]）重画成通透的水彩画风格，构图和主体不变，正文其他内容都不要动。",
            "appliesTo": [
              "image"
            ],
            "kind": "image"
          },
          {
            "id": "sys_sketch",
            "type": "action",
            "label": "素描",
            "origin": "system",
            "prompt": "把这张图（[[photo:{{KEY}}]]）重画成铅笔素描风格，构图和主体不变，正文其他内容都不要动。",
            "appliesTo": [
              "image"
            ],
            "kind": "image"
          },
          {
            "id": "sys_oil",
            "type": "action",
            "label": "油画",
            "origin": "system",
            "prompt": "把这张图（[[photo:{{KEY}}]]）重画成古典油画风格，构图和主体不变，正文其他内容都不要动。",
            "appliesTo": [
              "image"
            ],
            "kind": "image"
          },
          {
            "id": "sys_film",
            "type": "action",
            "label": "胶片",
            "origin": "system",
            "prompt": "把这张图（[[photo:{{KEY}}]]）调成胶片摄影的质感和色调，构图和主体不变，正文其他内容都不要动。",
            "appliesTo": [
              "image"
            ],
            "kind": "image"
          }
        ]
      },
      {
        "id": "sys_rewrite",
        "type": "group",
        "label": "改写这段",
        "origin": "system",
        "children": [
          {
            "id": "sys_concise",
            "type": "action",
            "label": "更简洁",
            "origin": "system",
            "prompt": "把第{{LINE}}行（开头是\"{{QUOTE}}\"）改写得更简洁，意思不变，正文其他行都不要动。",
            "appliesTo": [
              "text"
            ]
          },
          {
            "id": "sys_casual",
            "type": "action",
            "label": "更口语",
            "origin": "system",
            "prompt": "把第{{LINE}}行（开头是\"{{QUOTE}}\"）改写得更口语、像平时说话，意思不变，正文其他行都不要动。",
            "appliesTo": [
              "text"
            ]
          },
          {
            "id": "sys_formal",
            "type": "action",
            "label": "更书面",
            "origin": "system",
            "prompt": "把第{{LINE}}行（开头是\"{{QUOTE}}\"）改写得更书面、更正式，意思不变，正文其他行都不要动。",
            "appliesTo": [
              "text"
            ]
          },
          {
            "id": "sys_expand",
            "type": "action",
            "label": "扩写一点",
            "origin": "system",
            "prompt": "把第{{LINE}}行（开头是\"{{QUOTE}}\"）扩写一点，补充细节但别啰嗦，正文其他行都不要动。",
            "appliesTo": [
              "text"
            ]
          }
        ]
      },
      {
        "id": "sys_insert",
        "type": "group",
        "label": "插入图片",
        "origin": "system",
        "children": [
          {
            "id": "sys_wechat_cover",
            "type": "action",
            "label": "公众号题图",
            "origin": "system",
            "prompt": "给这篇文章画一张微信公众号题图，放在文章最前面。画面为 2.45:1 的横幅比例。主视觉不要用泛泛的机器人形象或模糊的科技背景，要用具体的物件表达文章主题，比如提示词卡片、设计画布、图片生成面板、封面草稿。题图上的中文主标题从文章标题提炼，必须清晰可读，最好 6 到 10 个汉字。构图要适合公众号封面：大标题放左侧，主视觉放右侧，四周留足安全边距。风格：成熟的新媒体编辑部封面，干净、精致、实用，不要廉价营销海报感。避免：乱码文字、过多小字、真实品牌 logo、纯氛围壁纸、厚重的蓝紫渐变。正文其他内容都不要动。",
            "appliesTo": [
              "text"
            ],
            "kind": "image"
          },
          {
            "id": "sys_cartoon_explainer",
            "type": "action",
            "label": "卡通解释图",
            "origin": "system",
            "prompt": "给这篇文章画一张扁平卡通风格的解释图（flat cartoon explanation illustration），插入到正文最能帮助理解的位置，让没读过文章的人扫一眼就能看懂文章的核心结构。先读懂全文，找出核心结构——分几个阶段？有什么对比？有什么递进？——再把这个结构画出来。画幅比例由内容决定，以一眼读懂为准：双行对照用 3:2 或 4:3 横版，流程递进用横长条（2.45:1 或 3:1），层级深度用竖版（3:4 或 4:5），凝聚式概念用方形 1:1。风格：像 New Yorker 杂志插图、xkcd 或高级科普读物的插画，既有趣又有思想深度；人物几何化简化（火柴人或圆头方身），线条清晰，无写实细节；配色温暖克制，最多 4 到 5 种主色，建议米白底加深色线条加 1 到 2 个强调色（橙红、墨绿、深蓝任选）；质感纯平面或轻微手绘线条感，像在白纸上手绘的概念图，不像 PPT 或 Canva 模板。构图：把核心层级、阶段或对比关系分区并列展开（从左到右、上下分层或环形排布），用箭头、台阶、流程线等通用视觉符号连接各区；每个分区只画 1 个主场景加 1 个核心物件，不堆细节；每个分区可配 1 个 2 到 6 字的中文短标签，标签必须准确、可读、无伪汉字；分区之间留呼吸空间，整体不能挤。必须避免：真人脸部（用简化几何代替）、文字过多（只用关键标签，不是 PPT）、抽象到看不懂（必须能读图理解文章）、风格不统一、饱和霓虹、廉价渐变、3D 拟真、金属玻璃光泽、儿童读物感、中国风滥用、任何水印签名 Logo 二维码、错字漏字伪中文笔画。正文其他内容都不要动。",
            "appliesTo": [
              "text"
            ],
            "kind": "image"
          }
        ]
      }
    ]
    """#
}

struct SharePreview: Decodable {
    let label, prompt: String
    let appliesTo: [String]
    let kind: String?
    let author: String
    let importCount: Int
}

struct ShareState: Decodable {
    let code: String
    let sharing: Bool
}

@MainActor
@Observable
final class PromptStore {
    static let shared = PromptStore()

    private(set) var items: [PromptNode]
    var loading = false
    var error: String?
    /// 删除在途（从摘除节点到 save() 网络往返落定）。视图应在此为 true 时禁用删除
    /// 入口/忽略确认——不是性能优化，是防止两个几乎同时的删除并发跑：没有它，第二个
    /// 删除会在第一个的快照之上再摘一次，第一个失败回滚时会用自己那份旧快照整体
    /// 覆盖掉第二个已经成功的改动。
    private(set) var isMutating = false

    private static let cacheKey = "promptsCache.v1"
    private var token: String { AuthStore.shared.bearer }

    private init() {
        let cached = UserDefaults.standard.data(forKey: Self.cacheKey)
        items = PromptLogic.effectiveItems(fetched: nil, cached: cached, builtin: PromptLogic.builtin)
    }

    /// GET 整树。成功 → 缓存原始响应 + 更新 items；失败静默保留现值（init 时已经
    /// 用缓存/内置兜过底一次，长按菜单不会因为这次刷新失败就没有菜单）。
    func refresh() async {
        guard !token.isEmpty else { error = String(localized: "请先登录"); return }
        loading = true
        defer { loading = false }
        var req = URLRequest(url: API.agentBase.appendingPathComponent("prompts"))
        req.setBearer(token)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
              let fresh = PromptLogic.decodeItems(data) else {
            error = String(localized: "加载失败")
            return
        }
        error = nil
        items = fresh
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    /// PUT 整树（rawItems(items)）。nil = 成功；非 nil = 给用户看的错误文案。
    /// 成功后用响应回填 items（服务端会重算 origin 等派生字段）。
    func save() async -> String? {
        guard !token.isEmpty else { return String(localized: "请先登录") }
        guard let body = try? JSONSerialization.data(withJSONObject: ["items": PromptLogic.rawItems(items)]) else {
            return String(localized: "保存失败，请重试")
        }
        var req = URLRequest(url: API.agentBase.appendingPathComponent("prompts"))
        req.httpMethod = "PUT"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return String(localized: "网络出错，请重试")
        }
        guard resp.isOK else { return String(localized: "保存失败，请重试") }
        if let fresh = PromptLogic.decodeItems(data) {
            items = fresh
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
        return nil
    }

    /// 1b 左滑/长按删除：`PromptLogic.removing` 摘除该节点（顶层项，或组内子项——组被删
    /// 连子项一起，因为组本身就是一个节点），再 PUT 整树保存；失败**整体恢复删除前的
    /// 树快照**（不是按 (topIndex, childIndex) 单点插回——两个几乎同时的删除会让索引
    /// 在 await save() 网络往返期间悄悄挪位，按旧索引插回可能插进另一个节点里；
    /// `rawItem` 只序列化 group 的 children，插进 action 节点的子项下次 save 会静默消失）。
    /// `isMutating` 关住重入窗口：删除在途时忽略新的 delete 调用，视图对应地在此为 true
    /// 时禁用删除入口，两个删除永远不会重叠，索引/快照错位从根上不可能发生。
    /// nil = 成功；非 nil = 给用户看的错误文案（此时 items 已经恢复原状）。
    func delete(id: String) async -> String? {
        guard !isMutating else { return nil }
        let (newItems, removed) = PromptLogic.removing(items, id: id)
        guard removed != nil else { return nil }
        let snapshot = items
        isMutating = true
        items = newItems
        let err = await save()
        isMutating = false
        if let err {
            items = snapshot
            return err
        }
        return nil
    }

    /// 新建（3c）：把节点追加到列表末尾再整树 PUT；失败恢复追加前的快照。与 `delete`
    /// 同一套快照/`isMutating`纪律（见 `delete` 上的长注释）。nil = 成功；非 nil = 错误文案。
    func add(_ node: PromptNode) async -> String? {
        guard !isMutating else { return nil }
        let snapshot = items
        isMutating = true
        items.append(node)
        let err = await save()
        isMutating = false
        if let err {
            items = snapshot
            return err
        }
        return nil
    }

    /// fork-on-edit（5c 核心）+ 系统 group 改名同款 fork：原位替换 id 对应节点（`newNode.id`
    /// 可以和 id 不同——fork 换新 p_ id 时就是这样），整树 PUT；失败恢复替换前的快照。
    /// custom/user 直接编辑也走这条（`newNode.id == id`，等于原位改字段）。同一套
    /// 快照/`isMutating` 纪律（见 `delete` 上的长注释）。nil = 成功；非 nil = 错误文案。
    func replace(id: String, with newNode: PromptNode) async -> String? {
        guard !isMutating else { return nil }
        let snapshot = items
        isMutating = true
        items = PromptLogic.replacing(items, id: id, with: newNode)
        let err = await save()
        isMutating = false
        if let err {
            items = snapshot
            return err
        }
        return nil
    }

    /// Task 7「完成」：排序态整棵 draft 树一次性 PUT（这就是当初选整树写的原因——排序/
    /// 分组结构天然被一次 PUT 承载，不需要专门的"移动"端点）。失败**保留 draft 由调用方
    /// 处理**——这里只回滚 `items` 本身（不像 delete/add/replace 那样在此确定终态），
    /// 因为排序态是否要退出、draft 要不要留给用户重试，是视图层的决定（PromptManagerView：
    /// 失败就留在排序态，draft 原封不动，用户可以直接再按一次「完成」重试）。
    ///
    /// **冲突检测**：`baseline` 是进入排序态时的 store.items 扁平 id 序列。完成时如果当前 items
    /// 的 id 序列 ≠ baseline（表示期间有 import 等并发更新），拒绝此次 PUT 并返回
    /// 「列表已在别处更新，请重新调整顺序」，让视图保留排序态供用户重新理。
    ///
    /// 同一套 snapshot/`isMutating` 纪律（见 `delete` 上的长注释）。
    /// nil = 成功；非 nil = 给用户看的错误文案。
    func applyReorder(_ newItems: [PromptNode], baseline: [String]) async -> String? {
        guard !isMutating else { return nil }
        // 冲突检测：baseline 是进入排序前的 id 序列，现在的 items 序列应该完全相同（排序只改顺序不改内容）
        if PromptLogic.flattenIDs(items) != baseline {
            return String(localized: "列表已在别处更新，请重新调整顺序")
        }
        let snapshot = items
        isMutating = true
        items = newItems
        let err = await save()
        isMutating = false
        if let err {
            items = snapshot
            return err
        }
        return nil
    }

    /// POST /agent/prompts/import {code}。成功后刷新整树（服务端已经把新条目
    /// 追加进用户的 prompts.json，本地需要重新 GET 才能拿到完整、带派生字段的列表）。
    func importPrompt(code: String) async -> Result<PromptNode, PromptError> {
        guard !token.isEmpty else { return .failure(PromptError(message: String(localized: "请先登录"))) }
        struct P: Encodable { let code: String }
        var req = URLRequest(url: API.agentBase.appendingPathComponent("prompts/import"))
        req.httpMethod = "POST"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(P(code: code))
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return .failure(PromptError(message: String(localized: "网络出错，请重试")))
        }
        guard resp.isOK else {
            return .failure(PromptError(message: resp.httpStatusCode == 404
                ? String(localized: "这个魔法数字无效或已停止分享")
                : String(localized: "导入失败，请重试")))
        }
        struct R: Decodable { let item: PromptNode }
        guard let item = (try? JSONDecoder().decode(R.self, from: data))?.item else {
            return .failure(PromptError(message: String(localized: "导入失败，请重试")))
        }
        await refresh()
        return .success(item)
    }

    /// POST /agent/prompts/restore-defaults —— 补回模板里缺的，自建/改过的都不受影响。
    func restoreDefaults() async -> Bool {
        guard !token.isEmpty else { return false }
        var req = URLRequest(url: API.agentBase.appendingPathComponent("prompts/restore-defaults"))
        req.httpMethod = "POST"
        req.setBearer(token)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
              let fresh = PromptLogic.decodeItems(data) else { return false }
        items = fresh
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        return true
    }

    /// GET /agent/prompt-share/<code> —— 导入预览，公开端点，不带 bearer。
    func sharePreview(code: String) async -> SharePreview? {
        let req = URLRequest(url: API.agentBase.appendingPathComponent("prompt-share").appendingPathComponent(code))
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return nil }
        return try? JSONDecoder().decode(SharePreview.self, from: data)
    }

    /// GET /agent/prompt-shares —— 当前用户全部分享状态一览（5c 分享卡）。
    func shareStates() async -> [String: ShareState] {
        guard !token.isEmpty else { return [:] }
        var req = URLRequest(url: API.agentBase.appendingPathComponent("prompt-shares"))
        req.setBearer(token)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return [:] }
        struct R: Decodable { let byItem: [String: ShareState] }
        return (try? JSONDecoder().decode(R.self, from: data))?.byItem ?? [:]
    }

    /// 分享开关：开 = POST /agent/prompt-share 铸码/同码复活；关 = DELETE 使码立即
    /// 失效（服务端索引保留，再开还是同一个码）。沿用原 InstructionCustomStore.setSharing
    /// 的实现（含 429 → 「今天生成分享码的次数已达上限，明天再试」的文案映射）。
    func setSharing(id: String, on: Bool) async -> String? {
        guard !token.isEmpty else { return String(localized: "请先登录") }
        var req: URLRequest
        if on {
            struct P: Encodable { let id: String }
            req = URLRequest(url: API.agentBase.appendingPathComponent("prompt-share"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(P(id: id))
        } else {
            req = URLRequest(url: API.agentBase.appendingPathComponent("prompt-share").appendingPathComponent(id))
            req.httpMethod = "DELETE"
        }
        req.setBearer(token)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else {
            return String(localized: "网络出错，请重试")
        }
        guard resp.isOK else {
            return resp.httpStatusCode == 429
                ? String(localized: "今天生成分享码的次数已达上限，明天再试")
                : String(localized: "操作失败，请重试")
        }
        return nil
    }

    /// 过滤结果 → ConfigMenu 现有输入形状（长按菜单直接吃）。
    func menuConfig(for anchor: PromptAnchor) -> UIMenuConfig {
        PromptLogic.menuConfig(items, for: anchor)
    }
}
