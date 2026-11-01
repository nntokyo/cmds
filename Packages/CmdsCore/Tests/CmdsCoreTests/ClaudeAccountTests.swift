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
        XCTAssertEqual(ClaudeAccounts.next(after: "a", in: accounts, now: now)?.name, "b")
        XCTAssertEqual(ClaudeAccounts.next(after: "b", in: accounts, now: now)?.name, "c")
        // Wraps around, skipping limited accounts; never the current one.
        XCTAssertEqual(ClaudeAccounts.next(after: "c", in: accounts, now: now)?.name, "b")
        XCTAssertEqual(ClaudeAccounts.next(after: nil, in: accounts, now: now)?.name, "b")
        XCTAssertEqual(ClaudeAccounts.firstAvailable(in: accounts, now: now)?.name, "b")
        accounts[1].limit = limit
        accounts[2].limit = limit
        XCTAssertNil(ClaudeAccounts.next(after: "a", in: accounts, now: now))
        XCTAssertNil(ClaudeAccounts.firstAvailable(in: accounts, now: now))
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
        XCTAssertEqual(ClaudeAccounts.next(after: "work", in: accounts, now: now)?.name, "home")
        // An account that is not (or no longer) in the list: the first free one, from the top.
        XCTAssertEqual(ClaudeAccounts.next(after: "gone", in: accounts, now: now)?.name, "Work")
        // A single account never switches to itself.
        XCTAssertNil(ClaudeAccounts.next(after: "Work", in: Array(accounts.prefix(1)), now: now))
        XCTAssertNil(ClaudeAccounts.next(after: nil, in: [], now: now))
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

    func testStoreFile() throws {
        let dir = try temporaryDirectory()
        let url = ClaudeAccountStore.url(supportDirectory: dir)
        XCTAssertEqual(ClaudeAccountStore.load(from: url), ClaudeAccountSettings())
        let settings = ClaudeAccountSettings(accounts: [ClaudeAccount(name: "a", configDir: "/a")], autoSwitch: false)
        try ClaudeAccountStore.save(settings, to: url)
        XCTAssertEqual(ClaudeAccountStore.load(from: url), settings)
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
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home + "/other/projects"), home + "/elsewhere")
        // Sharing again changes nothing.
        let again = ClaudeSessionSharing.plan(accounts, now: now, home: home)
        XCTAssertEqual(try ClaudeSessionSharing.apply(again, accounts: accounts, home: home), [])
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
