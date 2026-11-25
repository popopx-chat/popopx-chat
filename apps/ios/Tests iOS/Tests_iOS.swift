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

// MARK: - B5 / B6 chat room mount regression

/// Pins three contracts:
/// (a) a plain-text row in a direct chat uses the new bubble and carries the channel badge; (b) a draft with only an attachment and no text still sends;
/// (c) the reply quote strip and the attachment preview strip draw above the input bar and never overlap it.
///
/// Locators trust accessibilityIdentifier only: language-independent, a reskin never moves an anchor.
/// `popopx.inputBar.textField` / `.sendButton` / `.plusButton`, `popopx.bubble.channel`.
///
/// Before running them: legs one through four need a device holding a 1:1 chat with an active contact -- adding a friend is a real SMP
/// handshake, the peer lives on another device, and this device cannot create that contact. With no such chat those four legs call `XCTSkip` and tell the truth,
/// never a false green; T0 needs no chat at all and always really runs (shell anchors + the B6 carve-out for group chats).
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
    /// The acceptance anchor for every row of the chat list (`ChatsListView.swift:784`) -- the row's AX shape varies with the screen and the mount point, the anchor never does.
    private let rowAnchor = "popopx.row"
    private let markerPrefix = "popopx-regression"
    private let profileName = "CI Room Test"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - T0 shell anchors + the group-chat carve-out (needs no chat at all)

    func testT0ShellAnchorsAndGroupKeepsLegacyComposer() throws {
        launchToShell()
        XCTAssertTrue(anchor(Anchor.headerPlus).waitForExistence(timeout: 10),
                      "T0 has no popopx.header.plus on the shell -- the top bar never mounted, so every anchor is moot")
        assertHeaderFits(tag: "T0")
        XCTAssertFalse(anchorOnScreen(Anchor.field), "T0 shows an input-bar anchor on the chat list -- the scope leaked")

        let title = try ensureGroupChat()
        openChat(titled: title)
        XCTAssertFalse(anchor(Anchor.field).waitForExistence(timeout: 4),
                       "T0 group chat '\(title)' shows popopx.inputBar.textField -- the B6 carve-out missed group chats")
        let legacy = legacyComposerProbe()
        XCTAssertNotNil(legacy,
                        "T0 group chat '\(title)' has neither the new bar nor the old one: no composer rendered at all, so the assertion above is a false green")
        NSLog("POPREG[T0] group '%@' keeps the legacy composer (%@)", title, legacy ?? "-")
    }

    // MARK: - T1 (a) plain-text bubble + channel badge

    func testT1PlainBubbleCarriesChannelBadge() throws {
        let chat = try openEligibleDirectChat(tag: "T1")
        let text = "\(markerPrefix)-\(UUID().uuidString.prefix(6))"
        try typeAndSend(text)

        let bubble = try waited(app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch,
                                15, "T1 the sent '\(text)' never appeared in chat '\(chat)'")
        let badges = anchors(Anchor.badge)
        XCTAssertFalse(badges.isEmpty,
                       "T1 drew the bubble, but the whole screen has no popopx.bubble.channel -- the B5 resolver resolved a channel for no row at all")
        guard let badge = badges.min(by: { abs($0.frame.midY - bubble.frame.maxY) < abs($1.frame.midY - bubble.frame.maxY) }) else { return }
        XCTAssertTrue(hit(badge), "T1 the channel badge exists but is not hittable: it is not on the screen you are looking at")
        XCTAssertGreaterThanOrEqual(badge.frame.midY, bubble.frame.midY,
                                    "T1 the badge sits above the body text -- it must not draw at the bubble's top edge")
        XCTAssertLessThanOrEqual(badge.frame.midY, bubble.frame.maxY + 44,
                                 "T1 the badge is too far from this row (\(Int(badge.frame.midY)) vs row bottom \(Int(bubble.frame.maxY))) -- it is not this row's badge")
        NSLog("POPREG[T1] chat=%@ text='%@' bubble=%@ badge=%@ label='%@'",
              chat, text, rect(bubble.frame), rect(badge.frame), badge.label)
    }

    // MARK: - T2 (b) attachment-only draft, no text

    func testT2AttachmentOnlyDraftSends() throws {
        _ = try openEligibleDirectChat(tag: "T2")
        let rowsBefore = app.cells.count
        let plus = anchor(Anchor.plus)
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "T2 has no popopx.inputBar.plusButton")
        XCTAssertTrue(hit(plus), "T2 the '+' anchor is there but not hittable")
        plus.tap()
        guard pickOnePhoto() else {
            throw XCTSkip("T2 cannot drive the system photo picker (neither the album entry in the '+' panel nor the picker itself came up on this simulator), so whether an attachment-only draft sends is unverified")
        }
        let preview = try waitedOn(attachmentPreview, 10, "T2 no attachment preview above the input bar after picking the photo")
        let send = anchor(Anchor.send)
        XCTAssertTrue(send.waitForExistence(timeout: 5), "T2 the send anchor is gone after picking the photo")
        XCTAssertTrue(send.isEnabled,
                      "T2 with an attachment and no text the send button is still disabled -- the empty-draft check ate the attachment again (the one B6 fixed)")
        send.tap()
        XCTAssertTrue(waitUntil(25) { attachmentPreview() == nil },
                      "T2 tapped send and the attachment preview is still up: this draft was not consumed")
        XCTAssertTrue(waitUntil(10) { !anchor(Anchor.send).isEnabled },
                      "T2 after sending the send button is still enabled: the draft was not cleared")
        // Do not judge by the row count: ChatView's message stream is ScrollView+LazyVStack, its rows are not cells and `app.cells` stays 0,
        // so asserting "it sent" from that fails falsely forever. The real criteria are the two above: the preview got consumed, the send button went back to disabled.
        NSLog("POPREG[T2] attachment-only draft sent; preview was %@, cells %d → %d, images now %d",
              rect(preview.frame), rowsBefore, app.cells.count, app.images.count)
    }

    // MARK: - T3 (c) reply quote strip above the input bar

    func testT3ReplyStripSitsAboveInputBar() throws {
        _ = try openEligibleDirectChat(tag: "T3")
        let text = "\(markerPrefix)-quote-\(UUID().uuidString.prefix(6))"
        try typeAndSend(text)
        let bubble = try waitedOn({ self.app.staticTexts.matching(NSPredicate(format: "label == %@", text))
            .allElementsBoundByIndex.first { onScreen($0) } }, 15, "T3 the message that was sent never appeared")
        bubble.press(forDuration: 1.2)
        guard tapAny(["Reply", "Reply"]) != nil else {
            throw XCTSkip("T3 after the long press there was no 'Reply' item (this device's message menu did not carry one), so the occlusion check did not run")
        }
        let bar = try waitedOn({ hit(self.anchor(Anchor.field)) ? self.anchor(Anchor.field) : nil },
                               6, "T3 after tapping Reply the input-bar anchor is not hittable")
        let strip = app.staticTexts.matching(NSPredicate(format: "label == %@", text))
            .allElementsBoundByIndex.first { onScreen($0) && $0.frame.maxY <= bar.frame.minY + 0.5 }
        XCTAssertNotNil(strip,
                        "T3 the reply quote strip did not appear above the input bar's top edge ('\(text)' is left only at the bubble)")
        guard let strip else { return }
        assertNoOcclusion(strip, bar, tag: "T3", what: "reply quote strip")
    }

    // MARK: - T4 (c) attachment preview strip above the input bar

    func testT4AttachmentPreviewSitsAboveInputBar() throws {
        _ = try openEligibleDirectChat(tag: "T4")
        let plus = anchor(Anchor.plus)
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "T4 has no popopx.inputBar.plusButton")
        plus.tap()
        guard pickOnePhoto() else {
            throw XCTSkip("T4 cannot drive the system photo picker, so the attachment preview strip's geometry check did not run")
        }
        let preview = try waitedOn(attachmentPreview, 10, "T4 the attachment preview strip never appeared")
        let bar = anchor(Anchor.field)
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "T4 the input-bar anchor is gone after picking the photo")
        assertNoOcclusion(preview, bar, tag: "T4", what: "attachment preview strip")
    }

    // MARK: - Geometry assertions

    /// Finding A asserted directly: the anchors at both ends of the top bar must land wholly inside the window, and the '+' hit area must still be >= 44x44.
    /// The status capsule sits between those two segments, so when both ends are in bounds it must be too -- nothing inferred from "is it hittable".
    private func assertHeaderFits(tag: String) {
        let w = app.windows.firstMatch.frame
        var measured: [String] = []
        for id in [Anchor.identity, Anchor.headerPlus] {
            let e = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(e.waitForExistence(timeout: 8), "\(tag) top bar is missing the anchor \(id)")
            let f = e.frame
            measured.append("\(id)=\(rect(f))")
            XCTAssertGreaterThanOrEqual(f.minX, w.minX,
                                        "\(tag) \(id) crosses the left edge: \(rect(f)) window=\(rect(w))")
            XCTAssertLessThanOrEqual(f.maxX, w.maxX,
                                     "\(tag) \(id) crosses the right edge: \(rect(f)) window=\(rect(w)) content is wider than the screen, the top bar overflowed again")
            XCTAssertGreaterThanOrEqual(f.minY, 0, "\(tag) \(id) sits above the status bar: \(rect(f))")
            XCTAssertLessThanOrEqual(f.maxY, w.maxY, "\(tag) \(id) fell out of the bottom edge: \(rect(f))")
        }
        let plus = app.descendants(matching: .any).matching(identifier: Anchor.headerPlus).firstMatch.frame
        XCTAssertGreaterThanOrEqual(plus.width, 44, "\(tag) the '+' hit area is \(Int(plus.width)) wide < 44")
        XCTAssertGreaterThanOrEqual(plus.height, 44, "\(tag) the '+' hit area is \(Int(plus.height)) tall < 44")
        NSLog("%@", "\(tag) header fits window=\(rect(w)) \(measured.joined(separator: " "))")
    }

    /// "Above some bar" has two layers: the element is hittable itself, and its bottom edge stays above that bar's top edge while the x ranges really overlap --
    /// comparing y alone would also pass an element that is "at the same height but on the other side of the screen".
    private func assertNoOcclusion(_ strip: XCUIElement, _ bar: XCUIElement, tag: String, what: String) {
        XCTAssertTrue(hit(strip), "\(tag) \(what) exists but is not hittable")
        XCTAssertLessThanOrEqual(strip.frame.maxY, bar.frame.minY + 0.5,
                                 "\(tag) \(what) presses onto the input bar's top edge: strip=\(rect(strip.frame)) bar=\(rect(bar.frame))")
        XCTAssertGreaterThan(strip.frame.maxX, bar.frame.minX,
                             "\(tag) \(what) does not intersect the input bar on x: strip=\(rect(strip.frame)) bar=\(rect(bar.frame))")
        XCTAssertLessThan(strip.frame.minX, bar.frame.maxX,
                          "\(tag) \(what) does not intersect the input bar on x: strip=\(rect(strip.frame)) bar=\(rect(bar.frame))")
        NSLog("POPREG[%@] %@ strip=%@ bar=%@ gap=%.1f", tag, what,
              rect(strip.frame), rect(bar.frame), bar.frame.minY - strip.frame.maxY)
    }

    // MARK: - Getting into the scene under test

    /// Walk from a cold start to the shell. On a fresh container the first screen is the "Network commitments / Accept" terms page,
    /// which is neither ahead of the welcome page nor in the navigation stack, so try every stage and log what each step tapped off.
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
            // Six steps in a row with nothing to tap means this screen has to be looked at, not waited out for 84 more steps. Print everything tappable in the tree,
            // with its enabled state and frame: whether the CTA is "covered by the keyboard" or "disabled because the name never went in" --
            // those are the only two possibilities, and one line of log tells them apart at a glance.
            stalled += 1
            if stalled == 6 { NSLog("POPREG[stall@%d] %@", step, axDump()) }
            usleep(700_000)
        }
        NSLog("POPREG[shell] UNREACHABLE after 90 steps: %@ | %@", screenSignature(), axDump())
        XCTFail("onboarding ran to the end but the main interface never appeared (neither the popopx.header.plus anchor nor the 'Messages' page): see the POPREG[shell] scene just above")
    }

    /// One action at a time; when no known action is left it returns nil so the caller waits a moment and scans again.
    private func tapOnboardingAction(nameTyped: inout Bool) -> String? {
        // The v2 flow opens on the manifesto page, whose only forward action is `Create encrypted identity`
        // (OnboardingView.swift:94, POPOPXInfo.swift:215); it is not a substring of "Create profile", so without
        // this label every step of the walk found nothing and the shell was never reached.
        if tapAny(["Create encrypted identity"]) != nil { return "create-identity" }
        if tapAny(["Create profile", "Create profile", "Create profile"]) != nil { return "create-profile" }
        if !nameTyped, let field = profileNameField() {
            field.tap()
            // Type unconditionally: an empty SwiftUI TextField carries its placeholder text in `value` (measured value='Enter profile name...'),
            // so treating "value is not empty" as "already filled" never fills anything, and "Create profile" stays en=0 forever.
            field.typeText(profileName)
            nameTyped = true
            // The keyboard is still up after typing the name: on 375x812 "Create profile" measured at y=701, right underneath the keyboard.
            // Dismiss the keyboard with this page's own switch (`.onTapGesture { focusDisplayName = false }` at CreateProfile.swift:267)
            // -- tapping the title is tapping blank space, which beats tapping around the screen blindly.
            if let title = app.staticTexts.matching(NSPredicate(format: "label == %@", "Your profile"))
                .allElementsBoundByIndex.first(where: { onScreen($0) }) {
                title.tap()
            }
            // Screen 2 of v2 closes the keyboard from the field itself (`onSubmit: { _ in hideKeyboard() }`,
            // CreateProfile.swift:400), so Return releases the keyboard on both page variants; without it the
            // fixed bottom bar holds "Next" underneath the keyboard and nothing else on screen is tappable.
            app.typeText("\r")
            usleep(800_000)
            return "profile-name"
        }
        return tapAny(["Accept", "Agree", "Accept",
                       "Get started", "Get started",
                       "Skip", "Skip", "Not now", "Later",
                       "Continue", "Next", "Done", "OK"])
    }

    /// Recognise the field only when this screen really is the create-profile page, so the name never goes into some other form.
    /// The guard tests for copy that is on screen as a staticText; `Create profile` is a Button label upstream and `Next` is the
    /// button on v2, so neither is proof of the page on its own (on 375pt that is how 90 steps spun idle).
    private func profileNameField() -> XCUIElement? {
        // Screen 2 of the v2 flow is titled `Create your first anonymous identity` and its field is
        // `Anonymous name` / prompt `How you appear to contacts` (CreateProfile.swift:396-397); the upstream
        // sentences above only match the older page.
        guard screenHas(anyOf: ["Your profile", "Enter profile name",
                                "Your personal name", "Create profile", "local profile",
                                "anonymous identity", "Anonymous name"]) else { return nil }
        return firstField(prompting: ["Enter profile name", "Your personal name", "Your name",
                                      "How you appear to contacts", "Anonymous name"])
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

    /// When nothing moves, print the whole card: "what is tappable on screen, whether each one is enabled, and where it draws".
    /// "The CTA is covered by the keyboard" and "the CTA is disabled because the name never went in" need opposite fixes; only this line separates them.
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
        return anchorOnScreen(Anchor.headerPlus) || app.staticTexts["Messages"].exists || app.buttons["Messages"].exists
    }

    /// The terms page and the create-profile page are full-screen layers laid over the shell: the row of `Messages` tab labels still exists underneath them.
    /// So "did we reach the shell" cannot be judged from the layer behind being drawn alone -- the layer in front has to be dismissed as well.
    private func onboardingPending() -> Bool {
        for label in ["Accept", "Create profile", "Get started", "Agree", "Create profile", "Get started"]
        where app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists { return true }
        return false
    }

    /// Find a group chat; if there is none, create one locally the way CI does (creating a group stays off the network). Skip only when both fail.
    private func ensureGroupChat() throws -> String {
        if let existing = chatRows(matching: groupTitle).first { return rowTitle(existing) }
        let plus = anchor(Anchor.headerPlus)
        XCTAssertTrue(plus.waitForExistence(timeout: 8), "no popopx.header.plus found before creating the group")
        // Measure whether it is on screen before tapping: drawn outside the screen, tap() runs AXScrollToVisible and throws kAXErrorFailure,
        // rewriting a real "top bar overflow" regression into an unreadable instrumentation error.
        guard onScreen(plus) else {
            let why = "the top bar's '+' drew outside the screen: plus=\(rect(plus.frame)) window=\(rect(app.windows.firstMatch.frame))"
                + " -- the three segments side by side are wider than the screen, the overflowing HStack centres, so both ends leave the bounds at once (measured cause: the middle capsule is `fixedSize()` by its host, ViewThatFits receives no proposal and stops at the widest tier, see PopopxTelemetryHeader.swift:577-581)"
            XCTFail(why)
            throw NSError(domain: "PopopxChatRoomRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: why])
        }
        plus.tap()
        usleep(1_500_000)
        guard tapAny(["Start a group chat or an encrypted channel", "Create group", "New group"]) != nil else {
            throw XCTSkip("T0 the '+' menu had no create-group item, so everything beyond the group-chat carve-out and the badge assertions is unverified")
        }
        usleep(2_500_000)
        let name = firstField(prompting: ["Enter the group name", "Enter group name"])
        guard let name, name.waitForExistence(timeout: 6) else {
            throw XCTSkip("T0 the create-group screen has no group-name field, the group-chat carve-out is unverified")
        }
        name.tap()
        name.typeText(groupTitle)
        usleep(800_000)
        guard tapAny(["Create group", "Create group"]) != nil else {
            throw XCTSkip("T0 the create-group screen has no create button, the group-chat carve-out is unverified")
        }
        usleep(4_000_000)
        // Which layer you land on after creating the group drew two different answers on two machines: 402pt returns to the list (T0 passes straight through), 375pt stops
        // on the late-arriving "This group is missing servers" card -- while that card is up all three locator tiers come back empty,
        // and the only element on screen carrying the group name is the navigation title (measured 'B6 Carveout' 59,56 220x32).
        // Dismiss it first with the card's own copy; if the row is still invisible afterwards, relaunch the app: that assertion measures "group rows in the list keep the legacy composer",
        // and after a relaunch the list is the only layer present, which is worth far more than racing one card's arrival timing.
        dismissGroupServerPrompt()
        if chatRows(matching: groupTitle).isEmpty {
            NSLog("POPREG[T0] the new row is not in the list after creating the group, relaunching the app to measure once more; on screen at that moment: %@", listShape(lookingFor: groupTitle))
            launchToShell()   // its very first step is app.launch()
        }
        XCTAssertTrue(waitUntil(20) { !self.chatRows(matching: self.groupTitle).isEmpty },
                      "T0 after creating the group the chat list has no '\(groupTitle)' -- \(listShape(lookingFor: groupTitle))")
        // XCTAssert failing does not abort the test, so this must not fall through to the `!` line: hand back the name we started with,
        // and let openChat's assertion report the miss, with what was actually on screen in its message.
        // A row label is the whole "title, subtitle, time, channel" string, and holding on to it to re-find the row jitters once a minute.
        return groupTitle
    }

    /// "This group is missing servers" is the on-device confirmation layer that arrives **late**, after the group is created (cold start at 375pt measured: while the card sits over the list
    /// Back does not exist, the edge swipe only drags the card itself, list rows are nothing but staticText, and the only button carrying the group name is the navigation title at 59,56).
    /// `app.sheets` reports 0 the whole time, so the only option is to wait on the card's own copy; if it never shows, carry on -- some configurations do not put up this layer at all.
    private func dismissGroupServerPrompt() {
        let title = ["This group is missing servers", "This group is missing servers"]
        let appeared = waitUntil(12) { self.screenHas(anyOf: title) }
        guard appeared else { return }
        XCTAssertTrue(waitUntil(10) {
            _ = self.tapAny(["Skip", "Skip", "Use current server", "Use current server"])
            return !self.screenHas(anyOf: title)
        }, "T0 the servers card that follows group creation could not be dismissed within 10 seconds -- \(listShape(lookingFor: groupTitle))")
    }

    /// Open the chats in the list row by row until one carries the new input bar (= a 1:1 chat with an active contact).
    private func openEligibleDirectChat(tag: String) throws -> String {
        launchToShell()
        // A row label is assembled from "title, subtitle, time, channel" (measured:
        // "B6 Carveout, Chat with admins: on, 19:28, SMP online encrypted"), and the time segment moves.
        // So keep only the first segment as the title, re-find it by prefix once back in the list instead of holding a handle from the previous screen, and de-duplicate the titles.
        var titles: [String] = []
        for row in chatRows() where titles.count < 6 {
            let title = rowTitle(row)
            if !title.isEmpty, !titles.contains(title) { titles.append(title) }   // one row yields two handles sharing a prefix
        }
        var opened: [String] = []
        var lost: [String] = []
        for title in titles {
            guard let row = chatRows(matching: title).first else {
                // Coming back, the list can rest at a different scroll position -- "not on this screen" is not a regression: note it and take the next row.
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
        let tried = opened.isEmpty ? "0 rows" : "\(opened.count) rows (\(opened.joined(separator: ", ")))"
        let lostNote = lost.isEmpty ? "" : "; already off screen when re-finding: \(lost.joined(separator: ", "))"
        throw XCTSkip("\(tag) no 1:1 chat carrying the new input bar on this device: tried in the list " + tried + lostNote
            + ". This scene needs an active contact -- adding a friend is a real SMP handshake and the peer is on another device."
            + " (on screen at that moment: \(listShape(lookingFor: groupTitle)))")
    }

    /// This build of the chat list does not translate rows into cells (402pt iPhone 18 Pro, measured cells=0):
    /// every row is a full-width Button. The tab bar, the top bar capsule and the filter chips are all far narrower, so "width >= sixty percent of the screen width"
    /// is the criterion for "this is a chat row" -- matching by label instead would mean one measurement per locale, Chinese and English.
    /// All three on-screen shapes are handled, ranked by reliability:
    /// 1) the `popopx.row` anchor (`ChatsListView.swift:784`) -- unchanged by language and by the row's AX shape;
    /// 2) the cells that List translates to;
    /// 3) full-width Buttons -- the old list without anchors: at 402pt rows measured as full-width Buttons, while the tab bar / top bar capsule / filter chips
    ///    are all far narrower, so "width >= sixty percent of the screen width" means "this is a chat row"; at 375pt cold start the same row leaves only a narrow button around the title
    ///    ('B6 Carveout' 220x32 @59,56), and that criterion filters real rows out, so it ranks last.
    /// Row labels are assembled from "title, subtitle, time, channel" and the time segment moves -- always match by prefix, never hold the whole string.
    private func chatRows() -> [XCUIElement] {
        let anchored = anchors(rowAnchor)
        if !anchored.isEmpty {
            var seen: [String] = []
            return anchored.filter { row in
                let key = rect(row.frame)
                if seen.contains(key) { return false }   // one row yields two handles with the same frame
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

    /// What a row is called. With `accessibilityIdentifier` on the row container, that row's AX `label` is **empty**
    /// (a container does not merge its children; measured at 375pt cold start: the anchor found two rows, yet `$0.label.contains(groupName)` was false for both,
    /// burning a whole round). So the container tier takes the title from inside the row's frame: a row holds an avatar, a body column and a time column, and the real one is the top-left --
    /// the timestamp is in the right column and the preview under it, so sorting by y and then by x leaves only the title.
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

    /// When a list row "cannot be found", print one line with what is really on this screen: SwiftUI turns the same row into a cell, a button
    /// or two groups of staticText, and only measurement knows which. Without this line every rerun is spent discovering which locator to change.
    /// The final segment is the **geometry of the buttons carrying the title** (no onScreen/width filter): chatRows ANDs "label hit + wide enough +
    /// inside the screen", so reporting only "0 hits" cannot tell which kind of element it was or which filter dropped it -- at 375pt that is exactly how a round spun idle.
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
            + "staticTexts=\(texts.count), '\(title)' hit staticText x\(hits), hit cell x\(cells.filter { $0.label.contains(title) }.count)"
            + "; screen width \(rect(app.windows.firstMatch.frame)) titled buttons {\(titled)}"
            // The container tier reports on its own: how many rows the anchor found + the title parsed from inside each row. The last round went blind right here --
            // the log only said "button hits 1, cell hits 0", so nothing showed that the anchor tier had rows with empty labels.
            + "; \(rowAnchor)=\(anchored.count)"
            + "{\(anchored.prefix(4).map { "'\(rowTitle($0))' \(rect($0.frame))" }.joined(separator: " ; "))}"
    }

    private func openChat(titled title: String) {
        let row = chatRows(matching: title).first
            ?? app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title))
                .allElementsBoundByIndex.first { onScreen($0) }
        XCTAssertNotNil(row, "no row for '\(title)' in the chat list -- \(listShape(lookingFor: title))")
        guard let row else { return }
        row.tap()
        usleep(2_500_000)
    }

    private func backToShell() {
        if tapAny(["Back", "Back"]) == nil {
            let w = app.windows.firstMatch.frame
            app.coordinate(withNormalizedOffset: CGVector(dx: 8 / w.width, dy: (w.height * 0.45) / w.height))
                .press(forDuration: 0.2, thenDragTo:
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        }
        usleep(1_500_000)
        _ = waitUntil(10) { self.atShell() }
    }

    // MARK: - Actions on the input bar

    @discardableResult private func typeAndSend(_ text: String) throws -> XCUIElement {
        let field = anchor(Anchor.field)
        XCTAssertTrue(field.waitForExistence(timeout: 8), "no popopx.inputBar.textField in the chat")
        XCTAssertTrue(hit(field), "the field is in the tree but not hittable (covered by the keyboard or a sheet?)")
        field.tap()
        field.typeText(text)
        let send = anchor(Anchor.send)
        XCTAssertTrue(waitUntil(8) { send.exists && send.isEnabled },
                      "after typing, popopx.inputBar.sendButton is still disabled")
        send.tap()
        XCTAssertTrue(waitUntil(8) { self.anchor(Anchor.send).isEnabled == false },
                      "the send button is still enabled after sending: this text never went out")
        return app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// The '+' panel -> Album -> the first photo in the system picker -> Done/Add. Whichever step it cannot reach returns false and the caller skips.
    private func pickOnePhoto() -> Bool {
        if tapAny(["Album", "Photo", "Photos"]) == nil { return false }
        let photo = app.collectionViews.buttons.element(boundBy: 0)
        let pickerButtons = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Add", "Allow Full Access"]))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if pickerButtons.element(boundBy: 0).exists {
                let ok = pickerButtons.matching(NSPredicate(format: "label == %@", "Allow Full Access")).element(boundBy: 0)
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

    /// The attachment preview (the thumbnail) above the input bar: recognised by geometry, never by label.
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

    /// Probe for the legacy input bar: the UITextView near the bottom (`NativeTextEditor`) or its attachments button.
    private func legacyComposerProbe() -> String? {
        let h = app.windows.firstMatch.frame.height
        if let tv = app.textViews.allElementsBoundByIndex.first(where: { onScreen($0) && $0.frame.midY > h * 0.6 }) {
            return "textView \(rect(tv.frame))"
        }
        for label in ["Attachements", "Attachments", "Attach"] where app.buttons[label].exists && onScreen(app.buttons[label]) {
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

    // MARK: - Small tools

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

    /// Batch scans avoid `isHittable`: a clipped or half-scrolled element (the "All" filter button in the list) throws outright,
    /// `Activation point invalid`, which condemns the whole test. All that matters here is "drawn on screen".
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

    /// Poll until an element shows up. Not getting one is a failure, not a skip -- the scene is already there, something just did not draw.
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
            // Ask isHittable only of these same-named elements: asking the whole tree runs into clipped buttons, throws, and misjudges the test.
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

// MARK: - Onboarding screens 3 and 4, fit-on-one-screen criterion (iPhone 15 Pro 393x852)

/// The criterion trusts geometry, never locale: the bottom edge of the scroll container is the line "you see the end without scrolling",
/// so the lowest element in the container crossing it means this screen still needs a swipe down; how far that edge moves up after `swipeUp`
/// is the page's real scrollable distance. Print both together and any change to the padding has a basis.
/// The page number lands straight on the screen under test through the `-onboardingStage` launch argument: `EnumDefault.get()` reads
/// `UserDefaults.string(forKey:)`, and the argument domain outranks the persistent domain, so screens 3 and 4 can each be started alone.
/// Fewer than 12 elements counts as "asserting before the tree finished building" -- a gap is better than a false green.
@MainActor
final class PopopxOnboardingFitTests: XCTestCase {
    private struct Edge {
        let maxY: CGFloat
        let count: Int
        let culprit: String
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // Both legs need their own numbers: the first failure must not cancel the second leg's measurement.
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testA1Page3FitsOneScreen() throws {
        try measurePage(stage: "step3_ChooseServerOperators", tag: "P3")
    }

    func testA2Page4FitsOneScreen() throws {
        try measurePage(stage: "step4_NetworkCommitments", tag: "P4")
    }

    private func measurePage(stage: String, tag: String) throws {
        app.launchArguments = ["-onboardingStage", stage]
        app.launch()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 25),
                      "\(tag) launched with -onboardingStage \(stage) and there is no scroll container: \(signature())")
        XCTAssertTrue(waitUntil(20) { edge(of: scroll).count >= 12 },
                      "\(tag) fewer than 12 elements inside the container, so the edge that was measured does not count: \(signature())")
        let viewport = scroll.frame
        let before = edge(of: scroll)
        attach(tag: tag)
        scroll.swipeUp()
        usleep(800_000)
        let after = edge(of: scroll)
        let line = String(format: "POPFIT[%@] viewport=%@ before=%@ after=%@ elements=%d overflow=%.1f scrollable=%.1f",
                          tag, box(viewport), y(before.maxY), y(after.maxY), before.count,
                          before.maxY - viewport.maxY, before.maxY - after.maxY)
        NSLog("%@ culprit=%@", line, before.culprit)
        XCTAssertLessThanOrEqual(before.maxY, viewport.maxY + 2,
                                 "\(tag) has \(String(format: "%.0f", before.maxY - viewport.maxY))pt"
                                 + " of content drawn below the viewport (content maxY \(y(before.maxY)) vs viewport maxY \(y(viewport.maxY))), "
                                 + "the lowest element is '\(before.culprit)' -- this screen still needs a swipe down")
    }

    private func edge(of scroll: XCUIElement) -> Edge {
        var maxY: CGFloat = -10_000
        var count = 0
        var culprit = "-"
        for element in scroll.descendants(matching: .any).allElementsBoundByIndex {
            let frame = element.frame
            guard frame != .infinite, frame.width > 0, frame.height > 0, frame.maxY < 100_000 else { continue }
            count += 1
            if frame.maxY > maxY {
                maxY = frame.maxY
                culprit = "\(element.elementType.rawValue) '\(element.label.prefix(36))' \(box(frame))"
            }
        }
        return Edge(maxY: maxY, count: count, culprit: culprit)
    }

    private func attach(tag: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "onboarding-\(tag)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func signature() -> String {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(8)
            .map { "'\($0.label.prefix(24))' en=\($0.isEnabled ? 1 : 0)" }
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(8).map { "'\($0.label.prefix(24))'" }
        return "scrollViews=\(app.scrollViews.count) win=\(box(app.windows.firstMatch.frame))"
            + " btn=[\(buttons.joined(separator: " ; "))] txt=[\(texts.joined(separator: " ; "))]"
    }

    private func waitUntil(_ seconds: Int, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if condition() { return true }
            usleep(400_000)
        }
        return condition()
    }

    private func box(_ frame: CGRect) -> String {
        String(format: "%.0f,%.0f %.0fx%.0f", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)
    }

    private func y(_ value: CGFloat) -> String {
        String(format: "%.0f", value)
    }
}

// MARK: - On-device round 5: top bar geometry self-check (temporary probe, ruled out of the repo)

/// Every criterion comes from the three numbers hard-coded in the code, trusting neither locale nor screenshots:
/// - the identity capsule's height is `.frame(height: PopopxMetrics.space2XL)` = 48 (`PopopxTelemetryHeader.swift:239`),
///   wrapping cannot move that number structurally, so "measured 48" is the evidence of a single line; the width ceiling is
///   `PopopxMetrics.headerIdentityMaxWidth` = 115 (`PopopxTheme.swift:189`).
/// - this round the outer ring of the dot tier is locked to a 32x32 square (`.frame(width: spaceXL, height: spaceXL)` + `.circle`),
///   the previous build used a "width 32 + height 48" capsule, so besides counting the circles it asserts on its own that tall 32x48 ovals in the band are 0.
/// - the row does not overflow: the mark at the left end and the '+' at the right end must both be inside the window (the worst budget at the 393pt tier is 391).
/// Two phases: measure the current identity first, then pick the longest name out of the identity switcher and measure it again. When there is no longer name
/// the second phase skips itself and says so -- a skip is a conclusion too, not a green light.
final class PopopxHeaderR15Tests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    func testH1TopBarGeometryAndScreenshot() throws {
        app.launch()
        let identity = any("popopx.header.identity")
        XCTAssertTrue(identity.waitForExistence(timeout: 25),
                      "H1 the top bar has no popopx.header.identity -- the app is not parked on the 'Messages' page (onboarding / lock screen / some other page), so this round's geometry cannot be measured")
        usleep(1_500_000)
        let window = app.windows.firstMatch.frame
        measure(tag: "now", window: window, identity: identity, shot: "R15-tab1-now")

        // Re-measure the longest display name: the switcher is a `.menu` style Picker that opens as a column of identity names.
        let current = displayName(identity)
        identity.tap()
        usleep(900_000)
        let names = app.descendants(matching: .button).allElementsBoundByIndex
            .map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0 != current }
        guard let longest = names.max(by: { $0.count < $1.count }), longest.count > current.count else {
            NSLog("%@", "POPHDR[R15] LONG-SKIP the switcher has no identity name longer than the current one (now '\(current)' "
                        + "\(current.count) characters, candidates=\(names.prefix(6).joined(separator: " / ")))"
                        + " -- the longest-name tier was never walked on real hardware, leaving only the structural evidence above: the 115 ceiling and the fixed 48 height")
            return
        }
        app.descendants(matching: .button).matching(NSPredicate(format: "label == %@", longest)).firstMatch.tap()
        XCTAssertTrue(waitUntil(12) { displayName(any("popopx.header.identity")) == longest },
                      "H1 after switching to '\(longest)' (\(longest.count) characters) the top bar still reads"
                      + "'\(displayName(any("popopx.header.identity")))' -- the switch never landed, so the numbers below do not count")
        usleep(600_000)
        measure(tag: "long", window: window, identity: any("popopx.header.identity"), shot: "R15-tab1-long")

        // Switching over obliges switching back: this leg reads the user's own phone, so a re-test starts from the identity he had.
        let back = any("popopx.header.identity")
        back.tap()
        usleep(900_000)
        let original = app.descendants(matching: .button).matching(NSPredicate(format: "label == %@", current)).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 8), "H1 the switcher has no original identity '\(current)', so nothing was switched back")
        original.tap()
        XCTAssertTrue(waitUntil(12) { displayName(any("popopx.header.identity")) == current },
                      "H1 could not switch back to the original identity '\(current)' (the top bar now reads '\(displayName(any("popopx.header.identity")))') -- switch back by hand before re-testing")
        NSLog("POPHDR[R15] restored identity='%@' on top bar", current)
    }

    private func measure(tag: String, window: CGRect, identity: XCUIElement, shot: String) {
        let idf = identity.frame
        let name = displayName(identity)
        XCTAssertGreaterThanOrEqual(idf.height, 46, "H1[\(tag)] the identity capsule is \(Int(idf.height)) tall < 46: the 48 tier got pushed out of true")
        XCTAssertLessThanOrEqual(idf.height, 50,
                                "H1[\(tag)] the identity capsule is \(Int(idf.height)) tall > 50: beyond the fixed height 48 only wrapping can move this")
        XCTAssertLessThanOrEqual(idf.width, 116,
                                 "H1[\(tag)] the identity capsule is \(Int(idf.width)) wide, past the ceiling 115 -- "
                                 + "the name '\(name)' (\(name.count) characters) was not truncated")
        XCTAssertGreaterThanOrEqual(idf.minX, window.minX, "H1[\(tag)] the identity capsule is past the window's left edge: \(rect(idf)) window=\(rect(window))")

        let mark = any("popopx.header.mark")
        let plus = any("popopx.header.plus")
        XCTAssertTrue(mark.waitForExistence(timeout: 8) && plus.waitForExistence(timeout: 8),
                      "H1[\(tag)] missing popopx.header.mark / popopx.header.plus, so the budget for the whole row cannot be judged")
        let mf = mark.frame
        let pf = plus.frame
        XCTAssertGreaterThanOrEqual(mf.minX, window.minX, "H1[\(tag)] the brand mark is past the left edge: \(rect(mf))")
        XCTAssertLessThanOrEqual(pf.maxX, window.maxX + 0.5,
                                 "H1[\(tag)] the '+' right edge \(Int(pf.maxX)) is past the window's right edge \(Int(window.maxX)) -- this top bar row still overflowed")
        XCTAssertGreaterThanOrEqual(pf.width, 44, "H1[\(tag)] the '+' hit area \(Int(pf.width))x\(Int(pf.height)) is under 44 wide")
        XCTAssertGreaterThanOrEqual(pf.height, 44, "H1[\(tag)] the '+' hit area \(Int(pf.width))x\(Int(pf.height)) is under 44 tall")

        var rounds: [String] = []
        var ovals: [String] = []
        for element in headerBand(around: idf) {
            let f = element.frame
            if abs(f.width - 32) <= 1.5 && abs(f.height - 32) <= 1.5 {
                rounds.append("\(element.elementType.rawValue) '\(clip(element.label))' \(rect(f))")
            } else if abs(f.width - 32) <= 1.5 && f.height >= 46 {
                ovals.append("\(element.elementType.rawValue) '\(clip(element.label))' \(rect(f))")
            }
        }
        XCTAssertGreaterThanOrEqual(rounds.count, 2,
                                    "H1[\(tag)] the top bar band measured only \(rounds.count) of the 32x32 circles (network + Bluetooth, both expected): \(rounds)")
        XCTAssertTrue(ovals.isEmpty,
                      "H1[\(tag)] the top bar band still holds tall ovals 32 wide x >=46 high (the shape of the previous tier): \(ovals)")
        NSLog("%@", "POPHDR[R15][\(tag)] name='\(name)'(\(name.count)) window=\(rect(window)) "
                    + "identity=\(rect(idf)) mark=\(rect(mf)) badge=\(rect(any("popopx.header.badge").frame)) "
                    + "plus=\(rect(pf)) rounds=\(rounds.count) [\(rounds.joined(separator: " ; "))] "
                    + "ovals=\(ovals.count) [\(ovals.joined(separator: " ; "))]")

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = shot
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The horizontal top bar band: 8pt above and below the identity capsule's edges, keeping only elements that fall inside the band and really drew.
    private func headerBand(around idf: CGRect) -> [XCUIElement] {
        var seen: [XCUIElement] = []
        for query in [app.otherElements, app.buttons, app.groups, app.images] {
            for element in query.allElementsBoundByIndex {
                let f = element.frame
                guard f != .infinite, f.width > 0, f.height > 0, f.maxY < 100_000 else { continue }
                guard f.midY >= idf.minY - 8, f.midY <= idf.maxY + 8 else { continue }
                seen.append(element)
            }
        }
        return seen
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The top bar one is a `.menu` style `Picker`: its `accessibilityLabel` holds the "switch identity" sentence,
    /// while the real display name lives in `accessibilityValue` (`PopopxTelemetryHeader.swift:247-248`).
    /// Read the wrong slot and the "longest name" leg compares the length of a fixed sentence, which can never produce a winner.
    private func displayName(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func clip(_ value: String) -> String {
        String(value.prefix(18))
    }

    private func waitUntil(_ seconds: Int, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if condition() { return true }
            usleep(400_000)
        }
        return condition()
    }

    private func rect(_ frame: CGRect) -> String {
        String(format: "%.0f,%.0f %.0fx%.0f", frame.origin.x, frame.origin.y, frame.size.width, frame.height)
    }
}

