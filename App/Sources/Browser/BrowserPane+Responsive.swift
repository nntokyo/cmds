import AppKit
import WebKit
import CmdsCore

// Turning a browser pane's responsive view on and off (#170; the view itself: ResponsiveView.swift).
extension BrowserPane {
    /// The pane's responsive view settings; nil when the page is shown once.
    var responsive: BrowserResponsive? { responsiveView?.settings }

    /// `browser.set_responsive` and the Device menu; returns the state as the API reports it.
    @discardableResult
    func applyResponsive(_ change: BrowserResponsiveChange) throws -> JSONValue {
        setResponsive(try change.applied(to: responsive))
        return responsive?.json ?? BrowserResponsive.offJSON
    }

    /// Shows the page in the frames of `settings` (validated), or once again for nil.
    func setResponsive(_ settings: BrowserResponsive?) {
        if let view = responsiveView, let settings, view.settings.devices == settings.devices {
            guard view.settings != settings else { return }
            view.setSyncScroll(settings.scrollSynced)
            onEmulationChange?()
            return
        }
        guard settings != nil || responsiveView != nil else { return }
        if let view = responsiveView {
            view.close()
            view.removeFromSuperview()
            responsiveView = nil
            viewportHost.addSubview(webView)
            viewportHost.isHidden = false
            webView.setUserAgent(emulation.userAgent)
            layoutWebView()
        }
        if let settings, let view = try? ResponsiveView(primary: webView, settings: settings) {
            viewportHost.isHidden = true
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: viewportHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: viewportHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: viewportHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: viewportHost.bottomAnchor),
            ])
            responsiveView = view
            applyInspectable()  // the new frames follow Settings › Allow Safari's Web Inspector (#202)
        }
        updateDeviceButton()
        scheduleBreakpointRefresh()
        onEmulationChange?()
    }

    @objc func responsiveViewChosen() {
        setResponsive(responsive == nil ? BrowserResponsive() : nil)
    }

    @objc func syncScrollingChosen() {
        guard var settings = responsive else { return }
        settings.syncScroll = settings.scrollSynced ? false : nil
        setResponsive(settings)
    }
}
