import Foundation

// Point at Element (docs/guide/workspaces-and-panes.md "Point at an element"): in a browser pane, the user picks an
// element of the page, writes what is wrong with it, and the report (the comment, the element, where its code is and a
// screenshot with it outlined) goes to the coding agent in the terminal as a prompt. The idea comes from FixKit
// (github.com/ostiums/fixkit), which does the same for iOS, React Native and Flutter apps in the simulator.
//
// Two page scripts: `pickScript` runs in cmds' content world (the page cannot see or fake it) and lets the user pick;
// `sourceScript` runs in the page's world, where the frameworks keep what they know about an element (React fibers,
// Vue component instances, Svelte metadata) as properties other worlds cannot see. The picked element carries the
// attribute `ElementPoint.markAttribute` with a random token between the two.

/// What the page told about the picked element (`ElementPoint.pickScript` and `ElementPoint.sourceScript`).
public struct PointedElement: Codable, Equatable, Sendable {
    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Where the element's code is, as the page's framework or a dev tool's attribute tells it.
    public struct Source: Codable, Equatable, Sendable {
        /// As the page gave it: a path, or a URL of the dev server's module (`ElementPoint.sourcePath` cleans it).
        public var file: String
        public var line: Int?
        public var column: Int?
        /// `attribute` (a dev tool wrote it into the DOM), `framework` (the framework's own record), `sourcemap` (the
        /// creation stack's line mapped back with the module's source map) or `stack` (the line of the served module
        /// that created the element, no source map found; with a transpiler it can differ from the source file).
        public var via: String?

        public init(file: String, line: Int? = nil, column: Int? = nil, via: String? = nil) {
            self.file = file
            self.line = line
            self.column = column
            self.via = via
        }
    }

    /// `button`, `div`…
    public var tag: String
    /// A CSS selector that finds the element in the page.
    public var selector: String
    /// The element's opening tag, capped.
    public var html: String
    /// Its visible text, whitespace collapsed, capped.
    public var text: String?
    /// Its accessible label: `aria-label`, `alt`, `title` or `placeholder`.
    public var label: String?
    /// The box in CSS pixels, relative to the viewport.
    public var rect: Rect
    public var viewportWidth: Double
    public var viewportHeight: Double
    public var scrollX: Double?
    public var scrollY: Double?
    /// A few computed styles (`font-size: 14px`), in a fixed order.
    public var styles: [String]?
    /// React, Vue, Svelte, Angular, Astro… when the page tells.
    public var framework: String?
    /// The components around the element, outermost first.
    public var components: [String]?
    public var source: Source?
    /// The same-origin frames the element is in, outermost first (`iframe#preview (http://…)`); nil in the page itself.
    public var frame: String?
    /// The responsive view's device the element was picked in (`iPhone 390×844`); nil outside the responsive view.
    public var device: String?

    public init(tag: String, selector: String, html: String, text: String? = nil, label: String? = nil, rect: Rect,
                viewportWidth: Double, viewportHeight: Double, scrollX: Double? = nil, scrollY: Double? = nil,
                styles: [String]? = nil, framework: String? = nil, components: [String]? = nil, source: Source? = nil,
                frame: String? = nil) {
        self.tag = tag
        self.selector = selector
        self.html = html
        self.text = text
        self.label = label
        self.rect = rect
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.styles = styles
        self.framework = framework
        self.components = components
        self.source = source
        self.frame = frame
    }

    /// The short name the composer shows: `button "Save changes"`, `img "Logo"`, `div.card`.
    public var summary: String {
        let name = (label?.isEmpty == false ? label : nil) ?? (text?.isEmpty == false ? text : nil)
        guard let name else { return selector.split(separator: " ").last.map(String.init) ?? tag }
        return "\(tag) \"\(ElementPoint.capped(name, 40))\""
    }

    /// Adds what `sourceScript` found (its JSON object: `framework`, `components`, `source`).
    public mutating func merge(sourceInfo: JSONValue) {
        if let framework = sourceInfo["framework"]?.stringValue, !framework.isEmpty { self.framework = framework }
        if let names = sourceInfo["components"]?.arrayValue?.compactMap(\.stringValue), !names.isEmpty {
            components = names
        }
        if let source = try? sourceInfo["source"]?.decode(Source.self), !source.file.isEmpty { self.source = source }
    }
}

public enum ElementPoint {
    /// The attribute the picked element carries while its report is written (the page-world script finds it by it).
    public static let markAttribute = "data-cmds-point"
    /// Where reports go in the folder of the agent's terminal (`.cmds/` ignores itself for git).
    public static let reportsFolder = ".cmds/reports"
    /// Reports kept in a folder; older ones are removed when a new one is written.
    public static let keptReports = 30
    /// How long the page waits for a pick before giving up (the user walked away).
    public static let pickTimeout: TimeInterval = 600

    /// The prompt the agent gets: the user's comment first (what the agent acts on), then the facts.
    /// `screenshot`: the path to show the agent (relative to its folder when inside it).
    public static func prompt(comment: String, element: PointedElement, url: String?, title: String?,
                              screenshot: String?) -> String {
        ([comment.trimmingCharacters(in: .whitespacesAndNewlines), "", "[Pointed at in the cmds browser]"]
            + facts(element: element, url: url, title: title, screenshot: screenshot)).joined(separator: "\n")
    }

    /// The element's facts, one per line: page, element, selector, source, components, box, styles, HTML, screenshot.
    public static func facts(element: PointedElement, url: String?, title: String?, screenshot: String?) -> [String] {
        var lines: [String] = []
        if let url, !url.isEmpty {
            let named = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            lines.append("Page: \(url)" + (named.map { " (\"\(capped($0, 80))\")" } ?? ""))
        }
        if let device = element.device, !device.isEmpty { lines.append("Device: \(device) (responsive view)") }
        if let frame = element.frame, !frame.isEmpty { lines.append("Frame: \(frame)") }
        lines.append("Element: \(element.summary)")
        lines.append("Selector: \(element.selector)")
        if let source = element.source {
            var where_ = sourcePath(source.file)
            if let line = source.line {
                where_ += ":\(line)"
                if let column = source.column { where_ += ":\(column)" }
            }
            var notes: [String] = []
            if let framework = element.framework { notes.append(framework) }
            if source.via == "stack" { notes.append("line in the served module, may differ slightly") }
            lines.append("Source: \(where_)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"))
        } else if let framework = element.framework {
            lines.append("Framework: \(framework)")
        }
        if let components = element.components, !components.isEmpty {
            lines.append("Components: \(components.joined(separator: " › "))")
        }
        let r = element.rect
        var box = "Box: \(number(r.width))×\(number(r.height)) at \(number(r.x)),\(number(r.y)) in a "
            + "\(number(element.viewportWidth))×\(number(element.viewportHeight)) viewport"
        if let x = element.scrollX, let y = element.scrollY, x != 0 || y != 0 { box += " scrolled to \(number(x)),\(number(y))" }
        lines.append(box)
        if let styles = element.styles, !styles.isEmpty { lines.append("Styles: \(styles.joined(separator: "; "))") }
        if !element.html.isEmpty { lines.append("HTML: \(element.html)") }
        if let screenshot { lines.append("Screenshot (element outlined in red): \(screenshot)") }
        return lines
    }

    // MARK: - Asked by an agent (`browser.point`)

    /// How long `browser.point` waits for the user's click by default, and at most (seconds).
    public static let defaultAgentTimeout: Double = 120
    public static let maxAgentTimeout: Double = 600
    /// The request shown to the user is cut to this length.
    public static let maxAgentPromptLength = 300

    /// `browser.point` parameters: `prompt` (what the agent asks the user to click, optional) and `timeout` (seconds).
    public struct AgentRequest: Equatable, Sendable {
        public var prompt: String?
        public var timeout: Double

        public init(params: JSONValue?) throws {
            if let raw = params?["prompt"], raw != .null {
                guard let text = raw.stringValue else { throw RPCError.invalidParams("prompt must be a string") }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                prompt = trimmed.isEmpty ? nil : ElementPoint.capped(trimmed, ElementPoint.maxAgentPromptLength)
            }
            timeout = ElementPoint.defaultAgentTimeout
            if let raw = params?["timeout"], raw != .null {
                guard case .number(let seconds) = raw, seconds.isFinite, seconds >= 1,
                      seconds <= ElementPoint.maxAgentTimeout else {
                    throw RPCError.invalidParams("timeout must be 1 to \(Int(ElementPoint.maxAgentTimeout)) seconds")
                }
                timeout = seconds
            }
        }

        public var params: [String: JSONValue?] {
            ["prompt": prompt.map(JSONValue.string), "timeout": .number(timeout)]
        }
    }

    /// The answer of `browser.point`: `{element, url, title, text}` (`text`: the facts, one per line).
    public static func agentResult(element: PointedElement, url: String?, title: String?) -> JSONValue {
        let encoded = (try? JSONEncoder().encode(element)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return .object([
            "element": encoded ?? .null,
            "url": url.map(JSONValue.string) ?? .null,
            "title": title.map(JSONValue.string) ?? .null,
            "text": .string(facts(element: element, url: url, title: title, screenshot: nil).joined(separator: "\n")),
        ])
    }

    /// The error when the user gave up (Esc, Cancel, another page); 408 is the timeout.
    public static let cancelledCode = 409

    /// A source location as the agent can open it: a dev server URL becomes its path (`http://localhost:5173/src/App.tsx?t=1`
    /// → `src/App.tsx`), webpack's `webpack-internal:///(app-pages-browser)/./src/page.tsx` → `src/page.tsx`, Vite's
    /// `/@fs/Users/me/app/x.ts` → `/Users/me/app/x.ts`, `file:///…` → its path; a path stays as it is.
    public static func sourcePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["webpack-internal:///", "webpack:///", "webpack://"] where path.hasPrefix(prefix) {
            path.removeFirst(prefix.count)
            if path.hasPrefix("("), let close = path.firstIndex(of: ")") { path = String(path[path.index(after: close)...]) }
            if path.hasPrefix("/") { path.removeFirst() }
            // `webpack://app-name/./src/x` names the package before the path.
            if !path.hasPrefix("."), let slash = path.firstIndex(of: "/"), path[slash...].hasPrefix("/./") {
                path = String(path[path.index(after: slash)...])
            }
        }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path
        } else if let url = URL(string: path), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            path = url.path
            if !path.hasPrefix("/@fs/"), path.hasPrefix("/") { path.removeFirst() }
        }
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        if path.hasPrefix("/@fs/") { path.removeFirst(4) }
        if path.hasPrefix("./") { path.removeFirst(2) }
        return path.removingPercentEncoding ?? path
    }

    /// The report's screenshot name: `point-20261124-153012-1.png`.
    public static func screenshotName(at date: Date, sequence: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "point-\(formatter.string(from: date))-\(sequence).png"
    }

    static func capped(_ text: String, _ max: Int) -> String {
        text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value || abs(value) >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    // MARK: - Page scripts

    /// Lets the user pick an element (an async function body for cmds' content world; argument `token`). Outlines the
    /// element under the pointer with its name, swallows the click that picks it (the page never sees it), Esc gives
    /// up. Resolves with the element's facts (a `PointedElement` without framework facts), or null. The picked element
    /// stays outlined (following scrolls) and marked until `clearScript`; `cancelScript` gives up a pick in progress.
    public static let pickScript = """
        if (window.__cmdsPoint) window.__cmdsPoint.clear();
        return await new Promise((resolve) => {
          const host = document.createElement('cmds-point');
          host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;';
          const root = host.attachShadow({ mode: 'closed' });
          const box = document.createElement('div');
          box.style.cssText = 'position:fixed;box-sizing:border-box;border:2px solid #ff3b30;background:rgba(255,59,48,.10);'
            + 'border-radius:2px;display:none;pointer-events:none;';
          const tag = document.createElement('div');
          tag.style.cssText = 'position:fixed;font:600 11px/1.4 -apple-system,system-ui,sans-serif;color:#fff;'
            + 'background:#ff3b30;padding:1px 6px;border-radius:4px;white-space:nowrap;display:none;pointer-events:none;';
          root.append(box, tag);
          document.documentElement.append(host);

          let current = null, pinned = null, frame = 0, done = false;
          // Same-origin frames (Storybook's preview, an embedded app) are pointed into: each frame's window gets the
          // listeners and the cursor; a frame that loads later is hooked when the pointer is over it.
          const hooked = [];
          const hookedDocs = new WeakSet();
          const short = (el) => {
            let name = el.tagName.toLowerCase();
            if (el.id) name += '#' + el.id;
            const classes = [...el.classList].slice(0, 2);
            if (classes.length) name += '.' + classes.join('.');
            return name;
          };
          // The element's box in the top viewport: its frames' boxes (and borders) added.
          const rectOf = (el) => {
            const r = el.getBoundingClientRect();
            let x = r.left, y = r.top, doc = el.ownerDocument;
            for (let depth = 0; doc && doc !== document && depth < 10; depth++) {
              const holder = doc.defaultView && doc.defaultView.frameElement;
              if (!holder) break;
              const f = holder.getBoundingClientRect();
              x += f.left + holder.clientLeft;
              y += f.top + holder.clientTop;
              doc = holder.ownerDocument;
            }
            return { left: x, top: y, width: r.width, height: r.height, bottom: y + r.height };
          };
          const place = (el, label) => {
            const r = rectOf(el);
            Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px',
                                       width: Math.max(r.width, 2) + 'px', height: Math.max(r.height, 2) + 'px' });
            if (!label) { tag.style.display = 'none'; return; }
            tag.textContent = label + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
            tag.style.display = 'block';
            const above = r.top - 20;
            tag.style.left = Math.max(0, Math.min(r.left, innerWidth - tag.offsetWidth - 2)) + 'px';
            tag.style.top = (above >= 0 ? above : Math.min(r.bottom + 2, innerHeight - 20)) + 'px';
          };
          const isFrame = (el) => el && (el.tagName === 'IFRAME' || el.tagName === 'FRAME');
          const reachable = (holder) => { try { return holder.contentDocument && holder.contentWindow ? holder.contentWindow : null; } catch { return null; } };
          const at = (x, y, doc) => {
            let el = doc.elementFromPoint(x, y);
            while (el && el.shadowRoot) {
              const inner = el.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === el) break;
              el = inner;
            }
            return el === doc.documentElement ? doc.body || el : el;
          };
          const docOf = (e) => (e.view && e.view.document) || (e.target && e.target.ownerDocument) || document;
          const block = (e) => { e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation(); };
          const move = (e) => {
            const el = at(e.clientX, e.clientY, docOf(e));
            if (!el) return;
            if (isFrame(el)) { const win = reachable(el); if (win) hook(win); }
            current = el;
            place(el, short(el));
          };
          const press = (e) => block(e);
          const click = (e) => {
            block(e);
            const el = at(e.clientX, e.clientY, docOf(e)) || current;
            if (el) pick(el);
          };
          const key = (e) => {
            if (e.key !== 'Escape') return;
            block(e);
            finish(null);
          };
          const events = [['pointermove', move], ['mousemove', move], ['pointerdown', press], ['mousedown', press],
                          ['pointerup', press], ['mouseup', press], ['touchstart', press], ['dblclick', press],
                          ['auxclick', press], ['contextmenu', press], ['click', click], ['keydown', key]];
          function hook(win) {
            let doc;
            try { doc = win.document; } catch { return; }
            if (!doc || hookedDocs.has(doc)) return;
            hookedDocs.add(doc);
            const cursor = doc.createElement('style');
            cursor.textContent = '*, *::before, *::after { cursor: crosshair !important; }';
            (doc.head || doc.documentElement).append(cursor);
            for (const [name, handler] of events) win.addEventListener(name, handler, true);
            hooked.push({ win, cursor });
            for (const holder of doc.querySelectorAll('iframe, frame')) {
              const inner = reachable(holder);
              if (inner && hooked.length < 20) hook(inner);
            }
          }
          const stopListening = () => {
            for (const { win, cursor } of hooked) {
              try { for (const [name, handler] of events) win.removeEventListener(name, handler, true); } catch {}
              cursor.remove();
            }
            hooked.length = 0;
          };
          const clear = () => {
            stopListening();
            cancelAnimationFrame(frame);
            host.remove();
            if (pinned) pinned.removeAttribute(\(jsString(markAttribute)));
            pinned = null;
            if (window.__cmdsPoint === api) delete window.__cmdsPoint;
          };
          const finish = (value) => {
            if (done) return;
            done = true;
            if (value === null) clear();
            resolve(value);
          };
          const follow = () => {
            if (!pinned || !pinned.isConnected) { box.style.display = 'none'; return; }
            place(pinned, null);
            frame = requestAnimationFrame(follow);
          };
          const capped = (text, max) => text.length > max ? text.slice(0, max - 1) + '…' : text;
          const selectorOf = (el) => {
            const doc = el.ownerDocument;
            const unique = (sel) => { try { return doc.querySelectorAll(sel).length === 1; } catch { return false; } };
            if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);
            const parts = [];
            let node = el;
            while (node && node.nodeType === 1 && node !== doc.documentElement && parts.length < 8) {
              let part = node.tagName.toLowerCase();
              if (node.id && unique('#' + CSS.escape(node.id))) { parts.unshift('#' + CSS.escape(node.id)); break; }
              const classes = [...node.classList].filter((c) => /^[A-Za-z_-][\\w-]*$/.test(c) && c.length < 40).slice(0, 2);
              if (classes.length) part += '.' + classes.map((c) => CSS.escape(c)).join('.');
              const parent = node.parentElement;
              if (parent) {
                const same = [...parent.children].filter((c) => c.tagName === node.tagName);
                if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
              }
              parts.unshift(part);
              const sel = parts.join(' > ');
              if (unique(sel)) return sel;
              node = parent;
            }
            return parts.join(' > ');
          };
          // The frames around the element, outermost first: `iframe#preview (http://…/iframe.html?id=…)`.
          const frameOf = (el) => {
            const chain = [];
            let doc = el.ownerDocument;
            for (let depth = 0; doc && doc !== document && depth < 10; depth++) {
              const holder = doc.defaultView && doc.defaultView.frameElement;
              if (!holder) break;
              chain.unshift(selectorOf(holder) + ' (' + capped(String(doc.location.href), 200) + ')');
              doc = holder.ownerDocument;
            }
            return chain.length ? chain.join(' › ') : null;
          };
          const facts = (el) => {
            const r = rectOf(el);
            const open = (el.outerHTML.match(/^<[^>]*>/) || [''])[0];
            const text = (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
            const label = ['aria-label', 'alt', 'title', 'placeholder'].map((n) => el.getAttribute(n)).find((v) => v && v.trim());
            const style = (el.ownerDocument.defaultView || window).getComputedStyle(el);
            const styles = ['display', 'position', 'width', 'height', 'margin', 'padding', 'font-size', 'font-weight',
                            'line-height', 'color', 'background-color', 'border-radius', 'opacity']
              .map((n) => [n, style.getPropertyValue(n)])
              .filter(([n, v]) => v && v !== 'normal' && v !== 'none' && !(n === 'opacity' && v === '1')
                                  && !(n === 'background-color' && v === 'rgba(0, 0, 0, 0)')
                                  && !(n === 'position' && v === 'static') && v !== '0px')
              .map(([n, v]) => n + ': ' + v);
            return {
              tag: el.tagName.toLowerCase(), selector: selectorOf(el), html: capped(open, 300),
              text: text ? capped(text, 160) : null, label: label ? capped(label.trim(), 120) : null,
              rect: { x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) },
              viewportWidth: innerWidth, viewportHeight: innerHeight, scrollX: Math.round(scrollX), scrollY: Math.round(scrollY),
              styles, frame: frameOf(el),
            };
          };
          const pick = (el) => {
            stopListening();
            let value;
            try { value = facts(el); } catch (error) { value = { tag: el.tagName.toLowerCase(), selector: '', html: '',
              rect: { x: 0, y: 0, width: 0, height: 0 }, viewportWidth: innerWidth, viewportHeight: innerHeight }; }
            pinned = el;
            el.setAttribute(\(jsString(markAttribute)), token);  // after the facts: not in their HTML
            place(el, null);
            frame = requestAnimationFrame(follow);
            finish(value);
          };
          const api = { cancel: () => finish(null), clear: () => { finish(null); clear(); } };
          window.__cmdsPoint = api;
          hook(window);
        });
        """

    /// Gives up a pick in progress (the pick script resolves with null).
    public static let cancelScript = "if (window.__cmdsPoint) window.__cmdsPoint.cancel(); return null;"
    /// Removes the outline and the mark of a picked element.
    public static let clearScript = "if (window.__cmdsPoint) window.__cmdsPoint.clear(); return null;"

    /// In the page's world: what the page's framework knows about the element marked with `token` —
    /// `{framework, components, source}`, or null. Dev tools' attributes first (react-dev-inspector, Vue's and
    /// Astro's dev toolbars, Svelte's metadata), then React fibers (`_debugSource` up to React 18, the element's
    /// creation stack in React 19), Vue 3 / Vue 2 component instances and Angular's dev API. Read-only.
    public static let sourceScript = """
        const mark = '[' + \(jsString(markAttribute)) + '="' + CSS.escape(token) + '"]';
        // The element may be in a same-origin frame (pickScript points into them).
        const find = (doc, depth) => {
          const found = doc.querySelector(mark);
          if (found || depth > 5) return found;
          for (const holder of doc.querySelectorAll('iframe, frame')) {
            try { const inner = holder.contentDocument && find(holder.contentDocument, depth + 1); if (inner) return inner; } catch {}
          }
          return null;
        };
        const el = find(document, 0);
        if (!el) return null;
        const out = { framework: null, components: [], source: null };
        const int = (v) => { const n = parseInt(v, 10); return Number.isFinite(n) ? n : null; };
        const fromLocation = (text, via) => {
          const m = /^(.*?):(\\d+)(?::(\\d+))?$/.exec(text || '');
          return m ? { file: m[1], line: int(m[2]), column: int(m[3]), via } : (text ? { file: text, via } : null);
        };
        const add = (name) => {
          if (!name || typeof name !== 'string' || name.length > 80) return;
          if (out.components[0] !== name) out.components.unshift(name);
        };
        try {
          for (let n = el, depth = 0; n && n.nodeType === 1 && depth < 40 && !out.source; n = n.parentElement, depth++) {
            const a = (name) => n.getAttribute(name);
            if (a('data-inspector-relative-path')) {
              out.source = { file: a('data-inspector-relative-path'), line: int(a('data-inspector-line')),
                             column: int(a('data-inspector-column')), via: 'attribute' };
            } else if (a('data-v-inspector')) {
              out.source = fromLocation(a('data-v-inspector'), 'attribute');
              out.framework = 'Vue';
            } else if (a('data-astro-source-file')) {
              const loc = fromLocation('x:' + (a('data-astro-source-loc') || ''), 'attribute') || {};
              out.source = { file: a('data-astro-source-file'), line: loc.line ?? null, column: loc.column ?? null, via: 'attribute' };
              out.framework = 'Astro';
            } else if (n.__svelte_meta && n.__svelte_meta.loc) {
              const loc = n.__svelte_meta.loc;
              out.source = { file: loc.file, line: loc.line ?? null, column: loc.column ?? null, via: 'framework' };
              out.framework = 'Svelte';
            }
          }
        } catch {}
        try {
          const key = Object.keys(el).find((k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
          if (key) {
            out.framework = out.framework || 'React';
            const fiber = el[key];
            const nameOf = (type) => {
              if (!type || typeof type === 'string') return null;
              if (typeof type === 'function') return type.displayName || type.name || null;
              return type.displayName || (type.render && (type.render.displayName || type.render.name))
                || (type.type && (type.type.displayName || type.type.name)) || null;
            };
            for (let f = fiber, depth = 0; f && depth < 200 && out.components.length < 8; f = f.return, depth++) add(nameOf(f.type));
            if (!out.source) {
              for (let f = fiber, depth = 0; f && depth < 20 && !out.source; f = f.return, depth++) {
                if (f._debugSource && f._debugSource.fileName) {
                  const s = f._debugSource;
                  out.source = { file: s.fileName, line: s.lineNumber ?? null, column: s.columnNumber ?? null, via: 'framework' };
                }
              }
            }
            if (!out.source && fiber._debugStack && fiber._debugStack.stack) {
              const frames = String(fiber._debugStack.stack).split('\\n');
              const location = /((?:https?|file|webpack-internal|webpack):\\/\\/[^\\s()]+?):(\\d+):(\\d+)/;
              for (const frame of frames) {
                const m = location.exec(frame);
                if (!m || /node_modules|react-dom|react-jsx|jsx-dev-runtime|\\/_next\\/static\\/chunks\\/(?:webpack|main|framework)/.test(m[1])) continue;
                out.source = { file: m[1], line: int(m[2]), column: int(m[3]), via: 'stack' };
                break;
              }
            }
          }
        } catch {}
        try {
          let n = el;
          while (n && !n.__vueParentComponent && !n.__vue__) n = n.parentElement;
          if (n && n.__vueParentComponent) {
            out.framework = 'Vue';
            for (let c = n.__vueParentComponent, depth = 0; c && depth < 50 && out.components.length < 8; c = c.parent, depth++) {
              const t = c.type || {};
              add(t.__name || t.name || (t.__file ? t.__file.split('/').pop().replace(/\\.vue$/, '') : null));
              if (depth === 0 && !out.source && t.__file) out.source = { file: t.__file, via: 'framework' };
            }
          } else if (n && n.__vue__) {
            out.framework = 'Vue';
            for (let c = n.__vue__, depth = 0; c && depth < 50 && out.components.length < 8; c = c.$parent, depth++) {
              const o = c.$options || {};
              add(o.name || o._componentTag || (o.__file ? o.__file.split('/').pop().replace(/\\.vue$/, '') : null));
              if (depth === 0 && !out.source && o.__file) out.source = { file: o.__file, via: 'framework' };
            }
          }
        } catch {}
        try {
          if (!out.components.length && window.ng && typeof window.ng.getOwningComponent === 'function') {
            out.framework = 'Angular';
            let component = window.ng.getOwningComponent(el);
            for (let depth = 0; component && depth < 20 && out.components.length < 8; depth++) {
              add(component.constructor && component.constructor.name);
              const hostElement = window.ng.getHostElement(component);
              component = hostElement && hostElement.parentElement ? window.ng.getOwningComponent(hostElement.parentElement) : null;
            }
          }
        } catch {}
        // A line from a stack is the served module's: with the module's source map (dev servers such as Vite inline
        // one) it becomes the source file's line.
        const mapped = async (src) => {
          if (!src || src.via !== 'stack' || !src.line || !/^https?:/.test(src.file)) return src;
          try {
            const url = new URL(src.file, location.href);
            if (url.origin !== location.origin) return src;
            const code = await (await fetch(url.href, { cache: 'force-cache' })).text();
            const at = code.lastIndexOf('sourceMappingURL=');
            if (at < 0) return src;
            const ref = code.slice(at + 17).split(/\\s/)[0];
            let map;
            if (ref.startsWith('data:')) {
              const body = ref.slice(ref.indexOf(',') + 1);
              const text = ref.includes(';base64,')
                ? new TextDecoder().decode(Uint8Array.from(atob(body), (c) => c.charCodeAt(0))) : decodeURIComponent(body);
              map = JSON.parse(text);
            } else {
              const mapURL = new URL(ref, url);
              if (mapURL.origin !== location.origin) return src;
              map = await (await fetch(mapURL.href, { cache: 'force-cache' })).json();
            }
            const digits = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
            const lines = String(map.mappings || '').split(';');
            if (src.line > lines.length) return src;
            const column = (src.column || 1) - 1;
            let source = 0, line = 0, col = 0, best = null;
            for (let i = 0; i < src.line; i++) {
              let generated = 0;
              for (const segment of lines[i].split(',')) {
                if (!segment) continue;
                const values = [];
                let shift = 0, value = 0;
                for (const ch of segment) {
                  const digit = digits.indexOf(ch);
                  value += (digit & 31) << shift;
                  if (digit & 32) { shift += 5; continue; }
                  values.push(value & 1 ? -(value >> 1) : value >> 1);
                  value = 0; shift = 0;
                }
                generated += values[0];
                if (values.length >= 4) { source += values[1]; line += values[2]; col += values[3]; }
                if (i === src.line - 1 && values.length >= 4 && generated <= column) best = { source, line, col };
              }
            }
            if (!best || !map.sources || !map.sources[best.source]) return src;
            let file = map.sources[best.source];
            if (map.sourceRoot) file = map.sourceRoot.replace(/\\/?$/, '/') + file;
            if (!/^(\\/|[a-z][a-z0-9+.-]*:)/i.test(file)) file = new URL(file, url).href;
            return { file, line: best.line + 1, column: best.col + 1, via: 'sourcemap' };
          } catch { return src; }
        };
        out.source = await mapped(out.source);
        if (out.components.length > 8) out.components = out.components.slice(-8);
        return out;
        """

    private static func jsString(_ text: String) -> String { "'" + text + "'" }
}
