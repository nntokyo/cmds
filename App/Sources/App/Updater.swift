import AppKit
import CmdsCore
import Security
import Sparkle

/// Automatic updates (Sparkle; docs/internals/release.md#automatic-updates): a daily background check of the
/// EdDSA-signed appcast on cmds.n-n.tokyo; an update (the notarized DMG of the GitHub release, EdDSA-signed too) is
/// downloaded in the background and installed when cmds quits, or right away from cmds › Check for Updates….
/// The two switches live in cmds › Settings… › Updates.
///
/// Only a release signed with our Developer ID updates itself. Debug and local Release builds (signed for
/// development) never do: they would be replaced by the published release. Neither does an isolated instance
/// (`CMDS_SUPPORT_DIR`), unless `CMDS_UPDATE_FEED_URL` points a copy outside the Applications folders at an https test
/// feed — then it also checks at launch.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    /// Test feed for an isolated instance; ignored by the app in use.
    static let testFeedEnvironmentKey = "CMDS_UPDATE_FEED_URL"

    enum Status: Equatable {
        case starting
        case running
        /// Debug or local build, or an isolated instance without a test feed.
        case notThisBuild
        case failed(String)
    }

    private(set) var status = Status.starting
    private nonisolated let testFeedURL: String?
    private var controller: SPUStandardUpdaterController?

    override init() {
        testFeedURL = Self.testFeed()
        super.init()
    }

    /// The running updater; nil when this build or instance does not update itself.
    var updater: SPUUpdater? { controller?.updater }

    func start() {
        guard CmdsEnv.supportDirectoryOverride() == nil || testFeedURL != nil else {
            status = .notThisBuild
            return
        }
        // The signature check reads the code directory: off the main thread, so launch does not wait for it.
        Task.detached(priority: .utility) {
            let release = Self.isDeveloperIDRelease
            await MainActor.run { self.startUpdater(release: release) }
        }
    }

    private func startUpdater(release: Bool) {
        guard release else {
            status = .notThisBuild
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            status = .failed(error.localizedDescription)
            NSLog("cmds: updater not started: \(error.localizedDescription)")
            return
        }
        self.controller = controller
        status = .running
        if testFeedURL != nil { controller.updater.checkForUpdatesInBackground() }
    }

    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var installsAutomatically: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// `CMDS_UPDATE_FEED_URL` of an isolated instance, if it is https and this copy is not the installed app (an
    /// update replaces the bundle it runs from, which may be the app in use).
    private static func testFeed() -> String? {
        guard CmdsEnv.supportDirectoryOverride() != nil,
              let feed = ProcessInfo.processInfo.environment[testFeedEnvironmentKey], feed.hasPrefix("https://")
        else { return nil }
        let path = Bundle.main.bundlePath
        let installed = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return installed.contains(where: path.hasPrefix) ? nil : feed
    }

    /// This app (bundle identifier) signed with our team's Developer ID certificate, as releases are; development
    /// signing is not.
    private nonisolated static var isDeveloperIDRelease: Bool {
        let developerID = "identifier \"tokyo.n-n.cmds\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"LY354RVYHA\""
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

extension Updater: SPUUpdaterDelegate {
    /// nil keeps `SUFeedURL` from Info.plist.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        testFeedURL
    }
}

extension Updater: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return updater?.canCheckForUpdates ?? false
    }
}
