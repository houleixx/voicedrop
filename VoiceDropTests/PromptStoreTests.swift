import XCTest
@testable import VoiceDrop

// Prompt Manager Phase 2 — Task 2: PromptStore 模型 + 纯逻辑单测。
// 全部用内嵌 JSON fixture，不打网络。参照
// docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 2。
final class PromptStoreTests: XCTestCase {

    // MARK: - 解码

    func testDecodeResolvedFixtureWithGroupChildrenKindForkedFrom() throws {
        let json = """
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
                "prompt": "把这张图重画成卡通风格",
                "appliesTo": ["image"],
                "kind": "image-style",
                "imageParams": {"strength": 0.5, "seed": 42}
              }
            ]
          },
          {
            "id": "p_abc12345",
            "type": "action",
            "label": "更简洁（自定义）",
            "origin": "custom",
            "prompt": "把这段改得更简洁",
            "appliesTo": ["text"],
            "forkedFrom": "sys_concise"
          }
        ]
        """.data(using: .utf8)!

        let nodes = try JSONDecoder().decode([PromptNode].self, from: json)
        XCTAssertEqual(nodes.count, 2)

        let group = nodes[0]
        XCTAssertEqual(group.id, "sys_style")
        XCTAssertEqual(group.type, "group")
        XCTAssertEqual(group.label, "图片风格")
        XCTAssertEqual(group.origin, "system")
        XCTAssertEqual(group.children?.count, 1)

        let child = try XCTUnwrap(group.children?.first)
        XCTAssertEqual(child.id, "sys_cartoon")
        XCTAssertEqual(child.prompt, "把这张图重画成卡通风格")
        XCTAssertEqual(child.appliesTo, ["image"])
        XCTAssertEqual(child.kind, "image-style")
        XCTAssertNil(child.forkedFrom)

        let custom = nodes[1]
        XCTAssertEqual(custom.origin, "custom")
        XCTAssertEqual(custom.forkedFrom, "sys_concise")
        XCTAssertEqual(custom.appliesTo, ["text"])
    }

    func testDecodeIgnoresUnknownFieldsWithoutError() throws {
        // imageParams（以及任何其它未来字段）必须被静默忽略,不炸解码。
        let json = """
        [{"id":"sys_ad","type":"action","label":"广告","origin":"system",
          "prompt":"p","appliesTo":["image"],
          "imageParams":{"nested":{"a":[1,2,3]},"flag":true}}]
        """.data(using: .utf8)!
        XCTAssertNoThrow(try JSONDecoder().decode([PromptNode].self, from: json))
    }

    // MARK: - rawItems

    func testRawItemsSystemRefWithChildren() throws {
        let node = PromptNode(id: "sys_style", type: "group", label: "图片风格", origin: "system", children: [
            PromptNode(id: "sys_cartoon", type: "action", label: "卡通", origin: "system", prompt: "p", appliesTo: ["image"]),
        ])
        let raw = PromptLogic.rawItems([node])
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw[0]["ref"] as? String, "sys_style")
        XCTAssertNil(raw[0]["label"])
        XCTAssertNil(raw[0]["prompt"])
        let children = try XCTUnwrap(raw[0]["children"] as? [[String: Any]])
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0]["ref"] as? String, "sys_cartoon")
        XCTAssertNil(children[0]["label"])
    }

    func testRawItemsCustomEntityFullFields() throws {
        let node = PromptNode(id: "p_abc12345", type: "action", label: "更简洁", origin: "custom",
                               prompt: "改简洁点", appliesTo: ["text"], kind: "rewrite", forkedFrom: "sys_concise")
        let raw = PromptLogic.rawItems([node])[0]
        XCTAssertEqual(raw["id"] as? String, "p_abc12345")
        XCTAssertEqual(raw["type"] as? String, "action")
        XCTAssertEqual(raw["label"] as? String, "更简洁")
        XCTAssertEqual(raw["prompt"] as? String, "改简洁点")
        XCTAssertEqual(raw["appliesTo"] as? [String], ["text"])
        XCTAssertEqual(raw["kind"] as? String, "rewrite")
        XCTAssertEqual(raw["forkedFrom"] as? String, "sys_concise")
        XCTAssertNil(raw["ref"])
    }

    func testRawItemsUserEntityOmitsAbsentOptionalFields() throws {
        let node = PromptNode(id: "p_xyz98765", type: "action", label: "新动作", origin: "user",
                               prompt: "做点什么", appliesTo: ["text", "image"])
        let raw = PromptLogic.rawItems([node])[0]
        XCTAssertNil(raw["forkedFrom"])
        XCTAssertNil(raw["kind"])
        XCTAssertNil(raw["ref"])
        XCTAssertEqual(raw["id"] as? String, "p_xyz98765")
    }

    func testRawItemsGroupEntityWithChildren() throws {
        let node = PromptNode(id: "p_group1", type: "group", label: "我的分组", origin: "user", children: [
            PromptNode(id: "p_child1", type: "action", label: "子项", origin: "user", prompt: "内容", appliesTo: ["text"]),
        ])
        let raw = PromptLogic.rawItems([node])[0]
        XCTAssertEqual(raw["id"] as? String, "p_group1")
        let children = try XCTUnwrap(raw["children"] as? [[String: Any]])
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0]["id"] as? String, "p_child1")
    }

    func testRawItemsRoundTripNoContentLeakForAllRefTree() throws {
        // 模板全 ref 的树:序列化后不含任何 label/prompt(引用不携带内容)。
        let tree = [
            PromptNode(id: "sys_a", type: "action", label: "A", origin: "system", prompt: "prompt A secret", appliesTo: ["text"]),
            PromptNode(id: "sys_group", type: "group", label: "Group", origin: "system", children: [
                PromptNode(id: "sys_b", type: "action", label: "B", origin: "system", prompt: "prompt B secret", appliesTo: ["image"]),
            ]),
        ]
        let raw = PromptLogic.rawItems(tree)
        let data = try JSONSerialization.data(withJSONObject: raw)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("label"))
        XCTAssertFalse(text.contains("prompt A secret"))
        XCTAssertFalse(text.contains("prompt B secret"))
        XCTAssertFalse(text.contains("\"prompt\""))
        XCTAssertTrue(text.contains("sys_a"))
        XCTAssertTrue(text.contains("sys_b"))
    }

    // MARK: - fork

    func testForkProducesNewIdForkedFromOriginCustomFieldsPreserved() {
        let node = PromptNode(id: "sys_concise", type: "action", label: "更简洁", origin: "system",
                               prompt: "把这段改简洁", appliesTo: ["text"], kind: "rewrite")
        let forked = PromptLogic.fork(node)
        XCTAssertNotNil(forked.id.range(of: "^p_[a-z0-9]{8}$", options: .regularExpression), "id was \(forked.id)")
        XCTAssertEqual(forked.forkedFrom, "sys_concise")
        XCTAssertEqual(forked.origin, "custom")
        XCTAssertEqual(forked.label, "更简洁")
        XCTAssertEqual(forked.prompt, "把这段改简洁")
        XCTAssertEqual(forked.appliesTo, ["text"])
        XCTAssertEqual(forked.kind, "rewrite")
        XCTAssertEqual(forked.type, "action")
    }

    func testForkTwiceProducesDifferentIds() {
        let node = PromptNode(id: "sys_concise", type: "action", label: "更简洁", origin: "system", prompt: "p", appliesTo: ["text"])
        let a = PromptLogic.fork(node)
        let b = PromptLogic.fork(node)
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - filter

    func testFilterTextOnlyAppearsOnlyInText() {
        let items = [PromptNode(id: "a", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["text"])]
        XCTAssertEqual(PromptLogic.filter(items, for: .text).count, 1)
        XCTAssertEqual(PromptLogic.filter(items, for: .image).count, 0)
    }

    func testFilterBothAnchorsAppearInBoth() {
        let items = [PromptNode(id: "a", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["text", "image"])]
        XCTAssertEqual(PromptLogic.filter(items, for: .text).count, 1)
        XCTAssertEqual(PromptLogic.filter(items, for: .image).count, 1)
    }

    func testFilterGroupWithMatchingChildKeepsOnlyMatchingChildren() {
        let group = PromptNode(id: "g", type: "group", label: "组", origin: "user", children: [
            PromptNode(id: "a", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["text"]),
            PromptNode(id: "b", type: "action", label: "B", origin: "user", prompt: "p", appliesTo: ["image"]),
        ])
        let filtered = PromptLogic.filter([group], for: .text)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].children?.count, 1)
        XCTAssertEqual(filtered[0].children?.first?.id, "a")
    }

    func testFilterGroupWithNoMatchDisappears() {
        let group = PromptNode(id: "g", type: "group", label: "组", origin: "user", children: [
            PromptNode(id: "a", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["image"]),
        ])
        XCTAssertEqual(PromptLogic.filter([group], for: .text).count, 0)
    }

    func testFilterEmptyGroupDoesNotAppear() {
        let group = PromptNode(id: "g", type: "group", label: "空组", origin: "user", children: [])
        XCTAssertEqual(PromptLogic.filter([group], for: .text).count, 0)
        XCTAssertEqual(PromptLogic.filter([group], for: .image).count, 0)
    }

    // MARK: - menuConfig

    func testMenuConfigMergesConsecutiveLooseActionsAndGroupsGetOwnSection() {
        let items: [PromptNode] = [
            PromptNode(id: "a1", type: "action", label: "A1", origin: "user", prompt: "p1", appliesTo: ["text"]),
            PromptNode(id: "a2", type: "action", label: "A2", origin: "user", prompt: "p2", appliesTo: ["text"]),
            PromptNode(id: "g1", type: "group", label: "组1", origin: "user", children: [
                PromptNode(id: "c1", type: "action", label: "C1", origin: "user", prompt: "p3", appliesTo: ["text"]),
            ]),
            PromptNode(id: "a3", type: "action", label: "A3", origin: "user", prompt: "p4", appliesTo: ["text"]),
        ]
        let config = PromptLogic.menuConfig(items, for: .text)
        XCTAssertEqual(config.groups.count, 3)
        XCTAssertEqual(config.groups[0].map(\.id), ["a1", "a2"])
        XCTAssertEqual(config.groups[1].map(\.id), ["g1"])
        XCTAssertEqual(config.groups[1][0].type, "submenu")
        XCTAssertEqual(config.groups[1][0].children?.count, 1)
        XCTAssertEqual(config.groups[2].map(\.id), ["a3"])
    }

    func testMenuConfigActionPromptBecomesInstructionAndGroupBecomesSubmenu() {
        let items = [PromptNode(id: "a1", type: "action", label: "A1", origin: "user", prompt: "指令文本", appliesTo: ["text"])]
        let config = PromptLogic.menuConfig(items, for: .text)
        XCTAssertEqual(config.groups[0][0].instruction, "指令文本")
        XCTAssertNil(config.groups[0][0].type)

        let groupItems = [PromptNode(id: "g1", type: "group", label: "组1", origin: "user", children: [
            PromptNode(id: "c1", type: "action", label: "C1", origin: "user", prompt: "p", appliesTo: ["text"]),
        ])]
        let groupConfig = PromptLogic.menuConfig(groupItems, for: .text)
        XCTAssertEqual(groupConfig.groups[0][0].type, "submenu")
        XCTAssertEqual(groupConfig.groups[0][0].label, "组1")
    }

    // MARK: - newUserID

    func testNewUserIDFormat() {
        let id = PromptLogic.newUserID()
        XCTAssertNotNil(id.range(of: "^p_[a-z0-9]{8}$", options: .regularExpression), "id was \(id)")
    }

    func testNewUserIDUniquenessOver1000Calls() {
        var seen = Set<String>()
        for _ in 0..<1000 {
            seen.insert(PromptLogic.newUserID())
        }
        XCTAssertEqual(seen.count, 1000)
    }
}
