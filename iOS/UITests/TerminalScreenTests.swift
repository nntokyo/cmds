import XCTest

/// Rendering checks against the `-mock` demo data (simulator only; launches the app, unlike `DeviceDriverTests`).
/// Run: `-only-testing:CmdsDeviceDriver/TerminalScreenTests` with the companion app installed on the simulator.
final class TerminalScreenTests: XCTestCase {
    /// A full-screen TUI (Claude Code: header at the top, prompt at the bottom, blank rows between) zoomed in
    /// must keep the prompt row in view. Regression: scrolling to a padded anchor view left the viewport on the
    /// blank middle rows, so the pane looked completely empty.
    func testZoomedFullScreenTUIShowsThePromptRow() throws {
        #if !targetEnvironment(simulator)
        // Never relaunch the app on a real phone: it may be connected to a Mac in use.
        throw XCTSkip("simulator only")
        #endif
        let app = XCUIApplication(bundleIdentifier: "tokyo.n-n.cmds.companion")
        app.launchArguments = ["-mock", "-noNotify", "-mockFullScreenTUI"]
        app.launch()
        defer { app.terminate() }

        let workspace = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "api-server")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let screen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "terminalScreen")).firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThan(Self.textPixels(in: screen.screenshot().image), 0, "terminal blank before zoom")

        screen.pinch(withScale: 3, velocity: 1)
        Thread.sleep(forTimeInterval: 1.5)
        let shot = screen.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(Self.textPixels(in: shot.image), 50, "zoomed terminal shows no text")
    }

    /// Earlier output (`requestScrollback`) sits above the screen: swiping down reveals it and stops following the
    /// prompt; Latest returns to the prompt (#19).
    func testScrollsBackIntoEarlierOutput() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("simulator only")
        #endif
        let app = XCUIApplication(bundleIdentifier: "tokyo.n-n.cmds.companion")
        app.launchArguments = ["-mock", "-noNotify", "-mockFullScreenTUI"]
        app.launch()
        defer { app.terminate() }

        let workspace = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "api-server")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let screen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "terminalScreen")).firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        // Zoomed in, the screen and the rows above it are taller than the phone.
        screen.pinch(withScale: 3, velocity: 1)
        Thread.sleep(forTimeInterval: 1)
        let latest = app.buttons.matching(NSPredicate(format: "identifier == %@", "terminalLatest")).firstMatch
        XCTAssertFalse(latest.exists, "following the prompt: no Latest button")

        for _ in 0..<6 { screen.swipeDown(velocity: .fast) }
        XCTAssertTrue(latest.waitForExistence(timeout: 3), "scrolled into earlier output: Latest appears")
        let top = screen.screenshot()
        let attachment = XCTAttachment(screenshot: top)
        attachment.name = "earlier output"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(Self.textPixels(in: top.image), 50, "no earlier output above the screen")

        Thread.sleep(forTimeInterval: 2.5) // output keeps arriving; reading stays where it is
        XCTAssertTrue(latest.exists, "a screen update scrolled back to the prompt while reading")
        latest.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: latest)
        wait(for: [gone], timeout: 3)
    }

    /// A pane that keeps printing (`-mockStreamOutput`: numbered lines) while its earlier output is read (#22): the
    /// rows that scroll off its screen are added between the earlier output and the screen, also across the resets of a
    /// full scrollback, the rows being read stay where they are, the rows above the screen have no gap, and Latest
    /// returns to the live screen.
    func testEarlierOutputKeepsUpWhileReading() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("simulator only")
        #endif
        let app = Self.launch(["-mockStreamOutput"])
        defer { app.terminate() }
        let pane = openStreamingPane(app)

        // Following: the newest line stays on screen as lines arrive (one may arrive between the two reads).
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 1)
            let onScreen = Self.numbers(pane.viewport()).last ?? 0
            let newest = Self.numbers(pane.rows()).last ?? 0
            XCTAssertLessThanOrEqual(newest - onScreen, 2, "following: the newest line is not on screen")
        }

        let reading = scrollIntoEarlierOutput(app, pane)
        Thread.sleep(forTimeInterval: 4) // about 20 more lines
        let after = pane.snapshot("reading, 4 s later")
        let rows = pane.contiguousNumbers()
        XCTAssertFalse(Self.numbers(reading.viewport).isEmpty, "no numbered rows on screen while reading")
        XCTAssertEqual(after.viewport, reading.viewport, "the rows being read moved")
        XCTAssertEqual(pane.changedPixels(reading.image, after.image), 0, "the screen changed while reading")
        XCTAssertGreaterThanOrEqual((rows.last ?? 0) - (reading.newest ?? 0), 10, "the pane stopped printing")
        XCTAssertEqual(Self.gaps(in: rows), [], "rows missing above the screen")

        // Also in the middle of the earlier output (not at its top).
        pane.screen.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 2)
        let middle = pane.snapshot("reading in the middle")
        XCTAssertTrue(latestButton(app).exists, "scrolled back to the screen instead of the middle")
        XCTAssertNotEqual(middle.viewport, reading.viewport, "did not scroll")
        Thread.sleep(forTimeInterval: 3)
        let middleAfter = pane.snapshot("reading in the middle, 3 s later")
        XCTAssertEqual(middleAfter.viewport, middle.viewport, "the rows being read moved")
        XCTAssertEqual(pane.changedPixels(middle.image, middleAfter.image), 0, "the screen changed while reading")
        // The demo pane's scrollback is full: every 30 lines it drops its oldest rows and resets the stream. The rows
        // being read (their first ones gone on the demo Mac by now) still go on without a gap.
        let afterResets = pane.contiguousNumbers()
        XCTAssertGreaterThanOrEqual((afterResets.last ?? 0) - (reading.newest ?? 0), 30, "no reset while reading")
        XCTAssertEqual(afterResets.first, reading.oldest, "the rows being read were dropped")
        XCTAssertEqual(Self.gaps(in: afterResets), [], "rows missing above the screen after a reset")

        returnToLatest(app, pane)
        let newest = Self.numbers(pane.rows()).last
        XCTAssertNotNil(newest)
        XCTAssertTrue(Self.numbers(pane.viewport()).contains { $0 >= (newest ?? 0) - 2 },
                      "Latest did not return to the newest lines")
    }

    /// The rows above the screen stop continuing while earlier output is read (`historyReset`; here `clear`, sent with
    /// a shortcut button): the rows being read stay until the user returns, then the earlier output starts after the
    /// clear.
    func testHistoryResetWhileReadingWaitsForLatest() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("simulator only")
        #endif
        let app = Self.launch(["-mockStreamOutput", "-quickReplies", "clear"])
        defer { app.terminate() }
        let pane = openStreamingPane(app)

        let reading = scrollIntoEarlierOutput(app, pane)
        let beforeClear = Self.numbers(pane.rows()).last ?? 0
        let clear = app.buttons.matching(identifier: "quickReply0").firstMatch
        XCTAssertTrue(clear.exists, "no shortcut button (launch argument -quickReplies)")
        clear.tap()
        Thread.sleep(forTimeInterval: 6) // the screen fills again and rows scroll off
        let after = pane.snapshot("reading, after clear")
        XCTAssertEqual(after.viewport, reading.viewport, "the rows being read moved")
        XCTAssertEqual(pane.changedPixels(reading.image, after.image), 0, "the screen changed while reading")

        returnToLatest(app, pane)
        let rows = pane.contiguousNumbers()
        XCTAssertGreaterThan(rows.first ?? 0, beforeClear, "rows from before the clear are still above the screen")
        XCTAssertEqual(Self.gaps(in: rows), [], "rows missing above the screen")
    }

    /// cmds 0.3.0 on the Mac (`-mockNoHistoryStream`: no `scrollbackStream`): the earlier output being read stays as
    /// it was, so the rows that scroll off the screen meanwhile are missing above it until the user returns.
    func testEarlierOutputFromOlderMacsStaysAsItWas() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("simulator only")
        #endif
        let app = Self.launch(["-mockStreamOutput", "-mockNoHistoryStream"])
        defer { app.terminate() }
        let pane = openStreamingPane(app)

        let reading = scrollIntoEarlierOutput(app, pane)
        Thread.sleep(forTimeInterval: 4)
        let after = pane.snapshot("reading, 4 s later")
        XCTAssertEqual(after.viewport, reading.viewport, "the rows being read moved")
        XCTAssertFalse(Self.gaps(in: Self.numbers(pane.rows())).isEmpty, "no gap above the screen with an older Mac")
        returnToLatest(app, pane)
    }

    // MARK: - Streaming pane helpers

    /// The demo app with `-uiTestProbes` (rows on screen and all rows as accessibility values).
    private static func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "tokyo.n-n.cmds.companion")
        app.launchArguments = ["-mock", "-noNotify", "-uiTestProbes"] + arguments
        app.launch()
        return app
    }

    private struct StreamingPane {
        let test: XCTestCase
        let app: XCUIApplication
        let screen: XCUIElement
        let rowsProbe: XCUIElement
        let viewportProbe: XCUIElement

        /// Every row, earlier output first.
        func rows() -> String { rowsProbe.value as? String ?? "" }
        /// The rows on screen, after a line with their indices and the top of the visible part.
        func viewport() -> String { viewportProbe.value as? String ?? "" }

        /// Pixels that differ between two screenshots of the screen, below the status and navigation bars (the screen
        /// reaches under them, and the clock may change).
        func changedPixels(_ a: UIImage, _ b: UIImage) -> Int {
            let bars = app.navigationBars.firstMatch.frame.maxY - screen.frame.minY
            let scale = CGFloat(a.cgImage?.height ?? 0) / max(1, screen.frame.height)
            return TerminalScreenTests.changedPixels(a, b, fromRow: Int((bars * scale).rounded(.up)))
        }

        /// The row numbers once they have no gap, else after 2 s. Right after a reset the rows above the screen wait
        /// for the Mac's answer while the screen moves on, so they may miss the newest row or two for a moment.
        func contiguousNumbers() -> [Int] {
            let deadline = Date().addingTimeInterval(2)
            var numbers = TerminalScreenTests.numbers(rows())
            while !TerminalScreenTests.gaps(in: numbers).isEmpty, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                numbers = TerminalScreenTests.numbers(rows())
            }
            return numbers
        }

        /// The rows on screen and a screenshot, both attached to the test.
        func snapshot(_ name: String) -> (viewport: String, image: UIImage) {
            let shot = screen.screenshot()
            let text = viewport()
            let image = XCTAttachment(screenshot: shot)
            image.name = name
            image.lifetime = .keepAlways
            test.add(image)
            let onScreen = XCTAttachment(string: text)
            onScreen.name = "\(name): rows on screen"
            onScreen.lifetime = .keepAlways
            test.add(onScreen)
            let all = XCTAttachment(string: self.rows())
            all.name = "\(name): all rows"
            all.lifetime = .keepAlways
            test.add(all)
            return (text, shot.image)
        }
    }

    /// Opens the dotfiles pane, which prints a numbered line five times a second, once its earlier output is there.
    private func openStreamingPane(_ app: XCUIApplication) -> StreamingPane {
        let workspace = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "dotfiles")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let any = app.descendants(matching: .any)
        let pane = StreamingPane(test: self, app: app,
                                 screen: any.matching(identifier: "terminalScreen").firstMatch,
                                 rowsProbe: any.matching(identifier: "terminalRows").firstMatch,
                                 viewportProbe: any.matching(identifier: "terminalViewport").firstMatch)
        XCTAssertTrue(pane.screen.waitForExistence(timeout: 10))
        XCTAssertTrue(pane.rowsProbe.waitForExistence(timeout: 5), "launched without -uiTestProbes?")
        // 300 lines were printed before the pane opened: wait for the rows above the screen.
        let deadline = Date().addingTimeInterval(10)
        while Self.numbers(pane.rows()).count < 280 || pane.viewport().isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThanOrEqual(Self.numbers(pane.rows()).count, 280, "no earlier output above the screen")
        return pane
    }

    /// Swipes well up into the earlier output and waits until the scrolling stopped.
    private func scrollIntoEarlierOutput(_ app: XCUIApplication, _ pane: StreamingPane)
        -> (viewport: String, image: UIImage, oldest: Int?, newest: Int?) {
        for _ in 0..<4 { pane.screen.swipeDown(velocity: .fast) }
        XCTAssertTrue(latestButton(app).waitForExistence(timeout: 3), "scrolled into earlier output: Latest appears")
        Thread.sleep(forTimeInterval: 2) // deceleration and scroll indicators
        let reading = pane.snapshot("reading")
        let rows = Self.numbers(pane.rows())
        return (reading.viewport, reading.image, rows.first, rows.last)
    }

    private func returnToLatest(_ app: XCUIApplication, _ pane: StreamingPane) {
        let latest = latestButton(app)
        latest.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: latest)
        wait(for: [gone], timeout: 3)
        Thread.sleep(forTimeInterval: 1)
        _ = pane.snapshot("after Latest")
    }

    private func latestButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "terminalLatest").firstMatch
    }

    /// The numbers of the `line NNNNN` rows, in order.
    private static func numbers(_ text: String) -> [Int] {
        text.split(separator: "\n").compactMap { row in
            guard row.hasPrefix("line "), row.count == 10 else { return nil }
            return Int(row.dropFirst(5))
        }
    }

    /// Where the numbers do not go up by one: "after N, M" for each gap or step back.
    private static func gaps(in numbers: [Int]) -> [String] {
        zip(numbers, numbers.dropFirst()).filter { $1 != $0 + 1 }.map { "after \($0), \($1)" }
    }

    // MARK: - Pixels

    /// Pixels drawn by terminal text (light gray on the dark background); the blue cursor and the orange
    /// attention border do not count.
    private static func textPixels(in image: UIImage) -> Int {
        guard let image = RGBA(image) else { return 0 }
        // Skip a margin so the attention border is never sampled.
        let margin = 8
        var count = 0
        for y in margin..<max(margin, image.height - margin) {
            for x in margin..<max(margin, image.width - margin) {
                let i = (y * image.width + x) * 4
                if image.data[i] > 150, image.data[i + 1] > 150, image.data[i + 2] > 150 { count += 1 }
            }
        }
        return count
    }

    /// Pixels that differ between two screenshots from pixel row `fromRow` down (all of them when their sizes differ).
    private static func changedPixels(_ a: UIImage, _ b: UIImage, fromRow: Int) -> Int {
        guard let a = RGBA(a), let b = RGBA(b), a.width == b.width, a.height == b.height else { return .max }
        var count = 0
        for i in stride(from: min(max(0, fromRow), a.height) * a.width * 4, to: a.data.count, by: 4)
        where a.data[i] != b.data[i] || a.data[i + 1] != b.data[i + 1] || a.data[i + 2] != b.data[i + 2] {
            count += 1
        }
        return count
    }

    /// An image's pixels, 4 bytes each.
    private struct RGBA {
        let data: [UInt8]
        let width: Int
        let height: Int

        init?(_ image: UIImage) {
            guard let cg = image.cgImage else { return nil }
            width = cg.width
            height = cg.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.data = data
        }
    }
}
