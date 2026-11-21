import Foundation

/// Suspending browser tabs that have not been shown for a while (#375; docs/guide/workspaces-and-panes.md "Tabs"):
/// the page is unloaded and loads again when the tab is shown. Never a page with unsaved input or playing media.
public enum TabSuspension {
    /// The choices in Settings (minutes; 0 = never).
    public static let choices = [0, 15, 30, 60, 120]
    public static let defaultMinutes = 30

    /// What the tab's state allows, before asking the page (`script`).
    public struct Candidate: Equatable, Sendable {
        public var hiddenFor: TimeInterval
        public var unusedFor: TimeInterval
        public var loading: Bool
        public var scheme: String?
        /// The responsive view, reload on file changes or the console drawer are on.
        public var busy: Bool
        public var alreadySuspended: Bool

        public init(hiddenFor: TimeInterval, unusedFor: TimeInterval, loading: Bool, scheme: String?, busy: Bool,
                    alreadySuspended: Bool) {
            self.hiddenFor = hiddenFor
            self.unusedFor = unusedFor
            self.loading = loading
            self.scheme = scheme
            self.busy = busy
            self.alreadySuspended = alreadySuspended
        }
    }

    /// The tab may be suspended after `minutes` (0: never): hidden and unused (no command, no click) that long, a web or
    /// local page that finished loading, nothing special switched on.
    public static func eligible(_ tab: Candidate, minutes: Int) -> Bool {
        guard minutes > 0, !tab.alreadySuspended, !tab.loading, !tab.busy,
              let scheme = tab.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return false }
        let limit = TimeInterval(minutes * 60)
        return tab.hiddenFor >= limit && tab.unusedFor >= limit
    }

    /// `callAsyncJavaScript` body: `{dirty, playing}`: a form field changed from its default (or a focused editable
    /// element with text), audio or video playing. Any error keeps the tab (the caller treats no answer as "keep").
    public static let script = """
        const changed = (e) => {
          const type = (e.type || '').toLowerCase();
          if (['hidden', 'submit', 'button', 'reset', 'image', 'file'].includes(type)) return false;
          if (e.tagName === 'SELECT') return [...e.options].some(o => o.selected !== o.defaultSelected);
          if (type === 'checkbox' || type === 'radio') return e.checked !== e.defaultChecked;
          return e.value !== e.defaultValue;
        };
        const dirty = [...document.querySelectorAll('input, textarea, select')].some(changed)
          || [...document.querySelectorAll('[contenteditable]:not([contenteditable="false"])')]
               .some(e => (e.textContent || '').trim().length > 0 && e.contains(document.activeElement));
        const playing = [...document.querySelectorAll('video, audio')].some(m => !m.paused && !m.ended);
        return { dirty, playing };
        """
}
