//
//  Tests_iOS.swift
//  Tests iOS
//
//  Created by Evgeny Poberezkin on 17/01/2022.
//

import XCTest

class Tests_iOS: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use recording to get started writing UI tests.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}

// MARK: - B5 / B6 对话室挂载回归

/// 钉住三条契约：
/// ① 直聊里的纯文本行走新气泡，并带通道角标；② 只有附件、没有文字的草稿发得出去；
/// ③ 引用回复条与附件预览条画在输入栏上方、且不与输入栏重叠。
///
/// 定位只认 accessibilityIdentifier：语言无关，换皮不换锚点。
/// `popopx.inputBar.textField` / `.sendButton` / `.plusButton`、`popopx.bubble.channel`。
///
/// 跑之前要知道的：① 至 ④ 需要一台上有「活跃联系人的 1:1 会话」的设备——加好友是一次真实的 SMP
/// 握手，对端在另一台设备上，本机建不出这个联系人。没有这样的会话时那四条腿 `XCTSkip` 说实话，
/// 不给假绿；T0 不需要任何会话，永远真跑（壳层锚点 + B6 对群聊的排除项）。
@MainActor
final class PopopxChatRoomRegressionTests: XCTestCase {

    private enum Anchor {
        static let field = "popopx.inputBar.textField"
        static let send = "popopx.inputBar.sendButton"
        static let plus = "popopx.inputBar.plusButton"
        static let badge = "popopx.bubble.channel"
        static let headerPlus = "popopx.header.plus"
        static let identity = "popopx.header.identity"
    }

    private let groupTitle = "B6 Carveout"
    /// 会话列表每一行的验收锚点（`ChatsListView.swift:600`）—— 行的 AX 形状会随屏幕和挂载点变，锚点不会。
    private let rowAnchor = "popopx.row"
    private let markerPrefix = "popopx-regression"
    private let profileName = "CI Room Test"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - T0 壳层锚点 + 群聊排除项（不需要任何会话）

    func testT0ShellAnchorsAndGroupKeepsLegacyComposer() throws {
        launchToShell()
        XCTAssertTrue(anchor(Anchor.headerPlus).waitForExistence(timeout: 10),
                      "T0 壳层上没有 popopx.header.plus —— 顶栏没挂上，锚点全部无从谈起")
        assertHeaderFits(tag: "T0")
        XCTAssertFalse(anchorOnScreen(Anchor.field), "T0 会话列表上出现了输入条锚点，作用域泄漏了")

        let title = try ensureGroupChat()
        openChat(titled: title)
        XCTAssertFalse(anchor(Anchor.field).waitForExistence(timeout: 4),
                       "T0 群聊「\(title)」里出现了 popopx.inputBar.textField —— B6 的排除项漏了群聊")
        let legacy = legacyComposerProbe()
        XCTAssertNotNil(legacy,
                        "T0 群聊「\(title)」里新条旧条都没有：composer 整条没渲染，上一条断言是假的绿")
        NSLog("POPREG[T0] group '%@' keeps the legacy composer (%@)", title, legacy ?? "-")
    }

    // MARK: - T1 ① 纯文本气泡 + 通道角标

    func testT1PlainBubbleCarriesChannelBadge() throws {
        let chat = try openEligibleDirectChat(tag: "T1")
        let text = "\(markerPrefix)-\(UUID().uuidString.prefix(6))"
        try typeAndSend(text)

        let bubble = try waited(app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch,
                                15, "T1 发出去的「\(text)」没出现在会话「\(chat)」里")
        let badges = anchors(Anchor.badge)
        XCTAssertFalse(badges.isEmpty,
                       "T1 气泡画出来了，但整屏没有 popopx.bubble.channel —— B5 的 resolver 没给任何一行定到通道")
        guard let badge = badges.min(by: { abs($0.frame.midY - bubble.frame.maxY) < abs($1.frame.midY - bubble.frame.maxY) }) else { return }
        XCTAssertTrue(hit(badge), "T1 通道角标存在但点不到：它不在当前那一屏上")
        XCTAssertGreaterThanOrEqual(badge.frame.midY, bubble.frame.midY,
                                    "T1 角标在正文之上——它不该画在气泡上沿")
        XCTAssertLessThanOrEqual(badge.frame.midY, bubble.frame.maxY + 44,
                                 "T1 角标离这一行太远（\(Int(badge.frame.midY)) vs 行底 \(Int(bubble.frame.maxY))），不是这一行的角标")
        NSLog("POPREG[T1] chat=%@ text='%@' bubble=%@ badge=%@ label='%@'",
              chat, text, rect(bubble.frame), rect(badge.frame), badge.label)
    }

    // MARK: - T2 ② 仅附件、无文字的草稿

    func testT2AttachmentOnlyDraftSends() throws {
        _ = try openEligibleDirectChat(tag: "T2")
        let rowsBefore = app.cells.count
        let plus = anchor(Anchor.plus)
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "T2 没有 popopx.inputBar.plusButton")
        XCTAssertTrue(hit(plus), "T2 「+」锚点在但点不到")
        plus.tap()
        guard pickOnePhoto() else {
            throw XCTSkip("T2 驱动不到系统选图器（「+」面板里的相册项或选图器本身没在这台模拟器上起来），仅附件草稿发不发得出去未被验证")
        }
        let preview = try waitedOn(attachmentPreview, 10, "T2 选完图后输入栏上方没有附件预览")
        let send = anchor(Anchor.send)
        XCTAssertTrue(send.waitForExistence(timeout: 5), "T2 选完图后发送锚点没了")
        XCTAssertTrue(send.isEnabled,
                      "T2 有附件、无文字时发送键仍 disabled —— 空草稿判据又把附件吃掉了（B6 修过的那一条）")
        send.tap()
        XCTAssertTrue(waitUntil(25) { attachmentPreview() == nil },
                      "T2 点了发送，附件预览还在：这条草稿没被消费")
        XCTAssertTrue(waitUntil(10) { !anchor(Anchor.send).isEnabled },
                      "T2 发送之后发送键仍是可用态：草稿没清空")
        // 不拿行数当判据：ChatView 的消息流是 ScrollView+LazyVStack，行不是 cell，`app.cells` 恒为 0，
        // 用它断言"发出去了"会永远假失败。真判据在上面两条：预览被消费、发送键回到不可用。
        NSLog("POPREG[T2] attachment-only draft sent; preview was %@, cells %d → %d, images now %d",
              rect(preview.frame), rowsBefore, app.cells.count, app.images.count)
    }

    // MARK: - T3 ③ 引用回复条在输入栏上方

    func testT3ReplyStripSitsAboveInputBar() throws {
        _ = try openEligibleDirectChat(tag: "T3")
        let text = "\(markerPrefix)-quote-\(UUID().uuidString.prefix(6))"
        try typeAndSend(text)
        let bubble = try waitedOn({ self.app.staticTexts.matching(NSPredicate(format: "label == %@", text))
            .allElementsBoundByIndex.first { onScreen($0) } }, 15, "T3 发出的消息没出现")
        bubble.press(forDuration: 1.2)
        guard tapAny(["Reply", "回复"]) != nil else {
            throw XCTSkip("T3 长按消息后没有「回复」项（这台设备的消息菜单里没找到），遮挡校验没跑")
        }
        let bar = try waitedOn({ hit(self.anchor(Anchor.field)) ? self.anchor(Anchor.field) : nil },
                               6, "T3 点完回复后输入条锚点不可点")
        let strip = app.staticTexts.matching(NSPredicate(format: "label == %@", text))
            .allElementsBoundByIndex.first { onScreen($0) && $0.frame.maxY <= bar.frame.minY + 0.5 }
        XCTAssertNotNil(strip,
                        "T3 引用回复条没出现在输入栏上沿之上（「\(text)」只剩气泡那一处）")
        guard let strip else { return }
        assertNoOcclusion(strip, bar, tag: "T3", what: "引用回复条")
    }

    // MARK: - T4 ③ 附件预览条在输入栏上方

    func testT4AttachmentPreviewSitsAboveInputBar() throws {
        _ = try openEligibleDirectChat(tag: "T4")
        let plus = anchor(Anchor.plus)
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "T4 没有 popopx.inputBar.plusButton")
        plus.tap()
        guard pickOnePhoto() else {
            throw XCTSkip("T4 驱动不到系统选图器，附件预览条的几何校验没跑")
        }
        let preview = try waitedOn(attachmentPreview, 10, "T4 附件预览条没出现")
        let bar = anchor(Anchor.field)
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "T4 选完图后输入条锚点没了")
        assertNoOcclusion(preview, bar, tag: "T4", what: "附件预览条")
    }

    // MARK: - 几何断言

    /// 发现 A 的直接断言：顶栏两端的锚点必须整颗落在窗口里，「+」的热区还得 ≥44x44。
    /// 中间的状态胶囊夹在这两段之间，两端都在界内它就必然在界内 —— 不靠"能不能点到"反推。
    private func assertHeaderFits(tag: String) {
        let w = app.windows.firstMatch.frame
        var measured: [String] = []
        for id in [Anchor.identity, Anchor.headerPlus] {
            let e = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(e.waitForExistence(timeout: 8), "\(tag) 顶栏缺锚点 \(id)")
            let f = e.frame
            measured.append("\(id)=\(rect(f))")
            XCTAssertGreaterThanOrEqual(f.minX, w.minX,
                                        "\(tag) \(id) 越过左边界：\(rect(f)) window=\(rect(w))")
            XCTAssertLessThanOrEqual(f.maxX, w.maxX,
                                     "\(tag) \(id) 越过右边界：\(rect(f)) window=\(rect(w)) 内容比屏宽，顶栏又溢出了")
            XCTAssertGreaterThanOrEqual(f.minY, 0, "\(tag) \(id) 顶到状态条之上：\(rect(f))")
            XCTAssertLessThanOrEqual(f.maxY, w.maxY, "\(tag) \(id) 掉出下边界：\(rect(f))")
        }
        let plus = app.descendants(matching: .any).matching(identifier: Anchor.headerPlus).firstMatch.frame
        XCTAssertGreaterThanOrEqual(plus.width, 44, "\(tag) 「+」热区宽度 \(Int(plus.width)) < 44")
        XCTAssertGreaterThanOrEqual(plus.height, 44, "\(tag) 「+」热区高度 \(Int(plus.height)) < 44")
        NSLog("%@", "\(tag) header fits window=\(rect(w)) \(measured.joined(separator: " "))")
    }

    /// "在某条栏的上方"有两层：它自己点得到，且下沿压在该栏上沿之上、x 区间又真的重叠 ——
    /// 只比 y 会把"同一高度但跑到屏幕另一侧"的元素也判成通过。
    private func assertNoOcclusion(_ strip: XCUIElement, _ bar: XCUIElement, tag: String, what: String) {
        XCTAssertTrue(hit(strip), "\(tag) \(what) 存在但不可点")
        XCTAssertLessThanOrEqual(strip.frame.maxY, bar.frame.minY + 0.5,
                                 "\(tag) \(what) 压到了输入栏上沿：strip=\(rect(strip.frame)) bar=\(rect(bar.frame))")
        XCTAssertGreaterThan(strip.frame.maxX, bar.frame.minX,
                             "\(tag) \(what) 与输入栏 x 上不相交：strip=\(rect(strip.frame)) bar=\(rect(bar.frame))")
        XCTAssertLessThan(strip.frame.minX, bar.frame.maxX,
                          "\(tag) \(what) 与输入栏 x 上不相交：strip=\(rect(strip.frame)) bar=\(rect(bar.frame))")
        NSLog("POPREG[%@] %@ strip=%@ bar=%@ gap=%.1f", tag, what,
              rect(strip.frame), rect(bar.frame), bar.frame.minY - strip.frame.maxY)
    }

    // MARK: - 进入被测现场

    /// 从冷启动走到壳层。新装容器上的第一屏是「Network commitments / Accept」条款页，
    /// 它不在欢迎页之前、也不在导航栈里，所以逐个阶段试，且每一步都把点掉了什么写进日志。
    private func launchToShell() {
        app.launch()
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var nameTyped = false
        var stalled = 0
        for step in 1...90 {
            dismiss(sb, ["Allow", "Don’t Allow", "Don't Allow", "OK", "Continue", "Not Now"])
            if atShell() {
                NSLog("POPREG[shell] reached after %d step(s)", step)
                return
            }
            if let hitLabel = tapOnboardingAction(nameTyped: &nameTyped) {
                stalled = 0
                NSLog("POPREG[step %d] tapped '%@' on: %@", step, hitLabel, screenSignature())
                continue
            }
            // 连着六步无事可做 = 这一屏需要被看清，而不是再等 84 步。把整棵树里能点的东西
            // 连同 enabled 和 frame 打出来：是"CTA 被键盘盖住"还是"CTA 因为名字没打进而 disabled"，
            // 只有这两种，日志里一眼分得开。
            stalled += 1
            if stalled == 6 { NSLog("POPREG[stall@%d] %@", step, axDump()) }
            usleep(700_000)
        }
        NSLog("POPREG[shell] UNREACHABLE after 90 steps: %@ | %@", screenSignature(), axDump())
        XCTFail("走完 onboarding 仍到不了主界面（锚点 popopx.header.plus / 「消息」页都没出现）：见上一条 POPREG[shell] 现场")
    }

    /// 一次只做一个动作；没有已知动作就返回 nil，让调用方等一等再扫一遍。
    private func tapOnboardingAction(nameTyped: inout Bool) -> String? {
        if tapAny(["Create profile", "创建档案", "创建个人资料"]) != nil { return "create-profile" }
        if !nameTyped, let field = profileNameField() {
            field.tap()
            // 无条件输入：SwiftUI 空 TextField 的 `value` 里装的是占位文案（实测 value='Enter profile name...'），
            // 拿"value 非空"当"已经填过"，就永远填不进去，「Create profile」也就永远 en=0。
            field.typeText(profileName)
            nameTyped = true
            // 打完名字键盘还开着：375x812 上实测「Create profile」画在 y=701，正好在键盘底下。
            // 收键盘用这一页自己的开关（CreateProfile.swift:267 的 `.onTapGesture { focusDisplayName = false }`）
            // —— 点标题就是点空白，比往屏幕上乱点稳。
            if let title = app.staticTexts.matching(NSPredicate(format: "label == %@", "Your profile"))
                .allElementsBoundByIndex.first(where: { onScreen($0) }) {
                title.tap()
            }
            usleep(800_000)
            return "profile-name"
        }
        return tapAny(["Accept", "同意", "接受",
                       "Get started", "开始使用",
                       "Skip", "跳过", "Not now", "Later",
                       "Continue", "Next", "Done", "OK"])
    }

    /// 只在「这一屏确实是建档案」时认它的输入框，避免把名字打进别的表单。
    /// 判据只用在屏幕上真实存在的那两句：标题 `Your profile`（CreateProfile.swift:234）与
    /// 输入框占位 `Enter profile name...`（:309）。`Create profile` 是 Button 的标签，
    /// 不是 staticText，拿它当屏据永远匹配不上（375pt 上就是这么空转 90 步的）。
    private func profileNameField() -> XCUIElement? {
        guard screenHas(anyOf: ["Your profile", "Enter profile name",
                                "Your personal name", "创建档案", "local profile"]) else { return nil }
        return firstField(prompting: ["Enter profile name", "Your personal name", "你的名字"])
    }

    private func screenHas(anyOf words: [String]) -> Bool {
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        return words.contains { word in texts.contains { $0.contains(word) } }
    }

    private func screenSignature() -> String {
        let buttons = app.buttons.allElementsBoundByIndex.filter { onScreen($0) }.prefix(10).map { $0.label }
        let texts = app.staticTexts.allElementsBoundByIndex.filter { onScreen($0) }.prefix(8).map { $0.label }
        let fields = app.textFields.allElementsBoundByIndex.filter { onScreen($0) }.prefix(3).map { "field:\($0.label)" }
        return "btn=\(buttons) txt=\(texts) \(fields)"
    }

    /// 空转时把"屏上能点的东西、各自 enabled 与否、画在哪"整张打出来。
    /// "CTA 被键盘盖住"与"CTA 因为名字没打进而 disabled"是两种完全不同的修法，只有这一行分得开。
    private func axDump() -> String {
        let keyboard = app.keyboards.firstMatch.exists ? "keyboard=up" : "keyboard=down"
        let buttons = app.buttons.allElementsBoundByIndex.filter { onScreen($0) }.prefix(12).map { b in
            "'\(b.label)' en=\(b.isEnabled ? 1 : 0) \(rect(b.frame))"
        }
        let fields = app.textFields.allElementsBoundByIndex.filter { onScreen($0) }.prefix(4).map { f -> String in
            let v = (f.value as? String) ?? "?"
            return "'\(f.label)' value='\(v)'"
        }
        return "\(keyboard) buttons=[\(buttons.joined(separator: " ; "))] fields=[\(fields.joined(separator: " ; "))]"
    }

    private func atShell() -> Bool {
        guard !onboardingPending() else { return false }
        return anchorOnScreen(Anchor.headerPlus) || app.staticTexts["消息"].exists || app.buttons["消息"].exists
    }

    /// 条款页/建档案页是盖在壳层上的整屏层：`消息` 那一排 tab 标签在它下面照样 exists。
    /// 所以「到没到壳层」不能只看背后那层有没有画出来，还要看前面这一层收没收掉。
    private func onboardingPending() -> Bool {
        for label in ["Accept", "Create profile", "Get started", "同意", "创建档案", "开始使用"]
        where app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists { return true }
        return false
    }

    /// 找一个群聊；没有就照 CI 那条路子本地建一个（建群不出网）。都失败才 skip。
    private func ensureGroupChat() throws -> String {
        if let existing = chatRows(matching: groupTitle).first { return rowTitle(existing) }
        let plus = anchor(Anchor.headerPlus)
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "建群前找不到 popopx.header.plus")
        // 先量它在不在屏上再点：画到屏外时 tap() 会走 AXScrollToVisible，抛 kAXErrorFailure，
        // 把一条真实的"顶栏溢出"回归写成一句看不懂的仪器错误。
        guard onScreen(plus) else {
            let why = "顶栏「+」画在屏外：plus=\(rect(plus.frame)) window=\(rect(app.windows.firstMatch.frame))"
                + " —— 三段并排比屏宽，溢出的 HStack 居中，两端同时出界（测过的成因：中间胶囊被宿主 `fixedSize()`，ViewThatFits 收不到 proposal 停在最宽一档，见 PopopxTelemetryHeader.swift:477-490）"
            XCTFail(why)
            throw NSError(domain: "PopopxChatRoomRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: why])
        }
        plus.tap()
        usleep(1_500_000)
        guard tapAny(["发起群聊或加密频道", "Create group", "New group"]) != nil else {
            throw XCTSkip("T0 的「+」菜单里没有建群项，群聊排除项与角标两条断言之外的部分未验证")
        }
        usleep(2_500_000)
        let name = firstField(prompting: ["输入群名", "Enter group name"])
        guard let name, name.waitForExistence(timeout: 6) else {
            throw XCTSkip("T0 建群页上找不到群名输入框，群聊排除项未验证")
        }
        name.tap()
        name.typeText(groupTitle)
        usleep(800_000)
        guard tapAny(["创建群组", "Create group"]) != nil else {
            throw XCTSkip("T0 建群页上没有创建按钮，群聊排除项未验证")
        }
        usleep(4_000_000)
        // 建完群落在哪一层，两台机器给出过两种答案：402pt 回到列表（T0 直接过），375pt 停在
        // 「This group is missing servers」这张后到的卡片上 —— 卡片在场时三档定位全为空，
        // 屏上唯一带群名的元素是导航标题（实测 'B6 Carveout' 59,56 220x32）。
        // 先按卡片自己的文案点掉；点完还看不见行就重开应用：那条断言要测的是"列表里的群行走旧 composer"，
        // 重开之后列表是唯一在场的一层，比跟一张卡片的出现时序抢值得多。
        dismissGroupServerPrompt()
        if chatRows(matching: groupTitle).isEmpty {
            NSLog("POPREG[T0] 建群后列表里看不到新行，重开应用再测一次；当时屏上：%@", listShape(lookingFor: groupTitle))
            launchToShell()   // 它自己的第一步就是 app.launch()
        }
        XCTAssertTrue(waitUntil(20) { !self.chatRows(matching: self.groupTitle).isEmpty },
                      "T0 建完群在会话列表里找不到「\(groupTitle)」—— \(listShape(lookingFor: groupTitle))")
        // XCTAssert 失败不中止用例，所以这里不能回头去 `!` 那一行：直接交回自己起的名字，
        // 找不到由 openChat 那条断言来说，消息里带屏上实测。
        // 行标签整串是"标题, 副标题, 时间, 通道"，攥着它去重找等于每分钟抖一次。
        return groupTitle
    }

    /// 「This group is missing servers」是建群完成后**晚到**的现场确认层（冷启 375pt 实测：卡片压在列表上时
    /// Back 不存在、边缘滑动只拖动卡片本身，列表行只剩 staticText，唯一带群名的按钮是 59,56 的导航标题）。
    /// `app.sheets` 全程报 0，所以只能按卡片自己的文案等；等不到就继续 —— 有的配置根本不弹这一层。
    private func dismissGroupServerPrompt() {
        let title = ["This group is missing servers", "该群组缺少服务器"]
        let appeared = waitUntil(12) { self.screenHas(anyOf: title) }
        guard appeared else { return }
        XCTAssertTrue(waitUntil(10) {
            _ = self.tapAny(["Skip", "跳过", "Use current server", "使用当前服务器"])
            return !self.screenHas(anyOf: title)
        }, "T0 建群后的服务器卡片 10 秒内点不掉 —— \(listShape(lookingFor: groupTitle))")
    }

    /// 逐行点开列表里的会话，直到遇见一条挂上新输入条的（= 活跃联系人 1:1）。
    private func openEligibleDirectChat(tag: String) throws -> String {
        launchToShell()
        // 行标签是"标题, 副标题, 时间, 通道"拼出来的（实测：
        // "B6 Carveout, Chat with admins: on, 19:28, SMP 在线加密"），时间那一段会走。
        // 所以只取第一段当标题，回到列表时按前缀重找，不攥着上一屏的元素句柄；标题再去重。
        var titles: [String] = []
        for row in chatRows() where titles.count < 6 {
            let title = rowTitle(row)
            if !title.isEmpty, !titles.contains(title) { titles.append(title) }   // 同一行会翻出两个同前缀句柄
        }
        var opened: [String] = []
        var lost: [String] = []
        for title in titles {
            guard let row = chatRows(matching: title).first else {
                // 退回来时列表停在别的滚动位置 —— "这一屏没有"不是回归，记一笔继续下一行。
                lost.append(title)
                continue
            }
            opened.append(title)
            row.tap()
            usleep(2_500_000)
            if hit(anchor(Anchor.field)) {
                NSLog("POPREG[%@] eligible 1:1 chat = '%@'", tag, title)
                return title
            }
            backToShell()
        }
        let tried = opened.isEmpty ? "0 行" : "\(opened.count) 行（\(opened.joined(separator: "、"))）"
        let lostNote = lost.isEmpty ? "" : "；再找时已不在屏上：\(lost.joined(separator: "、"))"
        throw XCTSkip("\(tag) 这台设备上找不到挂了新输入条的 1:1 会话：列表里试过 " + tried + lostNote
            + "。需要一个活跃联系人才会有这条现场——加好友是一次真实的 SMP 握手，对端在另一台设备上。"
            + "（当时屏上：\(listShape(lookingFor: groupTitle))）")
    }

    /// 这一版会话列表不把行翻译成 cell（402pt iPhone 18 Pro 上实测 cells=0），
    /// 每一行是一个整宽的 Button。tab bar、顶栏胶囊、筛选 chip 都远窄于此，所以"宽度 ≥ 六成屏宽"
    /// 就是"这是一行会话"的判据 —— 换成 label 匹配会在中文/英文界面之间各测一遍。
    /// 三种屏上形状都接住，按可靠性排：
    /// 1) `popopx.row` 锚点（`ChatsListView.swift:600`）—— 不随语言、不随行的 AX 形状变；
    /// 2) List 翻译出的 cell；
    /// 3) 整宽 Button —— 没有锚点的旧列表：402pt 实测行是整宽 Button，而 tab bar / 顶栏胶囊 / 筛选 chip
    ///    都远窄于此，"宽度 ≥ 六成屏宽"就是"这是一行会话"；375pt 冷启实测同一行只剩包住标题的窄按钮
    ///    （'B6 Carveout' 220x32 @59,56），那条判据会把真行筛掉，所以它只排在最后。
    /// 行标签是"标题, 副标题, 时间, 通道"拼出来的，时间那一段会走 —— 匹配一律按前缀，不攥整串。
    private func chatRows() -> [XCUIElement] {
        let anchored = anchors(rowAnchor)
        if !anchored.isEmpty {
            var seen: [String] = []
            return anchored.filter { row in
                let key = rect(row.frame)
                if seen.contains(key) { return false }   // 同一行会翻出两个同框句柄
                seen.append(key)
                return true
            }
        }
        let cells = app.cells.allElementsBoundByIndex.filter { onScreen($0) && !$0.label.isEmpty }
        if !cells.isEmpty { return cells }
        let w = app.windows.firstMatch.frame
        return app.buttons.allElementsBoundByIndex
            .filter { onScreen($0) && $0.frame.width >= w.width * 0.6 && !$0.label.isEmpty }
    }

    /// 一行叫什么。`accessibilityIdentifier` 加在行容器上时，那一行的 AX `label` 是**空的**
    /// （容器不合并子元素；375pt 冷启实测：锚点找到了两行，`$0.label.contains(群名)` 仍全 false，
    /// 白跑一轮）。所以容器档从行框内部取标题：行里有头像、正文列和时间列，正主是左上角那条 ——
    /// 时间戳在右列、预览在它下面，先按 y 再按 x 排序就只剩标题。
    private func rowTitle(_ row: XCUIElement) -> String {
        let label = row.label
        if !label.isEmpty { return String(label.prefix(while: { $0 != "," })) }
        let f = row.frame
        let inside = app.staticTexts.allElementsBoundByIndex
            .filter { onScreen($0) && f.contains($0.frame) && !$0.label.isEmpty }
        return inside.min(by: { lhs, rhs in
            lhs.frame.minY != rhs.frame.minY ? lhs.frame.minY < rhs.frame.minY : lhs.frame.minX < rhs.frame.minX
        })?.label ?? ""
    }

    private func chatRows(matching title: String) -> [XCUIElement] {
        chatRows().filter { rowTitle($0).contains(title) }
    }

    /// 列表行"找不到"时，把这一屏上真实有什么打成一行：SwiftUI 会把同一行翻译成 cell、button
    /// 还是两组 staticText，只有实测知道。没有这句，每次都要重跑一遍才知道该改哪个定位器。
    /// 末尾那段是**带标题的按钮的几何**（不做 onScreen/宽度筛）：chatRows 是"标签命中 + 宽度达标 +
    /// 在屏内"三个条件与，只报"命中 0"分不清是哪种元素、还是被哪个筛子筛掉了 —— 375pt 上就是这么空转了一轮。
    private func listShape(lookingFor title: String) -> String {
        let cells = app.cells.allElementsBoundByIndex.filter { onScreen($0) }
        let buttons = app.buttons.allElementsBoundByIndex.filter { onScreen($0) }
        let texts = app.staticTexts.allElementsBoundByIndex.filter { onScreen($0) }
        let hits = texts.filter { $0.label.contains(title) }.count
        let titled = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title))
            .allElementsBoundByIndex.prefix(4)
            .map { "'\($0.label.prefix(14))' \(rect($0.frame))" }
            .joined(separator: " ; ")
        let anchored = anchors(rowAnchor)
        return "cells=\(cells.count){\(cells.prefix(4).map { $0.label }.joined(separator: " | "))} "
            + "buttons=\(buttons.count){\(buttons.prefix(6).map { $0.label }.joined(separator: " | "))} "
            + "staticTexts=\(texts.count)，「\(title)」命中 staticText x\(hits)、命中 cell x\(cells.filter { $0.label.contains(title) }.count)"
            + "；屏宽 \(rect(app.windows.firstMatch.frame)) 标题按钮 {\(titled)}"
            // 容器档单独报：锚点找到几行 + 每行从内部解析出的标题。上一轮就是在这里失明 ——
            // 日志只说"按钮命中 1、cell 命中 0"，看不出锚点档拿到了空 label 的行。
            + "；\(rowAnchor)=\(anchored.count)"
            + "{\(anchored.prefix(4).map { "'\(rowTitle($0))' \(rect($0.frame))" }.joined(separator: " ; "))}"
    }

    private func openChat(titled title: String) {
        let row = chatRows(matching: title).first
            ?? app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title))
                .allElementsBoundByIndex.first { onScreen($0) }
        XCTAssertNotNil(row, "会话列表里找不到「\(title)」那一行 —— \(listShape(lookingFor: title))")
        guard let row else { return }
        row.tap()
        usleep(2_500_000)
    }

    private func backToShell() {
        if tapAny(["Back", "返回"]) == nil {
            let w = app.windows.firstMatch.frame
            app.coordinate(withNormalizedOffset: CGVector(dx: 8 / w.width, dy: (w.height * 0.45) / w.height))
                .press(forDuration: 0.2, thenDragTo:
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        }
        usleep(1_500_000)
        _ = waitUntil(10) { self.atShell() }
    }

    // MARK: - 输入条上的动作

    @discardableResult private func typeAndSend(_ text: String) throws -> XCUIElement {
        let field = anchor(Anchor.field)
        XCTAssertTrue(field.waitForExistence(timeout: 8), "会话里没有 popopx.inputBar.textField")
        XCTAssertTrue(hit(field), "输入框在树里但点不到（被键盘或弹层挡住了？）")
        field.tap()
        field.typeText(text)
        let send = anchor(Anchor.send)
        XCTAssertTrue(waitUntil(8) { send.exists && send.isEnabled },
                      "打了字以后 popopx.inputBar.sendButton 仍是不可用态")
        send.tap()
        XCTAssertTrue(waitUntil(8) { self.anchor(Anchor.send).isEnabled == false },
                      "发送之后发送键仍可用：这条文本没发出去")
        return app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// 「+」面板 → 相册 → 系统选图器里选第一张 → Done/Add。任一步走不到就返回 false，由调用方 skip。
    private func pickOnePhoto() -> Bool {
        if tapAny(["相册", "Photo", "Photos"]) == nil { return false }
        let photo = app.collectionViews.buttons.element(boundBy: 0)
        let pickerButtons = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Add", "允许完全访问"]))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if pickerButtons.element(boundBy: 0).exists {
                let ok = pickerButtons.matching(NSPredicate(format: "label == %@", "允许完全访问")).element(boundBy: 0)
                if ok.exists { ok.tap(); usleep(1_500_000); continue }
                break
            }
            if photo.exists, hit(photo) { photo.tap(); usleep(1_500_000) }
            usleep(500_000)
        }
        let confirm = app.buttons["Done"].exists ? app.buttons["Done"] : app.buttons["Add"]
        guard confirm.exists else { return false }
        confirm.tap()
        usleep(2_500_000)
        return true
    }

    /// 输入栏上方那一块附件预览（缩略图），按几何认，不按标签认。
    private func attachmentPreview() -> XCUIElement? {
        let bar = anchor(Anchor.field)
        guard bar.exists else { return nil }
        let w = app.windows.firstMatch.frame
        return app.images.allElementsBoundByIndex.first { img in
            onScreen(img)
                && img.frame.maxY <= bar.frame.minY + 0.5
                && img.frame.minY > bar.frame.minY - 260
                && img.frame.midY > 0 && img.frame.midY < w.height
                && img.frame.width > 40
        }
    }

    /// 旧输入条的探针：底部那一块 UITextView（`NativeTextEditor`）或它的附件键。
    private func legacyComposerProbe() -> String? {
        let h = app.windows.firstMatch.frame.height
        if let tv = app.textViews.allElementsBoundByIndex.first(where: { onScreen($0) && $0.frame.midY > h * 0.6 }) {
            return "textView \(rect(tv.frame))"
        }
        for label in ["Attachements", "Attachments", "附件"] where app.buttons[label].exists && onScreen(app.buttons[label]) {
            return "button '\(label)'"
        }
        return nil
    }

    private func firstField(prompting prompts: [String]) -> XCUIElement? {
        for prompt in prompts {
            let byValue = app.textFields.matching(NSPredicate(format: "value CONTAINS %@", prompt))
            if let f = byValue.allElementsBoundByIndex.first(where: { onScreen($0) }) { return f }
            let byLabel = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", prompt))
            if let f = byLabel.allElementsBoundByIndex.first(where: { onScreen($0) }) { return f }
        }
        return app.textFields.allElementsBoundByIndex.first(where: { onScreen($0) })
            ?? app.textViews.allElementsBoundByIndex.first(where: { onScreen($0) })
    }

    // MARK: - 小工具

    private func anchor(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func anchors(_ id: String) -> [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex.filter { onScreen($0) }
    }

    private func anchorOnScreen(_ id: String) -> Bool {
        anchors(id).contains { $0.frame.width > 0 }
    }

    private func hit(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
    }

    /// 批量扫描时不用 `isHittable`：被裁切/半滚出的元素（列表里的「全部」筛选键）会直接抛
    /// `Activation point invalid`，把整条用例判死。这里只要"画在屏上"这一件事。
    private func onScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let f = element.frame
        let w = app.windows.firstMatch.frame
        guard f.width > 1, f.height > 1, f != .infinite else { return false }
        return f.midX >= w.minX && f.midX <= w.maxX && f.midY >= w.minY && f.midY <= w.maxY
    }

    private func waitUntil(_ seconds: Int, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if condition() { return true }
            usleep(400_000)
        }
        return condition()
    }

    private func waited(_ query: XCUIElement, _ seconds: Int, _ why: String) throws -> XCUIElement {
        XCTAssertTrue(query.waitForExistence(timeout: TimeInterval(seconds)), why)
        return query
    }

    /// 轮询到某个元素出现为止。等不到就是 failed，不是 skipped —— 现场已经在，是东西没画出来。
    private func waitedOn(_ read: () -> XCUIElement?, _ seconds: Int, _ why: String) throws -> XCUIElement {
        var found: XCUIElement?
        _ = waitUntil(seconds) {
            found = read()
            return found != nil
        }
        guard let value = found else {
            XCTFail(why)
            throw NSError(domain: "PopopxChatRoomRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
        }
        return value
    }

    @discardableResult private func tapAny(_ labels: [String]) -> String? {
        for label in labels {
            let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByIndex.filter { $0.isEnabled && onScreen($0) }
                + app.staticTexts.matching(NSPredicate(format: "label == %@", label))
                    .allElementsBoundByIndex.filter { onScreen($0) }
            // isHittable 只对这几个同名元素问：整棵树问会撞上被裁切的键，抛异常误判用例。
            if let target = candidates.first(where: { hit($0) }) {
                target.tap()
                return label
            }
        }
        return nil
    }

    private func dismiss(_ other: XCUIApplication, _ labels: [String]) {
        for label in labels where other.buttons[label].exists { other.buttons[label].tap(); usleep(600_000) }
    }

    private func rect(_ frame: CGRect) -> String {
        String(format: "%.0f,%.0f %.0fx%.0f", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)
    }
}
