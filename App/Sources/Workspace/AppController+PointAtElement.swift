import AppKit
import CmdsCore

/// Point at Element (BrowserPane+Point.swift): where a browser pane's report goes and how it gets there.
extension AppController {
    /// Numbers the screenshots of this run (two in the same second get different names).
    static var elementPointSequence = 0

    /// The terminal a report from browser `paneID` goes to: the one that opened the browser while an agent runs there,
    /// else the agent terminal of the workspace focused last. Never a terminal without an agent (the report would run
    /// as shell commands).
    func pointTarget(forBrowser paneID: String) -> Pane? {
        guard let browser = try? resolvePane(paneID), let workspace = workspace(id: browser.workspaceID) else { return nil }
        let hasAgent: (Pane) -> Bool = { $0.kind == .terminal && $0.terminal != nil && $0.agentActivity != .none }
        if let opener = browser.openedBy.flatMap({ workspace.panes[$0] }), hasAgent(opener) { return opener }
        return workspace.orderedPanes.filter(hasAgent).max { $0.focusedAt < $1.focusedAt }
    }

    /// The name a terminal is shown by in the composer and the notice.
    /// The terminal's task, else its title without the agent's status glyph (`✳ Claude Code` → `Claude Code`).
    func pointTargetName(_ pane: Pane) -> String {
        if let topic = pane.agentTopic, !topic.isEmpty { return topic }
        let title = pane.title.trimmingCharacters(in: .whitespaces)
        if AgentTitle.parse(title).glyph != nil {
            let rest = title.dropFirst().trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return DefaultTitle.localized(pane.title)
    }

    /// Saves the screenshot, types the prompt into the agent's terminal (a paste, then Return a moment later, as a
    /// schedule's prompt) and answers where it went. An agent asking a question is not typed into (the prompt would
    /// answer it): the prompt goes to the clipboard then, as it does without an agent terminal.
    func deliverElementPoint(_ report: ElementPointReport, fromBrowser paneID: String) -> ElementPointDelivery {
        let target = pointTarget(forBrowser: paneID)
        let screenshot = report.screenshot.flatMap { saveElementPointScreenshot($0, for: target) }
        let prompt = ElementPoint.prompt(comment: report.comment, element: report.element, url: report.url,
                                         title: report.title, screenshot: screenshot)
        guard let target else {
            copyToPasteboard(prompt)
            return .copied(reason: String(localized: "no agent runs in a terminal of this workspace"))
        }
        guard target.agentActivity != .needsInput else {
            copyToPasteboard(prompt)
            return .copied(reason: String(localized: "\(pointTargetName(target)) is waiting for an answer",
                                          comment: "Point at Element: the agent's terminal asks a question; argument: its name"))
        }
        do {
            try sendText(paneID: target.id, text: prompt)
        } catch {
            copyToPasteboard(prompt)
            return .copied(reason: String(localized: "the terminal could not take it"))
        }
        let id = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + ScheduleRunTiming.enterDelay) { [weak self] in
            MainActor.assumeIsolated { try? self?.typeText(paneID: id, text: "\r") }
        }
        elementPointFollows[target.id] = ElementPointFollow(browserPaneID: paneID, sentAt: Date(), sawWork: false)
        return .sent(to: pointTargetName(target))
    }

    // MARK: - Asked by an agent

    /// `browser.point`: shows the browser pane (a background tab comes forward; the keyboard stays where it is), lights
    /// its ring with the agent's request, and answers with the element the user clicks (`ElementPoint.agentResult`).
    func browserPoint(paneID: String, prompt: String?, timeout: TimeInterval) async throws -> JSONValue {
        let browser = try await readyBrowser(paneID: paneID)
        let pane = try resolvePane(paneID)
        if let workspace = workspace(id: pane.workspaceID), let leaf = workspace.root?.leaf(for: pane.id),
           leaf.paneID != pane.id {
            leaf.selectTab(pane.id)
            emit(.workspace(id: workspace.id))
        }
        raiseAttention(pane: pane, title: String(localized: "Point at an element", comment: "notification title of browser.point"),
                       body: prompt ?? String(localized: "The agent asks you to click an element"))
        defer { clearAttention(pane) }
        let element = try await browser.pointForAgent(prompt: prompt, timeout: timeout)
        return ElementPoint.agentResult(element: element, url: browser.currentURL?.absoluteString, title: browser.pageTitle)
    }

    // MARK: - Following a report

    /// The agent's state changed: the browser the report came from shows it. Working, asking, then finished once it
    /// worked after the report (`ElementPointFollow.sawWork`): an agent busy when the report came queues it, so the end
    /// of its earlier turn does not count. A report nobody started on within
    /// `ElementPointFollow.startWindow` is forgotten; a newer report from the same terminal replaces the follow.
    func followElementPoint(_ pane: Pane, activity: AgentActivity) {
        guard var follow = elementPointFollows[pane.id] else { return }
        let now = Date()
        guard let browser = self.pane(id: follow.browserPaneID)?.browser,
              follow.sawWork || now.timeIntervalSince(follow.sentAt) < ElementPointFollow.startWindow else {
            elementPointFollows[pane.id] = nil
            return
        }
        let name = pointTargetName(pane)
        let showTerminal: () -> Void = { [weak self] in try? self?.focusPane(id: pane.id) }
        switch activity {
        case .busy:
            follow.sawWork = true
            elementPointFollows[pane.id] = follow
            browser.showNotice(.pointWorking(target: name), onShowTerminal: showTerminal)
        case .needsInput:
            follow.sawWork = true
            elementPointFollows[pane.id] = follow
            browser.showNotice(.pointAsking(target: name), onShowTerminal: showTerminal)
        case .idle:
            // A queued report can start without the agent looking idle in between: its prompt hook says it did.
            let promptHook = pane.agentSignals.workingHookAt.map { $0 > follow.sentAt.addingTimeInterval(1) } ?? false
            guard follow.sawWork || promptHook else { return }
            elementPointFollows[pane.id] = nil
            // The Stop hook's reply text is recorded right after the state changes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let browser = self.pane(id: follow.browserPaneID)?.browser else { return }
                    browser.showNotice(.pointDone(target: name, summary: self.replySummary(of: pane, since: follow.sentAt)),
                                       onShowTerminal: showTerminal)
                }
            }
        case .none:
            elementPointFollows[pane.id] = nil
            if follow.sawWork { browser.showNotice(nil) }
        }
    }

    /// The first line of the agent's last reply, when its Stop notification came after the report.
    private func replySummary(of pane: Pane, since date: Date) -> String? {
        guard let workspace = workspace(id: pane.workspaceID), workspace.notificationPaneID == pane.id,
              let text = workspace.notificationText, (workspace.notificationDate ?? .distantPast) >= date else { return nil }
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // The notification's title ("Claude Code: …") is the notice's own start already.
        for title in [pointTargetName(pane), "Claude Code", "Codex"] where line.hasPrefix(title + ": ") {
            line = String(line.dropFirst(title.count + 2))
            break
        }
        return line.isEmpty ? nil : (line.count > 120 ? String(line.prefix(119)) + "…" : line)
    }

    /// Writes the screenshot where the agent can read it without asking: `.cmds/reports/` in its terminal's folder
    /// (`.cmds/` ignores itself for git), else the support folder's `Reports/`. Keeps the newest
    /// `ElementPoint.keptReports`. Nil for an agent on a server (it cannot read this Mac's files) or when nothing
    /// could be written. Returns the absolute path.
    private func saveElementPointScreenshot(_ png: Data, for target: Pane?) -> String? {
        if target?.ssh != nil { return nil }
        var folders: [URL] = []
        if let directory = target?.workingDirectory, !directory.isEmpty,
           FileManager.default.fileExists(atPath: directory) {
            folders.append(URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(ElementPoint.reportsFolder))
        }
        folders.append(CmdsEnv.supportDirectoryURL().appendingPathComponent("Reports", isDirectory: true))
        Self.elementPointSequence += 1
        let name = ElementPoint.screenshotName(at: Date(), sequence: Self.elementPointSequence)
        let manager = FileManager.default
        for folder in folders {
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let dotCmds = folder.deletingLastPathComponent()
                if dotCmds.lastPathComponent == ".cmds" {
                    let ignore = dotCmds.appendingPathComponent(".gitignore")
                    if !manager.fileExists(atPath: ignore.path) { try Data("*\n".utf8).write(to: ignore) }
                }
                let file = folder.appendingPathComponent(name)
                try png.write(to: file, options: .atomic)
                pruneElementPointScreenshots(in: folder)
                return file.path
            } catch {
                NSLog("cmds: point at element: cannot write \(folder.path): \(error)")
            }
        }
        return nil
    }

    private func pruneElementPointScreenshots(in folder: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("point-") && $0.hasSuffix(".png") }
            .sorted()
        for name in names.dropLast(ElementPoint.keptReports) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A report typed into an agent's terminal, followed until the agent finished with it.
struct ElementPointFollow {
    /// The browser pane the report came from (its notice shows the progress).
    var browserPaneID: String
    var sentAt: Date
    /// The agent became busy (or asked) after the report arrived.
    var sawWork: Bool
    /// An agent that never starts within this time is not followed.
    static let startWindow: TimeInterval = 120
}
