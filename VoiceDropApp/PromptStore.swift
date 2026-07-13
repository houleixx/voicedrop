import Foundation

// Prompt Manager Phase 2（iOS）—— 模型 + 纯逻辑（网络层见 Task 3）。
// spec: docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §9
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 2

// MARK: - 模型

/// 服务端 resolved 节点（`GET /agent/prompts` 的 items 数组元素）。
/// 未知字段（如 `imageParams`）不声明 = Codable 自动忽略，不炸解码。
struct PromptNode: Codable, Identifiable, Equatable {
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
