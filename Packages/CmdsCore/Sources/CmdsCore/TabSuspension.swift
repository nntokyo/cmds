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

    /// `callAsyncJavaScript` body: `{dirty, playing}`. Dirty: a form field changed from its default, a focused editable
    /// element with text, or a code or rich-text editor that keeps its text in scripts (Monaco, CodeMirror, ProseMirror,
    /// Jupyter…), looked for in the page, its open shadow roots and its same-site frames. Playing: audio or video.
    /// Any error keeps the tab (the caller treats no answer as "keep").
    public static let script = """
        const editors = '.monaco-editor, .CodeMirror, .cm-editor, .ProseMirror, .ql-editor, .jp-Notebook, .ace_editor, '
          + '[role="textbox"][contenteditable], trix-editor, .tox-edit-area, .ck-editor__editable';
        const changed = (e) => {
          const type = (e.type || '').toLowerCase();
          if (['hidden', 'submit', 'button', 'reset', 'image', 'file'].includes(type)) return false;
          if (e.tagName === 'SELECT') return [...e.options].some(o => o.selected !== o.defaultSelected);
          if (type === 'checkbox' || type === 'radio') return e.checked !== e.defaultChecked;
          return e.value !== e.defaultValue;
        };
        const roots = [];
        const collect = (root, depth) => {
          if (!root || depth > 4 || roots.length > 200) return;
          roots.push(root);
          for (const e of root.querySelectorAll('*')) { if (e.shadowRoot) collect(e.shadowRoot, depth + 1); }
          for (const f of root.querySelectorAll('iframe, frame')) {
            let d = null;
            try { d = f.contentDocument; } catch (e) {}
            if (d) collect(d, depth + 1);
          }
        };
        collect(document, 0);
        let dirty = false, playing = false;
        for (const root of roots) {
          const active = root.activeElement || document.activeElement;
          if ([...root.querySelectorAll('input, textarea, select')].some(changed)
              || [...root.querySelectorAll('[contenteditable]:not([contenteditable="false"])')]
                   .some(e => (e.textContent || '').trim().length > 0 && active && e.contains(active))
              || root.querySelector(editors)) dirty = true;
          if ([...root.querySelectorAll('video, audio')].some(m => !m.paused && !m.ended)) playing = true;
        }
        return { dirty, playing };
        """
}
