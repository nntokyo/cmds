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
        return .sent(to: pointTargetName(target))
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
