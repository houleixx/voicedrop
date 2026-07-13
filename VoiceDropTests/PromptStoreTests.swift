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

    // Task 5：PromptEditView 保存语义的核心——dirty 后保存 = 先把编辑后的字段套进节点副本
    // （id 仍是原系统 id），再喂给 fork。这里直接模拟那一步：fork 的输入已经是编辑后的值，
    // 断言产物携带的是**编辑后**的字段，不是原始值，同时 forkedFrom 仍指向原始系统 id。
    func testForkWithEditsAppliesEditedFieldsAndPreservesForkedFrom() {
        let original = PromptNode(id: "sys_concise", type: "action", label: "更简洁", origin: "system",
                                   prompt: "把这段改简洁", appliesTo: ["text"], kind: "rewrite")
        var edited = original
        edited.label = "更简洁一点"
        edited.prompt = "把这段改得更简洁"
        edited.appliesTo = ["text", "image"]

        let forked = PromptLogic.fork(edited)
        XCTAssertNotNil(forked.id.range(of: "^p_[a-z0-9]{8}$", options: .regularExpression), "id was \(forked.id)")
        XCTAssertEqual(forked.forkedFrom, "sys_concise", "forkedFrom must point at the original system id, not the edited copy")
        XCTAssertEqual(forked.origin, "custom")
        XCTAssertEqual(forked.label, "更简洁一点")
        XCTAssertEqual(forked.prompt, "把这段改得更简洁")
        XCTAssertEqual(forked.appliesTo, ["text", "image"])
    }

    // group fork 只冻结 label（spec §3）：group 没有 prompt/appliesTo，children 原样带走。
    func testForkGroupCarriesChildrenAndHasNoPromptOrAppliesTo() {
        let group = PromptNode(id: "sys_style", type: "group", label: "图片风格", origin: "system", children: [
            PromptNode(id: "sys_cartoon", type: "action", label: "卡通", origin: "system", prompt: "p", appliesTo: ["image"]),
            PromptNode(id: "sys_ad", type: "action", label: "广告", origin: "system", prompt: "p2", appliesTo: ["image"]),
        ])
        var renamed = group
        renamed.label = "我的图片风格"

        let forked = PromptLogic.fork(renamed)
        XCTAssertNotNil(forked.id.range(of: "^p_[a-z0-9]{8}$", options: .regularExpression), "id was \(forked.id)")
        XCTAssertEqual(forked.forkedFrom, "sys_style")
        XCTAssertEqual(forked.origin, "custom")
        XCTAssertEqual(forked.type, "group")
        XCTAssertEqual(forked.label, "我的图片风格")
        XCTAssertNil(forked.prompt)
        XCTAssertNil(forked.appliesTo)
        XCTAssertEqual(forked.children?.map(\.id), ["sys_cartoon", "sys_ad"])
    }

    // MARK: - fork regression tests (Task 5: view-layer fork gating)

    /// Task 5 regression: fork applied then fields-restored doesn't produce node equal to original.
    /// Documenting that fork decision must happen at view layer only when values genuinely differ.
    func testForkIsNeverEqualToOriginal_soViewMustGateOnValueDiff() {
        let original = PromptNode(id: "sys_concise", type: "action", label: "更简洁", origin: "system",
                                   prompt: "把这段改简洁", appliesTo: ["text"], kind: "rewrite")
        var edited = original
        // Apply all edits
        edited.label = "更简洁一点"
        edited.prompt = "把这段改得更简洁"
        edited.appliesTo = ["text", "image"]

        let forked = PromptLogic.fork(edited)

        // Restore edited fields to original values
        var restored = forked
        restored.label = original.label
        restored.prompt = original.prompt
        restored.appliesTo = original.appliesTo

        // Fork id is different, so restored != original (fork decision must happen in view layer only)
        XCTAssertNotEqual(restored.id, original.id, "fork must produce a different id that persists even after field restoration")
        XCTAssertNotEqual(restored, original, "restored forked node must not equal original (different ids prove fork cannot be rolled back at view layer)")
    }

    // MARK: - replacing（Task 5：fork-on-edit / 系统 group 改名的原位替换，PromptStore.replace 用）

    func testReplacingWithIdenticalNodeStillSwapsById() {
        let original = PromptNode(id: "sys_a", type: "action", label: "A", origin: "system", prompt: "p", appliesTo: ["text"])
        let items = [
            original,
            PromptNode(id: "b", type: "action", label: "B", origin: "user", prompt: "p", appliesTo: ["text"]),
        ]
        // Forking the identical node produces new id but keeps all field values same
        let forked = PromptLogic.fork(original)
        let result = PromptLogic.replacing(items, id: "sys_a", with: forked)
        XCTAssertEqual(result.map(\.id), [forked.id, "b"], "replacing should swap by id even with identical field values")
        XCTAssertEqual(result[0].label, "A")
        XCTAssertEqual(result[0].prompt, "p")
        XCTAssertNotEqual(result[0].id, "sys_a", "replaced node should have new id from fork")
    }

    func testReplacingTopLevelNodeSwapsInPlaceEvenWithDifferentId() {
        let items = [
            PromptNode(id: "sys_a", type: "action", label: "A", origin: "system", prompt: "p", appliesTo: ["text"]),
            PromptNode(id: "b", type: "action", label: "B", origin: "user", prompt: "p", appliesTo: ["text"]),
        ]
        let forked = PromptNode(id: "p_new12345", type: "action", label: "A'", origin: "custom",
                                 prompt: "p'", appliesTo: ["text"], forkedFrom: "sys_a")
        let result = PromptLogic.replacing(items, id: "sys_a", with: forked)
        XCTAssertEqual(result.map(\.id), ["p_new12345", "b"])
        XCTAssertEqual(result[0].label, "A'")
    }

    func testReplacingChildInGroupKeepsSiblingsAndPosition() {
        let items = [
            PromptNode(id: "g", type: "group", label: "组", origin: "user", children: [
                PromptNode(id: "c1", type: "action", label: "C1", origin: "user", prompt: "p", appliesTo: ["text"]),
                PromptNode(id: "c2", type: "action", label: "C2", origin: "user", prompt: "p", appliesTo: ["text"]),
            ]),
        ]
        let replacement = PromptNode(id: "c1", type: "action", label: "C1 改名", origin: "user", prompt: "p", appliesTo: ["text"])
        let result = PromptLogic.replacing(items, id: "c1", with: replacement)
        XCTAssertEqual(result[0].children?.map(\.id), ["c1", "c2"])
        XCTAssertEqual(result[0].children?.first?.label, "C1 改名")
    }

    func testReplacingNonexistentIdLeavesItemsUnchanged() {
        let items = [PromptNode(id: "a", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["text"])]
        let replacement = PromptNode(id: "z", type: "action", label: "Z", origin: "user", prompt: "p", appliesTo: ["text"])
        let result = PromptLogic.replacing(items, id: "does-not-exist", with: replacement)
        XCTAssertEqual(result, items)
    }

    // MARK: - removing（MINOR 4：删除的位置逻辑抽成纯函数，单测覆盖）

    func testRemovingTopLevelAction() {
        let items = [
            PromptNode(id: "a", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["text"]),
            PromptNode(id: "b", type: "action", label: "B", origin: "user", prompt: "p", appliesTo: ["text"]),
        ]
        let (newItems, removed) = PromptLogic.removing(items, id: "a")
        XCTAssertEqual(newItems.map(\.id), ["b"])
        XCTAssertEqual(removed?.id, "a")
    }

    func testRemovingChildFromGroupKeepsOtherChildren() {
        let items = [
            PromptNode(id: "g", type: "group", label: "组", origin: "user", children: [
                PromptNode(id: "c1", type: "action", label: "C1", origin: "user", prompt: "p", appliesTo: ["text"]),
                PromptNode(id: "c2", type: "action", label: "C2", origin: "user", prompt: "p", appliesTo: ["text"]),
            ]),
        ]
        let (newItems, removed) = PromptLogic.removing(items, id: "c1")
        XCTAssertEqual(removed?.id, "c1")
        XCTAssertEqual(newItems.count, 1)
        XCTAssertEqual(newItems[0].id, "g")
        XCTAssertEqual(newItems[0].children?.map(\.id), ["c2"])
    }

    func testRemovingGroupRemovesItsChildrenToo() {
        let items = [
            PromptNode(id: "g", type: "group", label: "组", origin: "user", children: [
                PromptNode(id: "c1", type: "action", label: "C1", origin: "user", prompt: "p", appliesTo: ["text"]),
            ]),
            PromptNode(id: "a", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["text"]),
        ]
        let (newItems, removed) = PromptLogic.removing(items, id: "g")
        XCTAssertEqual(removed?.id, "g")
        XCTAssertEqual(removed?.children?.map(\.id), ["c1"])
        XCTAssertEqual(newItems.map(\.id), ["a"])
    }

    func testRemovingNonexistentIdLeavesItemsUnchangedAndReturnsNil() {
        let items = [
            PromptNode(id: "a", type: "action", label: "A", origin: "user", prompt: "p", appliesTo: ["text"]),
            PromptNode(id: "g", type: "group", label: "组", origin: "user", children: [
                PromptNode(id: "c1", type: "action", label: "C1", origin: "user", prompt: "p", appliesTo: ["text"]),
            ]),
        ]
        let (newItems, removed) = PromptLogic.removing(items, id: "does-not-exist")
        XCTAssertNil(removed)
        XCTAssertEqual(newItems, items)
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

    // MARK: - 内置回退（Task 3）

    /// 内置 = 服务端 DEFAULT_PROMPT_TEMPLATE 的解析形态：3 组（sys_style/sys_rewrite/
    /// sys_insert）+ 12 个 action，总节点数（组 + 递归 action）= 15。
    private func countNodes(_ nodes: [PromptNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + countNodes($1.children ?? []) }
    }
    private func countActions(_ nodes: [PromptNode]) -> Int {
        nodes.reduce(0) { $0 + ($1.type == "action" ? 1 : 0) + countActions($1.children ?? []) }
    }

    func testBuiltinHas15NodesAnd12Actions() {
        let builtin = PromptLogic.builtin
        XCTAssertEqual(countNodes(builtin), 15)
        XCTAssertEqual(countActions(builtin), 12)
    }

    func testBuiltinIdsUseSysPrefixAndKnownGroups() {
        let ids = Set(PromptLogic.builtin.map(\.id))
        XCTAssertEqual(ids, ["sys_style", "sys_rewrite", "sys_insert"])
        let styleChildren = Set(PromptLogic.builtin.first { $0.id == "sys_style" }?.children?.map(\.id) ?? [])
        XCTAssertEqual(styleChildren, ["sys_cartoon", "sys_ad", "sys_watercolor", "sys_sketch", "sys_oil", "sys_film"])
        let insertChildren = Set(PromptLogic.builtin.first { $0.id == "sys_insert" }?.children?.map(\.id) ?? [])
        XCTAssertEqual(insertChildren, ["sys_wechat_cover", "sys_cartoon_explainer"])
    }

    // MARK: - effectiveItems 三级回退裁决（纯函数，不打网络）

    func testEffectiveItemsPrefersFetchedOverCachedOverBuiltin() throws {
        let fetchedJSON = """
        {"schema":1,"items":[{"id":"p_fetched1","type":"action","label":"F","origin":"user","prompt":"p","appliesTo":["text"]}]}
        """.data(using: .utf8)!
        let cachedJSON = """
        {"schema":1,"items":[{"id":"p_cached01","type":"action","label":"C","origin":"user","prompt":"p","appliesTo":["text"]}]}
        """.data(using: .utf8)!
        let builtin = [PromptNode(id: "sys_builtin", type: "action", label: "B", origin: "system", prompt: "p", appliesTo: ["text"])]

        let fromFetched = PromptLogic.effectiveItems(fetched: fetchedJSON, cached: cachedJSON, builtin: builtin)
        XCTAssertEqual(fromFetched.map(\.id), ["p_fetched1"])

        let fromCached = PromptLogic.effectiveItems(fetched: nil, cached: cachedJSON, builtin: builtin)
        XCTAssertEqual(fromCached.map(\.id), ["p_cached01"])

        let fromBuiltin = PromptLogic.effectiveItems(fetched: nil, cached: nil, builtin: builtin)
        XCTAssertEqual(fromBuiltin.map(\.id), ["sys_builtin"])
    }

    func testEffectiveItemsCorruptFetchedFallsBackToCached() throws {
        let corrupt = "not json at all { [[[".data(using: .utf8)!
        let cachedJSON = """
        {"schema":1,"items":[{"id":"p_cached01","type":"action","label":"C","origin":"user","prompt":"p","appliesTo":["text"]}]}
        """.data(using: .utf8)!
        let result = PromptLogic.effectiveItems(fetched: corrupt, cached: cachedJSON, builtin: PromptLogic.builtin)
        XCTAssertEqual(result.map(\.id), ["p_cached01"])
    }

    /// 坏缓存（且没有本次 GET）→ 静默落到内置：15 节点。长按永远有菜单。
    func testEffectiveItemsCorruptCacheFallsBackToBuiltin() throws {
        let corrupt = "not json at all { [[[".data(using: .utf8)!
        let result = PromptLogic.effectiveItems(fetched: nil, cached: corrupt, builtin: PromptLogic.builtin)
        XCTAssertEqual(countNodes(result), 15)
        XCTAssertEqual(countActions(result), 12)
    }

    func testEffectiveItemsAllNilFallsBackToBuiltin() throws {
        let result = PromptLogic.effectiveItems(fetched: nil, cached: nil, builtin: PromptLogic.builtin)
        XCTAssertEqual(result.map(\.id), PromptLogic.builtin.map(\.id))
    }

    /// 有效但空的 fetched 必须返回空列表，不能落到缓存或内置（用户主动删除了所有项）。
    func testEffectiveItemsValidEmptyFetchedReturnsEmptyNotCachedOrBuiltin() throws {
        let emptyJSON = """
        {"schema":1,"items":[]}
        """.data(using: .utf8)!
        let cachedJSON = """
        {"schema":1,"items":[{"id":"p_cached01","type":"action","label":"C","origin":"user","prompt":"p","appliesTo":["text"]}]}
        """.data(using: .utf8)!
        let builtin = [PromptNode(id: "sys_builtin", type: "action", label: "B", origin: "system", prompt: "p", appliesTo: ["text"])]

        let result = PromptLogic.effectiveItems(fetched: emptyJSON, cached: cachedJSON, builtin: builtin)
        XCTAssertEqual(result.count, 0, "Empty valid payload must return empty list, not fall through to cache or builtin")
    }

    // MARK: - menuConfig 直接吃内置回退

    /// 内置下 .image：全部 6 个图片风格动作都挂在 sys_style 唯一一组下——1 个 section，
    /// 该 section 唯一节点是 submenu，children 有 6 个。
    func testMenuConfigImageFromBuiltinIsOneSectionWithSixChildren() {
        let config = PromptLogic.menuConfig(PromptLogic.builtin, for: .image)
        XCTAssertEqual(config.groups.count, 1)
        XCTAssertEqual(config.groups[0].count, 1)
        XCTAssertEqual(config.groups[0][0].type, "submenu")
        XCTAssertEqual(config.groups[0][0].children?.count, 6)
    }

    /// 内置下 .text：sys_rewrite（4 子项）+ sys_insert（2 子项）各自成组 → 2 个 section。
    func testMenuConfigTextFromBuiltinIsTwoSections() {
        let config = PromptLogic.menuConfig(PromptLogic.builtin, for: .text)
        XCTAssertEqual(config.groups.count, 2)
        XCTAssertEqual(config.groups[0].map(\.id), ["sys_rewrite"])
        XCTAssertEqual(config.groups[0][0].children?.count, 4)
        XCTAssertEqual(config.groups[1].map(\.id), ["sys_insert"])
        XCTAssertEqual(config.groups[1][0].children?.count, 2)
    }

    // MARK: - extractShareCode（Task 6：PromptImportSheet 粘贴解析 + universal link 边界）

    /// 8 位数字必须整体拒绝——服务端同款边界：`(?<![0-9])[1-9][0-9]{6}(?![0-9])`。若只取
    /// 正则本身「7 位数字」不带前后瞻，会把 8 位手机号片段的前 7 位误当魔法数字抠出来。
    func testExtractShareCodeEightDigitsReturnsNil() {
        XCTAssertNil(PromptLogic.extractShareCode("12345678"))
    }

    func testExtractShareCodeFromEmbeddedText() {
        XCTAssertEqual(PromptLogic.extractShareCode("用 4820135 改"), "4820135")
    }

    func testExtractShareCodeFromLink() {
        XCTAssertEqual(PromptLogic.extractShareCode("https://voicedrop.cn/4820135"), "4820135")
    }

    func testExtractShareCodeBareSevenDigits() {
        XCTAssertEqual(PromptLogic.extractShareCode("4820135"), "4820135")
    }

    func testExtractShareCodeNoDigitsReturnsNil() {
        XCTAssertNil(PromptLogic.extractShareCode("没有魔法数字的一段话"))
    }

    /// 首位数字不能是 0（服务端铸码规则），紧贴在 6 位数字前也凑不够 7 位——两种情况都该 nil。
    func testExtractShareCodeLeadingZeroRejected() {
        XCTAssertNil(PromptLogic.extractShareCode("0123456"))
    }

    /// 8 位数字不管多出来的那位贴在前面还是后面，边界都不干净——两种情况都该 nil，
    /// 只有真正独立的 7 位数字段才中。
    func testExtractShareCodeAdjacentDigitsOnEitherSideRejected() {
        XCTAssertNil(PromptLogic.extractShareCode("48201359"))     // 8 位，前 7 位后面还跟着数字
        XCTAssertNil(PromptLogic.extractShareCode("14820135"))     // 8 位，后 7 位前面还跟着数字
    }

    func testExtractShareCodePicksFirstMatchWhenMultiplePresent() {
        XCTAssertEqual(PromptLogic.extractShareCode("先是 4820135 后来又提到 9012345"), "4820135")
    }
}
