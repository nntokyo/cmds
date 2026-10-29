import CmdsCore
import Foundation
import Network
import Observation

/// Bonjour discovery of Macs advertising `_cmds._tcp`.
@MainActor
@Observable
final class MacBrowser {
    private(set) var macs: [MacTarget] = []
    private(set) var isBrowsing = false
    private(set) var error: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SyncProtocol.bonjourServiceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.isBrowsing = true; self?.error = nil
                case .failed(let error), .waiting(let error):
                    self?.isBrowsing = false
                    self?.error = Self.describe(error)
                case .cancelled: self?.isBrowsing = false
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.macs = results.compactMap(Self.target(for:)).sorted { $0.displayName < $1.displayName }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    private static func target(for result: NWBrowser.Result) -> MacTarget? {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
        var display = name
        if case .bonjour(let txt) = result.metadata, let n = txt[SyncProtocol.txtKeyName], !n.isEmpty {
            display = n
        }
        return MacTarget(kind: .bonjour(name: name, type: type, domain: domain), displayName: display)
    }

    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
            return "Local network access is off. Enable it in Settings › Privacy › Local Network."
        }
        return error.localizedDescription
    }
}
