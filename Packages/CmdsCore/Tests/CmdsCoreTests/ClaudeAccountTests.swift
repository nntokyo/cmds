import Foundation
import XCTest
@testable import CmdsCore

/// Claude accounts (#31): limit messages, choosing the next account, resume commands and sharing session transcripts.
final class ClaudeAccountTests: XCTestCase {
    let uuid = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// 2026-11-02 10:00 in Tokyo (a Monday).
    var now: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 10, minute: 0))!
    }

    func tokyoDate(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func detect(_ screen: String) -> ClaudeLimitHit? {
        ClaudeLimitDetector.detect(screen: screen, now: now, timeZone: tokyo)
    }

    // MARK: Limit messages on the screen

    func testUsageLimitMessages() {
        let screen = """
            ╭───────────────────────────────────────────╮
            │ ✻ Welcome to Claude Code!                 │
            ╰───────────────────────────────────────────╯

            > refactor the parser

            ⏺ I'll start by reading the parser.
              ⎿  You've hit your limit · resets 3pm (Asia/Tokyo)
                 /upgrade to increase your usage limit.

            ╭───────────────────────────────────────────╮
            │ >                                         │
            ╰───────────────────────────────────────────╯
              ? for shortcuts
            """
        let hit = detect(screen)
        XCTAssertEqual(hit?.kind, .usageLimit)
        XCTAssertEqual(hit?.resetsAt, tokyoDate(11, 2, 15))
        XCTAssertEqual(hit?.line, "You've hit your limit · resets 3pm (Asia/Tokyo)")

        // Earlier than now today: tomorrow.
        XCTAssertEqual(detect("⎿  You’ve hit your session limit · resets 9:30am")?.resetsAt, tokyoDate(11, 3, 9, 30))
        XCTAssertEqual(detect("You've hit your weekly limit · resets Nov 7, 9am (Asia/Tokyo)")?.resetsAt, tokyoDate(11, 7, 9))
        XCTAssertEqual(detect("You've hit your Opus limit · resets Nov 7 at 9pm")?.resetsAt, tokyoDate(11, 7, 21))
        XCTAssertEqual(detect("5-hour limit reached ∙ resets 3pm")?.resetsAt, tokyoDate(11, 2, 15))
        XCTAssertEqual(detect("Opus weekly limit reached ∙ resets Thu 9am")?.resetsAt, tokyoDate(11, 5, 9))
        XCTAssertEqual(detect("Claude usage limit reached. Your limit will reset at 3pm (America/New_York).")?.resetsAt,
                       tokyoDate(11, 3, 5)) // 15:00 New York (EST) = 05:00 next day in Tokyo
        XCTAssertEqual(detect("Claude AI usage limit reached|1793592000")?.resetsAt, Date(timeIntervalSince1970: 1_793_592_000))
        XCTAssertEqual(detect("You've hit your limit · resets in 2h 15m")?.resetsAt, now.addingTimeInterval(2 * 3600 + 15 * 60))
        XCTAssertEqual(detect("You've hit your limit · resets 15:30")?.resetsAt, tokyoDate(11, 2, 15, 30))
        // January shown in November: next year.
        XCTAssertEqual(detect("You've hit your weekly limit · resets Jan 3, 9am")?.resetsAt, tokyoDate(1, 3, 9, year: 2027))
        // No readable time: a hit without one (the account gets an estimated reset).
        let bare = detect("Claude usage limit reached.")
        XCTAssertEqual(bare?.kind, .usageLimit)
        XCTAssertNil(bare?.resetsAt)
    }

    func testWrappedResetTime() {
        let screen = """
              ⎿  You've hit your weekly limit · resets
                 Nov 7, 9am (Asia/Tokyo)
            """
        XCTAssertEqual(detect(screen)?.resetsAt, tokyoDate(11, 7, 9))
    }

    func testTimeZoneCutByTheWrap() {
        // 68 columns: the zone wraps in the middle of its name.
        let screen = """
              ⎿  Claude usage limit reached. Your limit will reset at 3pm (America/Ne
                 w_York).
            """
        XCTAssertEqual(detect(screen)?.resetsAt, tokyoDate(11, 3, 5))
        let afterParen = """
              ⎿  Claude usage limit reached. Your limit will reset at 3pm (
                 America/New_York).
            """
        XCTAssertEqual(detect(afterParen)?.resetsAt, tokyoDate(11, 3, 5))
        // Cut with nothing after it (the last row), or a zone that is not known: read in the Mac's zone.
        XCTAssertEqual(detect("Claude usage limit reached. Your limit will reset at 3pm (America/Ne")?.resetsAt, tokyoDate(11, 2, 15))
        XCTAssertEqual(detect("You've hit your limit · resets 3pm (Mars/Olympus)")?.resetsAt, tokyoDate(11, 2, 15))
    }

    func testHitLinesAndIgnoring() {
        // A resumed session replays its transcript: older limit notices of the conversation and the latest one.
        let screen = """
            ⏺ Usage limit reached · continuing automatically at 4:50pm · esc to cancel
            > go on
              ⎿  You've hit your 5-hour limit · resets 9:50pm (Asia/Tokyo)
            ⏺ Done.
            """
        let lines = ClaudeLimitDetector.hitLines(screen: screen)
        XCTAssertEqual(lines, ["Usage limit reached · continuing automatically at 4:50pm · esc to cancel",
                               "You've hit your 5-hour limit · resets 9:50pm (Asia/Tokyo)"])
        XCTAssertNil(ClaudeLimitDetector.detect(screen: screen, now: now, timeZone: tokyo, ignoring: lines))
        // A new limit below the replayed ones is found.
        let fresh = screen + "\n  ⎿  You've hit your 5-hour limit · resets 11pm (Asia/Tokyo)"
        XCTAssertEqual(ClaudeLimitDetector.detect(screen: fresh, now: now, timeZone: tokyo, ignoring: lines)?.resetsAt,
                       tokyoDate(11, 2, 23))
        XCTAssertEqual(ClaudeLimitDetector.hitLines(screen: "$ ls\nREADME.md"), [])
    }

    func testRateLimitMessages() {
        let api = #"  ⎿  API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization"}}"#
        XCTAssertEqual(detect(api)?.kind, .rateLimit)
        XCTAssertNil(detect(api)?.resetsAt)
        XCTAssertEqual(detect("⏺ API Error: Rate limit reached")?.kind, .rateLimit)
        XCTAssertEqual(detect("Rate limit reached")?.kind, .rateLimit)
        XCTAssertEqual(detect("Request rejected (429)")?.kind, .rateLimit)
    }

    func testNotLimits() {
        for text in [
            "Approaching usage limit · resets at 10pm",
            "You've used 90% of your weekly limit · resets Nov 7, 9am",
            "Approaching Opus usage limit",
            // Limits of the conversation, not of the account (another account would not help).
            "Context limit reached · /compact or /clear to continue",
            "⎿  Context limit reached",
            "Conversation limit reached",
            "Output token limit reached",
            "Max tokens limit reached",
            // The words inside code or prose do not count: the message must start the line.
            #"  let message = "You've hit your limit · resets 3pm""#,
            "+    XCTAssertEqual(detect(\"5-hour limit reached\"), …)",
            "The server returned 429 when we hit the rate limit.",
            "grep -n 'rate_limit_error' src/",
            "$ echo hello",
            "",
        ] {
            XCTAssertNil(detect(text), text)
        }
    }

    func testContinuingAutomatically() {
        // Claude Code 2.1.3xx: the notice under the limit message has the time without "resets".
        let screen = """
            ❯ continue
              ⎿  You've hit your 5-hour limit · resets 4:50pm (Asia/Tokyo)
                 /usage-credits to finish what you’re working on.

            ⏺ Usage limit reached · continuing automatically at 4:50pm · esc to cancel

            ✻ Worked for 0s · done 16:40
            """
        let hit = detect(screen)
        XCTAssertEqual(hit?.kind, .usageLimit)
        XCTAssertEqual(hit?.line, "Usage limit reached · continuing automatically at 4:50pm · esc to cancel")
        XCTAssertEqual(hit?.resetsAt, detect("⎿  You've hit your 5-hour limit · resets 4:50pm (Asia/Tokyo)")?.resetsAt)
        XCTAssertNotNil(hit?.resetsAt)
        // The notice alone (the turn ended in the grace allowance, no "You've hit" line).
        XCTAssertNotNil(detect("⏺ Usage limit reached · continuing automatically at 4:50pm · esc to cancel")?.resetsAt)
        XCTAssertEqual(detect(screen + "\n⏺ Automatic continue cancelled · /rate-limit-options to re-arm")?.resetsAt, hit?.resetsAt)
        // The limit has reset: what is above is over.
        XCTAssertNil(detect(screen + "\n\n⏺ Usage limit reset · Continuing automatically\n\n  Read 2 files"))
    }

    func testNewestMessageWins() {
        let screen = """
            ⎿  API Error: Rate limit reached
            > continue
            ⎿  You've hit your limit · resets 3pm (Asia/Tokyo)
            """
        XCTAssertEqual(detect(screen)?.kind, .usageLimit)
    }

    func testOnlyRecentLinesAreScanned() {
        let old = "⎿  You've hit your limit · resets 3pm"
        let filler = (1...ClaudeLimitDetector.scannedLines).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertNil(detect(old + "\n" + filler))
    }

    func testStatusLineLimits() {
        let full = UsageLimit(id: "five_hour", usedPercent: 100, resetsAt: now.addingTimeInterval(3600), windowMinutes: 300)
        let partial = UsageLimit(id: "seven_day", usedPercent: 64, resetsAt: now.addingTimeInterval(86400), windowMinutes: 10080)
        let hit = ClaudeLimitDetector.hit(fromLimits: [full, partial], now: now)
        XCTAssertEqual(hit?.kind, .usageLimit)
        XCTAssertEqual(hit?.resetsAt, now.addingTimeInterval(3600))
        XCTAssertNil(ClaudeLimitDetector.hit(fromLimits: [partial], now: now))
        // A window that has already reset does not count.
        let past = UsageLimit(id: "five_hour", usedPercent: 100, resetsAt: now.addingTimeInterval(-60), windowMinutes: 300)
        XCTAssertNil(ClaudeLimitDetector.hit(fromLimits: [past], now: now))
    }

    func testHitBecomesAccountLimit() {
        let known = ClaudeLimitHit(kind: .usageLimit, resetsAt: now.addingTimeInterval(600), line: "x").limit(now: now)
        XCTAssertFalse(known.estimated)
        XCTAssertEqual(known.resetsAt, now.addingTimeInterval(600))
        let unknown = ClaudeLimitHit(kind: .rateLimit, resetsAt: nil, line: "x").limit(now: now)
        XCTAssertTrue(unknown.estimated)
        XCTAssertEqual(unknown.resetsAt, now.addingTimeInterval(ClaudeLimitDetector.fallbackDuration(.rateLimit)))
        XCTAssertTrue(unknown.isActive(at: now))
        XCTAssertFalse(unknown.isActive(at: now.addingTimeInterval(3600)))
    }

    func testFallbackDurationsAndPastResetTimes() {
        // Without a reset time an account counts as limited for the session window (usage) or a quarter hour (rate).
        XCTAssertEqual(ClaudeLimitDetector.fallbackDuration(.usageLimit), 5 * 3600)
        XCTAssertEqual(ClaudeLimitDetector.fallbackDuration(.rateLimit), 15 * 60)
        // A reset time that has passed already is no better than none: estimated from now.
        let past = ClaudeLimitHit(kind: .usageLimit, resetsAt: now.addingTimeInterval(-60), line: "x").limit(now: now)
        XCTAssertTrue(past.estimated)
        XCTAssertEqual(past.resetsAt, now.addingTimeInterval(5 * 3600))
        let atNow = ClaudeLimitHit(kind: .rateLimit, resetsAt: now, line: "x").limit(now: now)
        XCTAssertTrue(atNow.estimated)
        XCTAssertEqual(atNow.resetsAt, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(past.detectedAt, now)
        XCTAssertEqual(past.message, "x")
    }

    func testLimitMessageIsShortened() throws {
        let long = String(repeating: "x", count: 250)
        XCTAssertEqual(ClaudeAccountLimit(kind: .usageLimit, resetsAt: now, message: long).message?.count, 200)
        let json = #"{"kind":"rateLimit","resetsAt":1800000000,"message":"\#(long)"}"#
        let decoded = try JSONDecoder().decode(ClaudeAccountLimit.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.message?.count, 200)
        // detectedAt defaults to the reset time; a missing reset time fails the record.
        XCTAssertEqual(decoded.detectedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertThrowsError(try JSONDecoder().decode(ClaudeAccountLimit.self, from: Data(#"{"kind":"usageLimit"}"#.utf8)))
    }

    // MARK: Accounts

    func testNamesAndPaths() {
        for good in ["work", "personal-2", "me@example.com", "A_b.c"] { XCTAssertNil(ClaudeAccounts.nameProblem(good), good) }
        for bad in ["", "-x", ".x", "a b", "a;b", "auto", "AUTO", String(repeating: "a", count: 33), "名前"] {
            XCTAssertNotNil(ClaudeAccounts.nameProblem(bad), bad)
        }
        for good in ["/Users/me/.claude-work", "~/.claude-work", "~"] { XCTAssertNil(ClaudeAccounts.pathProblem(good), good) }
        for bad in ["relative", "/a'b", "/a\\b", "/a!b", "/a\nb", ""] { XCTAssertNotNil(ClaudeAccounts.pathProblem(bad), bad) }
        XCTAssertEqual(ClaudeAccounts.expandedPath("~/.claude-work/", home: "/Users/me"), "/Users/me/.claude-work")
        XCTAssertEqual(ClaudeAccounts.expandedPath("/a/./b/../c", home: "/Users/me"), "/a/c")
    }

    func testMatchingConfigDir() {
        let accounts = [ClaudeAccount(name: "main", configDir: "~/.claude"), ClaudeAccount(name: "work", configDir: "/x/claude-work")]
        XCTAssertEqual(ClaudeAccounts.account(forConfigDir: nil, in: accounts, home: "/Users/me")?.name, "main")
        XCTAssertEqual(ClaudeAccounts.account(forConfigDir: "", in: accounts, home: "/Users/me")?.name, "main")
        XCTAssertEqual(ClaudeAccounts.account(forConfigDir: "/x/claude-work/", in: accounts, home: "/Users/me")?.name, "work")
        XCTAssertNil(ClaudeAccounts.account(forConfigDir: "/y", in: accounts, home: "/Users/me"))
    }

    func testNextAccount() {
        let limit = ClaudeAccountLimit(kind: .usageLimit, resetsAt: now.addingTimeInterval(3600), detectedAt: now)
        let expired = ClaudeAccountLimit(kind: .usageLimit, resetsAt: now.addingTimeInterval(-1), detectedAt: now)
        var accounts = [ClaudeAccount(name: "a", configDir: "/a", limit: limit),
                        ClaudeAccount(name: "b", configDir: "/b"),
                        ClaudeAccount(name: "c", configDir: "/c", limit: expired)]
        XCTAssertEqual(ClaudeAccounts.next(after: "a", in: accounts, now: now, usable: { _ in true })?.name, "b")
        XCTAssertEqual(ClaudeAccounts.next(after: "b", in: accounts, now: now, usable: { _ in true })?.name, "c")
        // Wraps around, skipping limited accounts; never the current one.
        XCTAssertEqual(ClaudeAccounts.next(after: "c", in: accounts, now: now, usable: { _ in true })?.name, "b")
        XCTAssertEqual(ClaudeAccounts.next(after: nil, in: accounts, now: now, usable: { _ in true })?.name, "b")
        XCTAssertEqual(ClaudeAccounts.firstAvailable(in: accounts, now: now, usable: { _ in true })?.name, "b")
        accounts[1].limit = limit
        accounts[2].limit = limit
        XCTAssertNil(ClaudeAccounts.next(after: "a", in: accounts, now: now, usable: { _ in true }))
        XCTAssertNil(ClaudeAccounts.firstAvailable(in: accounts, now: now, usable: { _ in true }))
    }

    func testNextAccountSkipsMissingConfigDirs() throws {
        let home = try temporaryDirectory().path
        try FileManager.default.createDirectory(atPath: home + "/a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/b", withIntermediateDirectories: true)
        let accounts = [ClaudeAccount(name: "a", configDir: home + "/a"), ClaudeAccount(name: "gone", configDir: home + "/gone"),
                        ClaudeAccount(name: "b", configDir: home + "/b")]
        // An account whose directory does not exist is never a target: no session can be reached from it.
        XCTAssertEqual(ClaudeAccounts.next(after: "a", in: accounts, now: now)?.name, "b")
        XCTAssertNil(ClaudeAccounts.next(after: "a", in: Array(accounts.prefix(2)), now: now))
        XCTAssertEqual(ClaudeAccounts.firstAvailable(in: Array(accounts.dropFirst()), now: now)?.name, "b")
    }

    func testSignInOfConfigDirs() throws {
        let home = try temporaryDirectory().path
        func write(_ path: String, _ json: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        }
        try write(home + "/.claude-a/.claude.json", #"{"oauthAccount":{"accountUuid":"one"},"other":1}"#)
        try write(home + "/.claude-b/.claude.json", #"{"oauthAccount":{"accountUuid":"one"}}"#)
        try write(home + "/.claude-c/.claude.json", #"{"oauthAccount":{"accountUuid":"two"}}"#)
        try write(home + "/.claude-d/.claude.json", "not json")
        // The default directory: a plain `claude` keeps the file next to it.
        try write(home + "/.claude.json", #"{"oauthAccount":{"accountUuid":"two"}}"#)
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        let accounts = ["a", "b", "c", "d", "gone"].map { ClaudeAccount(name: $0, configDir: "~/.claude-\($0)") }
            + [ClaudeAccount(name: "main", configDir: "~/.claude")]
        let signIn: (ClaudeAccount) -> String? = { ClaudeAccounts.signIn(of: $0, home: home) }
        XCTAssertEqual(accounts.map(signIn), ["one", "one", "two", nil, nil, "two"])
        XCTAssertEqual(ClaudeAccounts.sameSignIn(as: accounts[0], in: accounts, signIn: signIn).map(\.name), ["b"])
        XCTAssertEqual(ClaudeAccounts.sameSignIn(as: accounts[2], in: accounts, signIn: signIn).map(\.name), ["main"])
        // Not signed in: the same as nobody.
        XCTAssertEqual(ClaudeAccounts.sameSignIn(as: accounts[3], in: accounts, signIn: signIn), [])
        // The default directory is plain `claude` (#360): `~/.claude.json` wins over the file Claude Code writes when
        // CLAUDE_CONFIG_DIR is set to it, which is used only when the other is missing.
        try write(home + "/.claude/.claude.json", #"{"oauthAccount":{"accountUuid":"one"}}"#)
        XCTAssertEqual(signIn(accounts[5]), "two")
        try FileManager.default.removeItem(atPath: home + "/.claude.json")
        XCTAssertEqual(signIn(accounts[5]), "one")
    }

    func testSuggestedName() {
        let home = "/Users/me"
        XCTAssertEqual(ClaudeAccounts.suggestedName(forConfigDir: "~/.claude", taken: [], home: home), "claude")
        XCTAssertEqual(ClaudeAccounts.suggestedName(forConfigDir: "/Users/me/.claude-work", taken: [], home: home), "work")
        XCTAssertEqual(ClaudeAccounts.suggestedName(forConfigDir: "~/.claude", taken: ["Claude", "claude-2"], home: home), "claude-3")
        XCTAssertEqual(ClaudeAccounts.suggestedName(forConfigDir: "~/My Config!", taken: [], home: home), "MyConfig")
        XCTAssertEqual(ClaudeAccounts.suggestedName(forConfigDir: "~/.__", taken: [], home: home), "claude")
        XCTAssertEqual(ClaudeAccounts.suggestedName(forConfigDir: "~/auto", taken: [], home: home), "claude")
    }

    func testAccountSetup() throws {
        let home = try temporaryDirectory().path
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: home + "/.claude-work", withIntermediateDirectories: true)
        try Data("input=$(cat)\nprintf '%s' \"$input\" | cmds hook claude-status\n".utf8).write(to: URL(fileURLWithPath: home + "/.claude/statusline.sh"))
        let hook = #"{"hooks":[{"type":"command","command":"command -v cmds >/dev/null && cmds hook claude || true"}]}"#
        let all = ClaudeAccountSetup.hookEvents.map { #""\#($0)":[\#(hook)]"# }.joined(separator: ",")
        try Data(#"{"statusLine":{"type":"command","command":"~/.claude/statusline.sh","padding":0},"hooks":{\#(all)}}"#.utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude/settings.json"))
        try Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude-work/settings.json"))
        let main = ClaudeAccount(name: "main", configDir: "~/.claude")
        let work = ClaudeAccount(name: "work", configDir: "~/.claude-work")
        let gone = ClaudeAccount(name: "gone", configDir: "~/.claude-gone")
        // The script is read: it calls the hook.
        XCTAssertEqual(ClaudeAccountSetup.state(of: main, home: home)?.isComplete, true)
        XCTAssertEqual(ClaudeAccountSetup.state(of: work, home: home),
                       ClaudeAccountSetup.State(statusLine: .missing, missingHooks: ClaudeAccountSetup.hookEvents))
        XCTAssertNil(ClaudeAccountSetup.state(of: gone, home: home))
        XCTAssertThrowsError(try ClaudeAccountSetup.apply(to: gone, in: [main, work, gone], home: home))

        let result = try ClaudeAccountSetup.apply(to: work, in: [main, work, gone], home: home, now: now)
        XCTAssertTrue(result.statusLineAdded)
        XCTAssertEqual(result.hooksAdded, ClaudeAccountSetup.hookEvents)
        XCTAssertEqual(result.statusLine, .reports)
        XCTAssertEqual(ClaudeAccountSetup.state(of: work, home: home)?.isComplete, true)
        let backup = try XCTUnwrap(result.backup)
        XCTAssertTrue(String(decoding: try XCTUnwrap(fileManager.contents(atPath: backup)), as: UTF8.self).contains("say done"))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(fileManager.contents(atPath: home + "/.claude-work/settings.json"))) as? [String: Any])
        // Other settings and hooks stay; the status line is the first account's.
        XCTAssertEqual(written["model"] as? String, "opus")
        XCTAssertEqual((written["statusLine"] as? [String: Any])?["command"] as? String, "~/.claude/statusline.sh")
        XCTAssertEqual(((written["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 2)
        // Again: nothing to add, no second backup.
        let again = try ClaudeAccountSetup.apply(to: work, in: [main, work], home: home, now: now)
        XCTAssertEqual(again.hooksAdded, [])
        XCTAssertNil(again.backup)

        // A status line of the user's own is never replaced; without any account that reports, the bare command.
        let own = ClaudeAccountSetup.state(settings: Data(#"{"statusLine":{"type":"command","command":"~/mine.sh"}}"#.utf8))
        XCTAssertEqual(own.statusLine, .own)
        let updated = try XCTUnwrap(ClaudeAccountSetup.updated(settings: Data(#"{"statusLine":{"type":"command","command":"~/mine.sh"}}"#.utf8),
                                                             statusLine: ["type": "command", "command": ClaudeAccountSetup.statusCommand]))
        XCTAssertTrue(String(decoding: updated, as: UTF8.self).contains("~/mine.sh"))
        XCTAssertFalse(String(decoding: updated, as: UTF8.self).contains("claude-status"))
        XCTAssertEqual(ClaudeAccountSetup.state(settings: try XCTUnwrap(ClaudeAccountSetup.updated(settings: nil, statusLine: ClaudeAccountSetup.statusLineTemplate(from: [], home: home)))).isComplete, true)
        // Not a JSON object: left alone.
        XCTAssertTrue(ClaudeAccountSetup.state(settings: Data("[1]".utf8)).unreadable)
        XCTAssertThrowsError(try ClaudeAccountSetup.updated(settings: Data("oops".utf8), statusLine: [:]))
    }

    func testConfigDirExistsAndNames() throws {
        let home = try temporaryDirectory().path
        try FileManager.default.createDirectory(atPath: home + "/.claude-work", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: home + "/file"))
        XCTAssertTrue(ClaudeAccounts.configDirExists(ClaudeAccount(name: "w", configDir: "~/.claude-work"), home: home))
        XCTAssertFalse(ClaudeAccounts.configDirExists(ClaudeAccount(name: "f", configDir: "~/file"), home: home))
        XCTAssertFalse(ClaudeAccounts.configDirExists(ClaudeAccount(name: "m", configDir: "~/missing"), home: home))
        XCTAssertTrue(ClaudeAccount(name: "Work", configDir: "/w").hasName("wORK"))
        XCTAssertFalse(ClaudeAccount(name: "Work", configDir: "/w").hasName("work2"))
    }

    func testNextAccountMatchesNamesIgnoringCase() {
        let accounts = [ClaudeAccount(name: "Work", configDir: "/w"), ClaudeAccount(name: "home", configDir: "/h")]
        XCTAssertEqual(ClaudeAccounts.next(after: "work", in: accounts, now: now, usable: { _ in true })?.name, "home")
        // An account that is not (or no longer) in the list: the first free one, from the top.
        XCTAssertEqual(ClaudeAccounts.next(after: "gone", in: accounts, now: now, usable: { _ in true })?.name, "Work")
        // A single account never switches to itself.
        XCTAssertNil(ClaudeAccounts.next(after: "Work", in: Array(accounts.prefix(1)), now: now, usable: { _ in true }))
        XCTAssertNil(ClaudeAccounts.next(after: nil, in: [], now: now, usable: { _ in true }))
    }

    func testMergeKeepsLaterEstimateOverExpiredLimit() {
        let expired = ClaudeAccountLimit(kind: .usageLimit, resetsAt: now.addingTimeInterval(-1), detectedAt: now)
        let estimated = ClaudeAccountLimit(kind: .rateLimit, resetsAt: now.addingTimeInterval(900), estimated: true, detectedAt: now)
        XCTAssertEqual(ClaudeAccounts.merge(expired, estimated, now: now), estimated)
        let soonerEstimate = ClaudeAccountLimit(kind: .rateLimit, resetsAt: now.addingTimeInterval(300), estimated: true, detectedAt: now)
        XCTAssertEqual(ClaudeAccounts.merge(estimated, soonerEstimate, now: now), estimated)
    }

    func testMergeLimits() {
        let estimated = ClaudeAccountLimit(kind: .rateLimit, resetsAt: now.addingTimeInterval(900), estimated: true, detectedAt: now)
        let known = ClaudeAccountLimit(kind: .usageLimit, resetsAt: now.addingTimeInterval(600), detectedAt: now)
        let later = ClaudeAccountLimit(kind: .usageLimit, resetsAt: now.addingTimeInterval(7200), detectedAt: now)
        XCTAssertEqual(ClaudeAccounts.merge(known, estimated, now: now), known)
        XCTAssertEqual(ClaudeAccounts.merge(estimated, known, now: now), known)
        XCTAssertEqual(ClaudeAccounts.merge(known, later, now: now), later)
        XCTAssertEqual(ClaudeAccounts.merge(later, known, now: now), later)
        XCTAssertEqual(ClaudeAccounts.merge(nil, estimated, now: now), estimated)
    }

    func testSettingsRoundTripAndLenientDecoding() throws {
        let settings = ClaudeAccountSettings(accounts: [
            ClaudeAccount(name: "work", configDir: "~/.claude-work",
                          limit: ClaudeAccountLimit(kind: .usageLimit, resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                    detectedAt: Date(timeIntervalSince1970: 1_799_990_000), message: "x")),
        ], autoSwitch: true)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ClaudeAccountSettings.self, from: data), settings)
        // Dates are epoch seconds.
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("1800000000"))
        let messy = #"{"accounts":[{"name":"ok","configDir":"/ok"},{"name":"bad name","configDir":"/x"},{"name":"OK","configDir":"/dup"},{"name":"rel","configDir":"relative"},7],"autoSwitch":"yes"}"#
        let decoded = try JSONDecoder().decode(ClaudeAccountSettings.self, from: Data(messy.utf8))
        XCTAssertEqual(decoded.accounts.map(\.name), ["ok"])
        XCTAssertTrue(decoded.autoSwitch)
        XCTAssertEqual(decoded.account(named: "OK")?.name, "ok")
    }

    /// #44: a position beyond the end is refused like position 0, not clamped.
    func testMovePositions() {
        XCTAssertNil(ClaudeAccounts.positionProblem(0, count: 3))
        XCTAssertNil(ClaudeAccounts.positionProblem(2, count: 3))
        XCTAssertEqual(ClaudeAccounts.positionProblem(3, count: 3), "the position must be 1 to 3")
        XCTAssertEqual(ClaudeAccounts.positionProblem(8, count: 3), "the position must be 1 to 3")
        XCTAssertEqual(ClaudeAccounts.positionProblem(-1, count: 3), "the position must be 1 to 3")
        XCTAssertNil(ClaudeAccounts.positionProblem(0, count: 1))
        XCTAssertEqual(ClaudeAccounts.positionProblem(1, count: 1), "the position must be 1")
    }

    func testStoreFile() throws {
        let dir = try temporaryDirectory()
        let url = ClaudeAccountStore.url(supportDirectory: dir)
        let missing = ClaudeAccountStore.load(from: url)
        XCTAssertEqual(missing.settings, ClaudeAccountSettings())
        XCTAssertNil(missing.error)
        XCTAssertFalse(missing.saveBlocked)
        let settings = ClaudeAccountSettings(accounts: [ClaudeAccount(name: "a", configDir: "/a")], autoSwitch: false)
        try ClaudeAccountStore.save(settings, to: url)
        XCTAssertEqual(ClaudeAccountStore.load(from: url).settings, settings)
    }

    /// #46: a damaged file is moved aside and kept, so the next save does not replace the user's accounts.
    func testDamagedStoreFileIsMovedAsideNotOverwritten() throws {
        let dir = try temporaryDirectory()
        let url = ClaudeAccountStore.url(supportDirectory: dir)
        let damaged = Data(#"{"accounts":[{"name":"work","configDir":"/w"}"#.utf8)
        try damaged.write(to: url)

        let loaded = ClaudeAccountStore.load(from: url, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(loaded.settings, ClaudeAccountSettings())
        XCTAssertNotNil(loaded.error)
        XCTAssertFalse(loaded.saveBlocked)
        let moved = try XCTUnwrap(loaded.movedAside)
        XCTAssertTrue(moved.lastPathComponent.hasPrefix("claude-accounts.json.corrupt-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try ClaudeAccountStore.save(ClaudeAccountSettings(accounts: [ClaudeAccount(name: "new", configDir: "/n")]), to: url)
        XCTAssertEqual(try Data(contentsOf: moved), damaged)
    }

    /// #46: a file that cannot be read stays where it is, and saving is blocked.
    func testUnreadableStoreFileBlocksSaving() throws {
        let dir = try temporaryDirectory()
        let url = ClaudeAccountStore.url(supportDirectory: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) // a directory cannot be read
        let loaded = ClaudeAccountStore.load(from: url)
        XCTAssertNotNil(loaded.error)
        XCTAssertNil(loaded.movedAside)
        XCTAssertTrue(loaded.saveBlocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Resume commands

    func testResumeCommandWithAccount() {
        let session = AgentSession(agent: .claude, sessionID: uuid, cwd: "/Users/me/src/app", account: "work",
                                   configDir: "/Users/me/.claude-work")
        XCTAssertEqual(AgentResume.command(for: session),
                       "cd '/Users/me/src/app' && env CLAUDE_CONFIG_DIR='/Users/me/.claude-work' claude --resume \(uuid)")
        // A config dir that cannot be typed safely: no command at all (resuming under the wrong account is worse).
        var bad = session
        bad.configDir = "/tmp/it's"
        XCTAssertNil(AgentResume.command(for: bad))
        bad.configDir = "~/.claude-work"
        XCTAssertNil(AgentResume.command(for: bad))
    }

    func testSessionAccountCoding() throws {
        let session = AgentSession(agent: .claude, sessionID: uuid, cwd: "/x", lastSeen: Date(timeIntervalSince1970: 1_800_000_000),
                                   account: "work", configDir: "/Users/me/.claude-work")
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
        // An unsafe config dir from a file is dropped (the session itself stays).
        let json = #"{"agent":"claude","sessionID":"\#(uuid)","configDir":"/a'b","account":"work"}"#
        let lenient = try JSONDecoder().decode(AgentSession.self, from: Data(json.utf8))
        XCTAssertNil(lenient.configDir)
        XCTAssertEqual(lenient.account, "work")
    }

    // MARK: Sharing transcripts

    func testSharingPlanAndApply() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        func mkdir(_ path: String) throws { try fm.createDirectory(atPath: home + path, withIntermediateDirectories: true) }
        // main: the store, with a transcript. work: its own projects with a transcript. fresh: nothing yet.
        // other: projects links elsewhere. gone: not signed in.
        try mkdir("/main/projects/-Users-me-app")
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: home + "/main/projects/-Users-me-app/\(uuid).jsonl"))
        try mkdir("/work/projects/-Users-me-old")
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: home + "/work/projects/-Users-me-old/old.jsonl"))
        try mkdir("/fresh")
        try mkdir("/other")
        try mkdir("/elsewhere")
        try fm.createSymbolicLink(atPath: home + "/other/projects", withDestinationPath: home + "/elsewhere")
        let accounts = ["main", "work", "fresh", "other", "gone"].map { ClaudeAccount(name: $0, configDir: "~/\($0)") }

        func link(_ name: String) -> ClaudeProjectsLink {
            ClaudeSessionSharing.link(of: accounts.first { $0.name == name }!, in: accounts, home: home)
        }
        XCTAssertEqual(link("main"), .shared)
        XCTAssertEqual(link("work"), .separate)
        XCTAssertEqual(link("fresh"), .missing)
        XCTAssertEqual(link("other"), .elsewhere)
        XCTAssertEqual(link("gone"), .noConfigDir)
        XCTAssertFalse(ClaudeSessionSharing.transcriptReachable(sessionID: uuid, configDir: "~/work", home: home))

        let steps = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        XCTAssertEqual(steps.map(\.account), ["main", "work", "fresh", "other", "gone"])
        XCTAssertEqual(steps[0].action, .none)
        guard case .moveAsideAndLink(let backup) = steps[1].action else { return XCTFail("\(steps[1].action)") }
        XCTAssertTrue(backup.hasPrefix("projects.before-cmds-"))
        XCTAssertEqual(steps[2].action, .createLink)
        if case .skip = steps[3].action {} else { XCTFail("\(steps[3].action)") }
        if case .skip = steps[4].action {} else { XCTFail("\(steps[4].action)") }

        let linked = try ClaudeSessionSharing.apply(steps, accounts: accounts, home: home)
        XCTAssertEqual(linked, ["work", "fresh"])
        for name in ["main", "work", "fresh"] { XCTAssertEqual(link(name), .shared, name) }
        XCTAssertEqual(link("other"), .elsewhere)
        // The session is now reachable from every linked account; nothing was deleted.
        for dir in ["~/main", "~/work", "~/fresh"] {
            XCTAssertTrue(ClaudeSessionSharing.transcriptReachable(sessionID: uuid, configDir: dir, home: home), dir)
        }
        XCTAssertTrue(fm.fileExists(atPath: home + "/work/\(backup)/-Users-me-old/old.jsonl"))
        // work's own session was copied into the shared folder (#360): it can be continued from every account.
        XCTAssertEqual(fm.contents(atPath: home + "/main/projects/-Users-me-old/old.jsonl"), Data("old\n".utf8))
        XCTAssertTrue(ClaudeSessionSharing.transcriptReachable(sessionID: "old", configDir: "~/fresh", home: home))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home + "/other/projects"), home + "/elsewhere")
        // Sharing again changes nothing.
        let again = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        XCTAssertEqual(try ClaudeSessionSharing.apply(again, accounts: accounts, home: home), [])
    }

    /// #360: what the shared folder lacks is copied in, into the folders both have; nothing there is overwritten.
    func testSharingCopiesOnlyWhatTheStoreLacks() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        func write(_ path: String, _ text: String) throws {
            try fm.createDirectory(atPath: home + (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: home + path))
        }
        try write("/a/projects/-p/same.jsonl", "store")
        try write("/b/projects/-p/same.jsonl", "mine")
        try write("/b/projects/-p/new.jsonl", "new")
        try write("/b/projects/-p/new/subagents/agent-1.jsonl", "sub")
        try write("/b/projects/-q/other.jsonl", "q")
        let accounts = [ClaudeAccount(name: "a", configDir: home + "/a"), ClaudeAccount(name: "b", configDir: home + "/b")]
        let steps = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        guard case .moveAsideAndLink(let backup) = steps[1].action else { return XCTFail("\(steps[1].action)") }
        XCTAssertEqual(try ClaudeSessionSharing.apply(steps, accounts: accounts, home: home), ["b"])
        func text(_ path: String) -> String? { fm.contents(atPath: home + path).map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(text("/a/projects/-p/same.jsonl"), "store")
        XCTAssertEqual(text("/a/projects/-p/new.jsonl"), "new")
        XCTAssertEqual(text("/a/projects/-p/new/subagents/agent-1.jsonl"), "sub")
        XCTAssertEqual(text("/a/projects/-q/other.jsonl"), "q")
        // The renamed folder keeps everything.
        XCTAssertEqual(text("/b/\(backup)/-p/same.jsonl"), "mine")
        XCTAssertEqual(text("/b/\(backup)/-p/new.jsonl"), "new")
    }

    func testSharingCreatesStoreProjects() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/a", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/b", withIntermediateDirectories: true)
        let accounts = [ClaudeAccount(name: "a", configDir: home + "/a"), ClaudeAccount(name: "b", configDir: home + "/b")]
        let steps = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        XCTAssertEqual(try ClaudeSessionSharing.apply(steps, accounts: accounts, home: home), ["b"])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: home + "/b/projects", isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func testSharingNeverOverwritesABackup() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        for path in ["/a/projects", "/b/projects"] { try fm.createDirectory(atPath: home + path, withIntermediateDirectories: true) }
        let accounts = [ClaudeAccount(name: "a", configDir: home + "/a"), ClaudeAccount(name: "b", configDir: home + "/b")]
        let steps = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        guard case .moveAsideAndLink(let backup) = steps[1].action else { return XCTFail() }
        // Something takes the backup name between planning and applying: the step fails, b/projects stays.
        try fm.createDirectory(atPath: home + "/b/" + backup, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ClaudeSessionSharing.apply(steps, accounts: accounts, home: home))
        XCTAssertEqual(ClaudeSessionSharing.link(of: accounts[1], in: accounts, home: home), .separate)
    }

    func testSharingNeverReplacesWhatAppearedMeanwhile() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        for path in ["/a/projects", "/b"] { try fm.createDirectory(atPath: home + path, withIntermediateDirectories: true) }
        let accounts = [ClaudeAccount(name: "a", configDir: home + "/a"), ClaudeAccount(name: "b", configDir: home + "/b")]
        let steps = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        XCTAssertEqual(steps[1].action, .createLink)
        // b/projects appears between planning and applying (Claude Code started there): it is not replaced.
        try fm.createDirectory(atPath: home + "/b/projects/-x", withIntermediateDirectories: true)
        XCTAssertThrowsError(try ClaudeSessionSharing.apply(steps, accounts: accounts, home: home))
        XCTAssertTrue(fm.fileExists(atPath: home + "/b/projects/-x"))
        XCTAssertEqual(ClaudeSessionSharing.link(of: accounts[1], in: accounts, home: home), .separate)
    }

    func testSharingAfterReorderingKeepsTheRealStore() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/a/projects/-p", withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: home + "/a/projects/-p/\(uuid).jsonl"))
        try fm.createDirectory(atPath: home + "/b", withIntermediateDirectories: true)
        let a = ClaudeAccount(name: "a", configDir: home + "/a"), b = ClaudeAccount(name: "b", configDir: home + "/b")
        try ClaudeSessionSharing.apply(ClaudeSessionSharing.plan([a, b], now: now, home: home), accounts: [a, b], home: home)

        // b (a link to a's folder) is moved to the top: a's folder stays the store, nothing is to be done.
        let reordered = [b, a]
        XCTAssertEqual(ClaudeSessionSharing.store(reordered, home: home)?.account, "a")
        XCTAssertEqual(ClaudeSessionSharing.link(of: a, in: reordered, home: home), .shared)
        XCTAssertEqual(ClaudeSessionSharing.link(of: b, in: reordered, home: home), .shared)
        let steps = ClaudeSessionSharing.plan(reordered, now: now, home: home)
        XCTAssertEqual(steps.map(\.action), [.none, .none])
        XCTAssertEqual(try ClaudeSessionSharing.apply(steps, accounts: reordered, home: home), [])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: home + "/a/projects", isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: home + "/a").sorted(), ["projects"])

        // An account added later is linked to the real folder, not to b's link.
        try fm.createDirectory(atPath: home + "/c", withIntermediateDirectories: true)
        let c = ClaudeAccount(name: "c", configDir: home + "/c")
        let withC = [b, a, c]
        XCTAssertEqual(try ClaudeSessionSharing.apply(ClaudeSessionSharing.plan(withC, now: now, home: home), accounts: withC,
                                                      home: home), ["c"])
        XCTAssertTrue(ClaudeSessionSharing.transcriptReachable(sessionID: uuid, configDir: home + "/c", home: home))
        XCTAssertEqual(ClaudeSessionSharing.link(of: c, in: withC, home: home), .shared)
    }

    func testSharingWithTheFirstLinkedOutsideKeepsTheAccountsFolder() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/a/projects/-p", withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: home + "/a/projects/-p/\(uuid).jsonl"))
        try fm.createDirectory(atPath: home + "/b", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/elsewhere", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/c", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/c/projects", withDestinationPath: home + "/elsewhere")
        let a = ClaudeAccount(name: "a", configDir: home + "/a"), b = ClaudeAccount(name: "b", configDir: home + "/b")
        let c = ClaudeAccount(name: "c", configDir: home + "/c")
        try ClaudeSessionSharing.apply(ClaudeSessionSharing.plan([a, b, c], now: now, home: home), accounts: [a, b, c], home: home)

        // c (a link to a folder outside the accounts) is moved to the top: a's folder stays the store, c is left alone.
        let reordered = [c, a, b]
        XCTAssertEqual(ClaudeSessionSharing.store(reordered, home: home)?.account, "a")
        XCTAssertEqual(ClaudeSessionSharing.link(of: c, in: reordered, home: home), .elsewhere)
        let steps = ClaudeSessionSharing.plan(reordered, now: now, home: home)
        XCTAssertEqual(steps.map(\.action.name), [.skip, .unchanged, .unchanged])
        XCTAssertEqual(try ClaudeSessionSharing.apply(steps, accounts: reordered, home: home), [])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: home + "/a").sorted(), ["projects"])
        XCTAssertTrue(ClaudeSessionSharing.transcriptReachable(sessionID: uuid, configDir: home + "/b", home: home))

        // Only links outside the accounts and no folder of their own: the first one's target is the store, as before.
        let d = ClaudeAccount(name: "d", configDir: home + "/d")
        try fm.createDirectory(atPath: home + "/d", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/d/projects", withDestinationPath: home + "/elsewhere")
        XCTAssertEqual(ClaudeSessionSharing.store([c, d], home: home)?.path, (home + "/elsewhere" as NSString).resolvingSymlinksInPath)
    }

    func testApplyNeverMovesTheStoreAside() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/a/projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/b", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/b/projects", withDestinationPath: home + "/a/projects")
        let accounts = [ClaudeAccount(name: "b", configDir: home + "/b"), ClaudeAccount(name: "a", configDir: home + "/a")]
        // A step planned by older code (or before the folders changed) that would link the store to itself.
        let step = ClaudeSessionSharing.Step(account: "a", projectsPath: home + "/a/projects",
                                             action: .moveAsideAndLink(backupName: "projects.before-cmds-x"))
        XCTAssertThrowsError(try ClaudeSessionSharing.apply([step], accounts: accounts, home: home))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: home + "/a/projects", isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertFalse(fm.fileExists(atPath: home + "/a/projects.before-cmds-x"))
    }

    func testFailedLinkMovesTheFolderBack() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/a/projects", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/b/projects/-old", withIntermediateDirectories: true)
        let accounts = [ClaudeAccount(name: "a", configDir: home + "/a"), ClaudeAccount(name: "b", configDir: home + "/b")]
        let steps = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        guard case .moveAsideAndLink = steps[1].action else { return XCTFail("\(steps[1].action)") }
        XCTAssertThrowsError(try ClaudeSessionSharing.apply(steps, accounts: accounts, fileManager: NoLinksFileManager(), home: home))
        // b's own folder is back where it was, with its contents; no backup is left.
        XCTAssertTrue(fm.fileExists(atPath: home + "/b/projects/-old"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: home + "/b"), ["projects"])
        XCTAssertEqual(ClaudeSessionSharing.link(of: accounts[1], in: accounts, home: home), .separate)
    }

    func testBackupNamesAreNumberedWhenTaken() throws {
        let home = try temporaryDirectory().path
        let fm = FileManager.default
        let projects = home + "/a/projects"
        let first = ClaudeSessionSharing.backupName(for: projects, now: now, fileManager: fm)
        XCTAssertTrue(first.hasPrefix("projects.before-cmds-2026"), first)
        try fm.createDirectory(atPath: home + "/a/" + first, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeSessionSharing.backupName(for: projects, now: now, fileManager: fm), first + "-2")
        try fm.createDirectory(atPath: home + "/a/" + first + "-2", withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeSessionSharing.backupName(for: projects, now: now, fileManager: fm), first + "-3")
    }

    func testSharingWithoutAnySignedInAccountDoesNothing() throws {
        let home = try temporaryDirectory().path
        let accounts = [ClaudeAccount(name: "a", configDir: home + "/a"), ClaudeAccount(name: "b", configDir: home + "/b")]
        XCTAssertNil(ClaudeSessionSharing.store(accounts, home: home))
        let steps = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        XCTAssertEqual(steps.map(\.account), ["a", "b"])
        for step in steps { if case .skip = step.action {} else { XCTFail("\(step.action)") } }
        XCTAssertEqual(try ClaudeSessionSharing.apply(steps, accounts: accounts, home: home), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/a"))
    }

    func testTranscriptReachableNeedsAValidID() throws {
        let home = try temporaryDirectory().path
        try FileManager.default.createDirectory(atPath: home + "/a/projects/-p", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: home + "/a/projects/-p/\(uuid).jsonl"))
        XCTAssertTrue(ClaudeSessionSharing.transcriptReachable(sessionID: uuid, configDir: home + "/a", home: home))
        XCTAssertFalse(ClaudeSessionSharing.transcriptReachable(sessionID: "../\(uuid)", configDir: home + "/a", home: home))
        XCTAssertFalse(ClaudeSessionSharing.transcriptReachable(sessionID: uuid, configDir: home + "/missing", home: home))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// A file manager that cannot create symbolic links (a link failing after its folder was moved aside).
private final class NoLinksFileManager: FileManager, @unchecked Sendable {
    override func createSymbolicLink(atPath path: String, withDestinationPath destPath: String) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
