import Foundation

// DevTools for agents in browser panes (#167; docs/guide/ai-agents.md "Browser DevTools"): the console and error
// buffer, the page tree with refs, and click / fill / wait_for by ref or selector. The page scripts run in cmds' own
// content world (WebKit compiles them, so a page's Content Security Policy does not apply), except the small console
// hook, which must run in the page's world to see its `console` calls.

// MARK: - Console

/// One console message, uncaught error or unhandled promise rejection of a browser pane's page.
public struct ConsoleEntry: Codable, Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case debug, log, info, warn, error

        /// For `--level`: messages at this level or more severe (`log` and `info` count the same).
        public var severity: Int {
            switch self {
            case .debug: 0
            case .log, .info: 1
            case .warn: 2
            case .error: 3
            }
        }
    }

    public enum Source: String, Codable, Sendable {
        /// `console.log()` and friends.
        case console
        /// An uncaught exception (`window` `error` event).
        case error
        /// A promise rejected with nobody handling it.
        case rejection
    }

    /// Increasing per pane; `browser.console {since}` returns newer entries (`--follow`).
    public var seq: Int
    public var level: Level
    public var source: Source
    public var text: String
    /// Unix time, seconds.
    public var time: Double
    /// The page that logged it.
    public var url: String?
    /// Where an error was thrown: `script.js:12:5`.
    public var location: String?

    public init(seq: Int = 0, level: Level, source: Source = .console, text: String, time: Double, url: String? = nil,
                location: String? = nil) {
        self.seq = seq
        self.level = level
        self.source = source
        self.text = text
        self.time = time
        self.url = url
        self.location = location
    }

    /// From the page script's message (`{level, source, text, time, url?, location?}`); nil when malformed.
    public init?(message: [String: Any]) {
        guard let raw = message["level"] as? String, let level = Level(rawValue: raw),
              let text = message["text"] as? String else { return nil }
        self.init(level: level, source: (message["source"] as? String).flatMap(Source.init(rawValue:)) ?? .console,
                  text: String(text.prefix(ConsoleBuffer.maxTextLength)),
                  time: (message["time"] as? NSNumber).map { $0.doubleValue / 1000 } ?? Date().timeIntervalSince1970,
                  url: (message["url"] as? String).map { String($0.prefix(2048)) },
                  location: (message["location"] as? String).map { String($0.prefix(2048)) })
    }

    /// `12:03:04 error  Uncaught TypeError: x is undefined (app.js:3:9)`.
    public func line(timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: time))
        let clock = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let label = level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
        let prefix = source == .rejection ? "Unhandled rejection: " : ""
        return "\(clock) \(label)  \(prefix)\(text)" + (location.map { " (\($0))" } ?? "")
    }
}

/// The last `capacity` console entries of a page; older ones are dropped (and counted).
public struct ConsoleBuffer: Sendable {
    public static let defaultCapacity = 1_000
    /// Longest message kept (the page script cuts there too).
    public static let maxTextLength = 4_000

    public let capacity: Int
    public private(set) var entries: [ConsoleEntry] = []
    /// Entries dropped for the cap since the last clear.
    public private(set) var dropped = 0
    private var nextSeq = 1

    public init(capacity: Int = ConsoleBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ entry: ConsoleEntry) {
        var entry = entry
        entry.seq = nextSeq
        nextSeq += 1
        entries.append(entry)
        if entries.count > capacity {
            let excess = entries.count - capacity
            entries.removeFirst(excess)
            dropped += excess
        }
    }

    public mutating func clear() {
        entries.removeAll()
        dropped = 0
    }

    /// Entries at `level` or more severe, newer than `since`, the last `limit` of them.
    public func entries(level: ConsoleEntry.Level? = nil, since: Int? = nil, limit: Int? = nil) -> [ConsoleEntry] {
        var result = entries.filter { entry in
            (level.map { entry.level.severity >= $0.severity } ?? true) && (since.map { entry.seq > $0 } ?? true)
        }
        if let limit, result.count > limit { result = Array(result.suffix(limit)) }
        return result
    }

    /// `browser.console`'s answer: `{entries, dropped, last}` (`last`: the newest seq, for `since`).
    public func json(level: ConsoleEntry.Level?, since: Int?, limit: Int?) -> JSONValue {
        let selected = entries(level: level, since: since, limit: limit)
        return .object([
            "entries": (try? JSONValue.from(selected)) ?? .array([]),
            "dropped": .number(Double(dropped)),
            "last": .number(Double(nextSeq - 1)),
        ])
    }
}

/// The scripts that fill a pane's console buffer. `hook` runs in the page's world at document start and hands each
/// message to `listener` (cmds' world) as a DOM event whose name only the two know; `listener` batches them to the
/// `cmdsConsole` message handler. Page scripts cannot reach the handler, and a strict CSP does not stop either script
/// (WebKit injects them).
public enum ConsoleCapture {
    public static let handlerName = "cmdsConsole"
    /// Most messages the page script sends per second; the rest are counted as dropped there.
    public static let maxPerSecond = 200

    /// `eventName`: random per web view (`cmds-console-<uuid>`).
    public static func hook(eventName: String) -> String {
        """
        (() => {
          const name = \(jsonString(eventName));
          const dispatch = EventTarget.prototype.dispatchEvent, Custom = CustomEvent, stringify = JSON.stringify;
          const send = (record) => {
            try { dispatch.call(document, new Custom(name, { detail: stringify(record) })); } catch (e) {}
          };
          const text = (value) => {
            try {
              if (typeof value === 'string') return value;
              if (value instanceof Error) return (value.name || 'Error') + ': ' + value.message;
              if (value === undefined) return 'undefined';
              if (typeof value === 'function') return 'function ' + (value.name || '') + '()';
              if (typeof value === 'object' && value !== null && typeof Node !== 'undefined' && value instanceof Node) {
                return '<' + (value.nodeName || 'node').toLowerCase() + '>';
              }
              const json = stringify(value);
              return json === undefined ? String(value) : json;
            } catch (e) { try { return String(value); } catch (e2) { return '[unprintable]'; } }
          };
          const join = (args) => Array.prototype.map.call(args, text).join(' ').slice(0, \(ConsoleBuffer.maxTextLength));
          for (const level of ['debug', 'log', 'info', 'warn', 'error']) {
            const original = console[level];
            if (typeof original !== 'function') continue;
            console[level] = function (...args) {
              send({ level, source: 'console', text: join(args), time: Date.now(), url: location.href });
              return original.apply(this, args);
            };
          }
          window.addEventListener('error', (event) => {
            if (!(event instanceof ErrorEvent)) return;  // resource load errors have no message
            const where = event.filename ? event.filename + ':' + event.lineno + ':' + event.colno : undefined;
            send({ level: 'error', source: 'error', text: event.message || text(event.error), time: Date.now(),
                   url: location.href, location: where });
          });
          window.addEventListener('unhandledrejection', (event) => {
            const reason = event.reason;
            const message = reason instanceof Error ? (reason.name || 'Error') + ': ' + reason.message : text(reason);
            send({ level: 'error', source: 'rejection', text: message, time: Date.now(), url: location.href });
          });
        })();
        """
    }

    public static func listener(eventName: String) -> String {
        """
        (() => {
          if (window.__cmdsConsoleListening) return;
          window.__cmdsConsoleListening = true;
          let queue = [], timer = null, windowStart = 0, sent = 0, dropped = 0;
          const flush = () => {
            timer = null;
            if (dropped) {
              queue.push({ level: 'warn', source: 'console', time: Date.now(), url: location.href,
                           text: '[cmds] ' + dropped + ' console messages not recorded (more than \(maxPerSecond) per second)' });
              dropped = 0;
            }
            const batch = queue; queue = [];
            if (batch.length) window.webkit.messageHandlers.\(handlerName).postMessage(batch);
          };
          document.addEventListener(\(jsonString(eventName)), (event) => {
            const now = Date.now();
            if (now - windowStart > 1000) { windowStart = now; sent = 0; }
            if (++sent > \(maxPerSecond)) { dropped++; return; }
            try { queue.push(JSON.parse(event.detail)); } catch (e) { return; }
            if (!timer) timer = setTimeout(flush, 100);
          });
        })();
        """
    }

    static func jsonString(_ text: String) -> String {
        let data = try? JSONEncoder().encode(text)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

/// `browser.console` params: `level?` (that level or more severe), `since?` (entries after that seq), `limit?`
/// (the newest that many), `clear?` (empty the buffer after answering).
public struct BrowserConsoleRequest: Equatable, Sendable {
    public var level: ConsoleEntry.Level?
    public var since: Int?
    public var limit: Int?
    public var clear: Bool

    public init(level: ConsoleEntry.Level? = nil, since: Int? = nil, limit: Int? = nil, clear: Bool = false) {
        self.level = level
        self.since = since
        self.limit = limit
        self.clear = clear
    }

    public init(params: JSONValue?) throws {
        self.init()
        switch params?["level"] {
        case nil, .null?: break
        case .string(let raw)?:
            guard let level = ConsoleEntry.Level(rawValue: raw.lowercased() == "warning" ? "warn" : raw.lowercased()) else {
                throw RPCError.invalidParams("level must be debug, log, info, warn or error")
            }
            self.level = level
        default: throw RPCError.invalidParams("level must be a string")
        }
        func count(_ key: String) throws -> Int? {
            switch params?[key] {
            case nil, .null?: return nil
            case .number(let value)? where value >= 0 && value.rounded() == value && value < 1e12: return Int(value)
            default: throw RPCError.invalidParams("\(key) must be a non-negative whole number")
            }
        }
        since = try count("since")
        limit = try count("limit")
        switch params?["clear"] {
        case nil, .null?: break
        case .bool(let flag)?: clear = flag
        default: throw RPCError.invalidParams("clear must be a boolean")
        }
    }

    public var params: [String: JSONValue?] {
        var result: [String: JSONValue?] = [:]
        if let level { result["level"] = .string(level.rawValue) }
        if let since { result["since"] = .number(Double(since)) }
        if let limit { result["limit"] = .number(Double(limit)) }
        if clear { result["clear"] = .bool(true) }
        return result
    }
}

/// `browser.snapshot_tree` / `click` / `fill` / `wait_for`, checked before anything runs in the page.
public enum BrowserPageAction: Equatable, Sendable {
    /// Under `selector` (default the body), at most `maxNodes` nodes.
    case tree(selector: String?, maxNodes: Int)
    case click(ElementTarget)
    case fill(ElementTarget, value: String)
    /// Exactly one of `selector` and `text`; `timeout` in seconds.
    case waitFor(selector: String?, text: String?, timeout: Double)

    public static let maxValueLength = 100_000

    public init(method: String, params: JSONValue?) throws {
        switch method {
        case "browser.snapshot_tree":
            let selector = params?["selector"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            var maxNodes = PageScripts.maxNodes
            if case .number(let value)? = params?["maxNodes"] {
                guard value >= 1, value.rounded() == value else { throw RPCError.invalidParams("maxNodes must be a positive whole number") }
                maxNodes = min(Int(value), PageScripts.maxNodes)
            }
            self = .tree(selector: selector, maxNodes: maxNodes)
        case "browser.click":
            self = .click(try ElementTarget(params: params))
        case "browser.fill":
            guard case .string(let value)? = params?["value"] else { throw RPCError.invalidParams("value must be a string") }
            guard value.count <= Self.maxValueLength else { throw RPCError.invalidParams("value is too long") }
            self = .fill(try ElementTarget(params: params), value: value)
        case "browser.wait_for":
            let selector = params?["selector"]?.stringValue, text = params?["text"]?.stringValue
            guard (selector == nil) != (text == nil), !(selector ?? text ?? "").isEmpty else {
                throw RPCError.invalidParams("give either selector or text")
            }
            var timeout = PageScripts.defaultWaitTimeout
            switch params?["timeout"] {
            case nil, .null?: break
            case .number(let value)? where value > 0 && value <= PageScripts.maxWaitTimeout: timeout = value
            default: throw RPCError.invalidParams("timeout must be 0–\(Int(PageScripts.maxWaitTimeout)) seconds")
            }
            self = .waitFor(selector: selector, text: text, timeout: timeout)
        default:
            throw RPCError.methodNotFound(method)
        }
    }

    public var method: String {
        switch self {
        case .tree: "browser.snapshot_tree"
        case .click: "browser.click"
        case .fill: "browser.fill"
        case .waitFor: "browser.wait_for"
        }
    }

    public var params: [String: JSONValue?] {
        switch self {
        case .tree(let selector, let maxNodes):
            var result: [String: JSONValue?] = selector.map { ["selector": .string($0)] } ?? [:]
            if maxNodes != PageScripts.maxNodes { result["maxNodes"] = .number(Double(maxNodes)) }
            return result
        case .click(let target): return target.params
        case .fill(let target, let value): return target.params.merging(["value": .string(value)]) { $1 }
        case .waitFor(let selector, let text, let timeout):
            var result: [String: JSONValue?] = ["timeout": .number(timeout)]
            if let selector { result["selector"] = .string(selector) }
            if let text { result["text"] = .string(text) }
            return result
        }
    }
}

// MARK: - Targets

/// What `browser.click` / `fill` / `wait_for` act on: a ref from `browser.snapshot_tree` (`e12`) or a CSS selector.
public enum ElementTarget: Equatable, Sendable {
    case ref(String)
    case selector(String)

    /// `e` + digits is a ref, anything else a CSS selector (the CLI's single argument).
    public static func parse(_ raw: String) throws -> ElementTarget {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RPCError.invalidParams("empty ref or selector") }
        guard text.count <= BrowserSnapshotRequest.maxSelectorLength else { throw RPCError.invalidParams("selector is too long") }
        if text.range(of: #"^e\d{1,9}$"#, options: .regularExpression) != nil { return .ref(text) }
        return .selector(text)
    }

    /// From params `ref` or `selector` (exactly one).
    public init(params: JSONValue?) throws {
        let ref = params?["ref"]?.stringValue, selector = params?["selector"]?.stringValue
        switch (ref, selector) {
        case (let ref?, nil):
            guard case .ref(let checked) = try Self.parse(ref) else { throw RPCError.invalidParams("ref must look like e12") }
            self = .ref(checked)
        case (nil, let selector?):
            let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= BrowserSnapshotRequest.maxSelectorLength else {
                throw RPCError.invalidParams("selector is empty or too long")
            }
            self = .selector(trimmed)
        default:
            throw RPCError.invalidParams("give either ref (from browser.snapshot_tree) or selector")
        }
    }

    public var params: [String: JSONValue?] {
        switch self {
        case .ref(let ref): ["ref": .string(ref)]
        case .selector(let selector): ["selector": .string(selector)]
        }
    }

    public var description: String {
        switch self {
        case .ref(let ref): ref
        case .selector(let selector): selector
        }
    }
}

// MARK: - Page tree

/// One node of `browser.snapshot_tree`: an element an agent can read or act on, with the ref to act on it by.
public struct PageNode: Codable, Equatable, Sendable {
    public var ref: String
    public var role: String
    public var name: String?
    public var value: String?
    /// Heading level.
    public var level: Int?
    public var checked: Bool?
    public var disabled: Bool?
    /// Links: the target.
    public var url: String?
    public var children: [PageNode]?

    public init(ref: String, role: String, name: String? = nil, value: String? = nil, level: Int? = nil,
                checked: Bool? = nil, disabled: Bool? = nil, url: String? = nil, children: [PageNode]? = nil) {
        self.ref = ref
        self.role = role
        self.name = name
        self.value = value
        self.level = level
        self.checked = checked
        self.disabled = disabled
        self.url = url
        self.children = children
    }

    /// The compact text form (MCP, CLI): one line per node, indented by depth:
    /// `- button "Sign in" [ref=e3]`, `- textbox "Email" value="a@b.c" [ref=e4]`, `- heading "Pricing" level=2 [ref=e5]`.
    public static func text(_ nodes: [PageNode], depth: Int = 0) -> String {
        nodes.map { node in
            var line = String(repeating: "  ", count: depth) + "- " + node.role
            if let name = node.name, !name.isEmpty { line += " " + quoted(name) }
            if let value = node.value { line += " value=" + quoted(value) }
            if let level = node.level { line += " level=\(level)" }
            if let checked = node.checked { line += checked ? " checked" : " unchecked" }
            if node.disabled == true { line += " disabled" }
            if let url = node.url { line += " url=" + url }
            line += " [ref=\(node.ref)]\n"
            return line + text(node.children ?? [], depth: depth + 1)
        }.joined()
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    public static func count(_ nodes: [PageNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + count($1.children ?? []) }
    }
}

/// The page scripts of the tree and the actions. They share `window.__cmdsRefs` in cmds' content world: a ref stays
/// valid for its element until the page navigates.
public enum PageScripts {
    public static let maxNodes = 2_000
    public static let defaultWaitTimeout: Double = 5
    public static let maxWaitTimeout: Double = 60

    /// Refs, element lookup and visibility, prepended to every script.
    static let common = """
        const refs = window.__cmdsRefs || (window.__cmdsRefs = { next: 1, byRef: new Map(), byElement: new WeakMap() });
        const refOf = (element) => {
          let ref = refs.byElement.get(element);
          if (!ref) { ref = 'e' + refs.next++; refs.byElement.set(element, ref); refs.byRef.set(ref, new WeakRef(element)); }
          return ref;
        };
        const visible = (element) => {
          if (!(element instanceof Element) || !element.isConnected) return false;
          const style = getComputedStyle(element);
          if (style.visibility === 'hidden' || style.display === 'none') return false;
          const rect = element.getBoundingClientRect();
          return rect.width > 0 || rect.height > 0 || element.getClientRects().length > 0;
        };
        const resolve = (ref, selector) => {
          if (ref) {
            const element = refs.byRef.get(ref)?.deref();
            if (!element || !element.isConnected) throw new Error('ref ' + ref + ' is gone (the page changed); take a new browser.snapshot_tree');
            return element;
          }
          let element;
          try { element = document.querySelector(selector); } catch (e) { throw new Error('invalid selector ' + selector + ': ' + e.message); }
          if (!element) throw new Error('no element matches ' + selector);
          return element;
        };
        """

    /// Builds the tree under `selector` (default the body). Arguments: `selector`, `maxNodes`.
    public static let tree = common + """
        const implicit = (element) => {
          const tag = element.localName;
          switch (tag) {
            case 'a': return element.hasAttribute('href') ? 'link' : null;
            case 'button': return 'button';
            case 'select': return element.multiple ? 'listbox' : 'combobox';
            case 'textarea': return 'textbox';
            case 'img': return 'img';
            case 'nav': return 'navigation';
            case 'main': return 'main';
            case 'header': return 'banner';
            case 'footer': return 'contentinfo';
            case 'aside': return 'complementary';
            case 'form': return 'form';
            case 'dialog': return 'dialog';
            case 'table': return 'table';
            case 'ul': case 'ol': return 'list';
            case 'li': return 'listitem';
            case 'summary': return 'button';
            case 'label': return null;
            case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
            case 'input': {
              const type = (element.getAttribute('type') || 'text').toLowerCase();
              if (type === 'hidden') return null;
              return { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button',
                       image: 'button', range: 'slider', number: 'spinbutton', search: 'searchbox' }[type] || 'textbox';
            }
          }
          if (element.isContentEditable && element.parentElement && !element.parentElement.isContentEditable) return 'textbox';
          return null;
        };
        const textOf = (element) => (element.innerText || element.textContent || '').replace(/\\s+/g, ' ').trim();
        const nameOf = (element, role) => {
          const label = element.getAttribute('aria-label');
          if (label) return label.trim();
          const by = element.getAttribute('aria-labelledby');
          if (by) {
            const text = by.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map(textOf).join(' ');
            if (text) return text;
          }
          if (element.labels && element.labels.length) return Array.from(element.labels).map(textOf).join(' ');
          if (role === 'img') return element.getAttribute('alt') || element.getAttribute('title') || '';
          if (['textbox', 'searchbox', 'combobox', 'spinbutton', 'listbox', 'slider'].includes(role)) {
            return element.getAttribute('placeholder') || element.getAttribute('title') || element.getAttribute('name') || '';
          }
          if (element.localName === 'input' && ['submit', 'button', 'reset'].includes(element.type)) return element.value || element.type;
          if (['navigation', 'main', 'banner', 'contentinfo', 'complementary', 'form', 'list', 'table', 'dialog'].includes(role)) {
            return element.getAttribute('title') || '';
          }
          return element.getAttribute('title') || textOf(element);
        };
        let count = 0, truncated = false;
        const walk = (element) => {
          const nodes = [];
          for (const child of element.children) {
            if (count >= maxNodes) { truncated = true; break; }
            if (child.getAttribute('aria-hidden') === 'true' || !visible(child) && child.localName !== 'option') continue;
            const role = child.getAttribute('role') || implicit(child);
            const children = walk(child);
            if (!role) { nodes.push(...children); continue; }
            count++;
            const node = { ref: refOf(child), role };
            const name = nameOf(child, role).slice(0, 200);
            if (name) node.name = name;
            if (role === 'heading') node.level = Number(child.getAttribute('aria-level') || child.localName.slice(1)) || undefined;
            if (role === 'link') node.url = child.href;
            if (['textbox', 'searchbox', 'combobox', 'spinbutton', 'slider'].includes(role)) {
              const value = child.isContentEditable ? textOf(child) : child.value;
              if (value !== undefined && value !== '') node.value = String(value).slice(0, 200);
            }
            if (role === 'checkbox' || role === 'radio') node.checked = child.checked ?? child.getAttribute('aria-checked') === 'true';
            if (child.disabled || child.getAttribute('aria-disabled') === 'true') node.disabled = true;
            // Leaf text of links and buttons is already the name.
            if (children.length && !['link', 'button', 'heading', 'textbox', 'combobox', 'listbox'].includes(role)) node.children = children;
            nodes.push(node);
          }
          return nodes;
        };
        const root = selector ? resolve(null, selector) : document.body;
        if (!root) return { nodes: [], title: document.title, url: location.href, truncated: false };
        return { nodes: walk(root), title: document.title, url: location.href, truncated };
        """

    /// Clicks the element (pointer and mouse events, then `click()`). Arguments: `ref`, `selector`.
    public static let click = common + """
        const element = resolve(ref, selector);
        if (element.disabled) throw new Error((ref || selector) + ' is disabled');
        element.scrollIntoView({ block: 'center', inline: 'center' });
        const rect = element.getBoundingClientRect();
        const at = { bubbles: true, cancelable: true, composed: true, view: window, button: 0,
                     clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
        element.dispatchEvent(new PointerEvent('pointerdown', { ...at, pointerId: 1, isPrimary: true }));
        element.dispatchEvent(new MouseEvent('mousedown', at));
        if (typeof element.focus === 'function') element.focus();
        element.dispatchEvent(new PointerEvent('pointerup', { ...at, pointerId: 1, isPrimary: true }));
        element.dispatchEvent(new MouseEvent('mouseup', at));
        element.click();
        return { ref: refOf(element), tag: element.localName };
        """

    /// Sets the value as typing would (the element's native setter, then `input` and `change`). Arguments: `ref`,
    /// `selector`, `value`.
    public static let fill = common + """
        const element = resolve(ref, selector);
        if (element.disabled || element.readOnly) throw new Error((ref || selector) + ' is disabled or read-only');
        element.scrollIntoView({ block: 'center' });
        if (typeof element.focus === 'function') element.focus();
        const tag = element.localName;
        if (tag === 'input' && ['checkbox', 'radio'].includes(element.type)) {
          const want = ['true', 'on', '1', 'yes', 'checked'].includes(String(value).toLowerCase());
          if (element.checked !== want) element.click();
          return { ref: refOf(element), checked: element.checked };
        }
        if (tag === 'select') {
          const option = Array.from(element.options).find((o) => o.value === value || o.text.trim() === value);
          if (!option) throw new Error('no option ' + value + ' in ' + (ref || selector));
          element.value = option.value;
        } else if (tag === 'input' || tag === 'textarea') {
          const proto = tag === 'input' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
          Object.getOwnPropertyDescriptor(proto, 'value').set.call(element, value);
        } else if (element.isContentEditable) {
          element.textContent = value;
        } else {
          throw new Error((ref || selector) + ' (' + tag + ') is not a text field, select or checkbox');
        }
        element.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
        return { ref: refOf(element), value: element.isContentEditable ? element.textContent : element.value };
        """

    /// Waits until a visible element matches `selector`, or visible text contains `text`. Arguments: `selector`,
    /// `text`, `timeout` (ms). Resolves `{found, ref?, elapsed}`; `found: false` after the timeout.
    public static let waitFor = common + """
        const started = Date.now();
        const find = () => {
          if (selector) {
            let element;
            try { element = document.querySelector(selector); } catch (e) { throw new Error('invalid selector ' + selector + ': ' + e.message); }
            return element && visible(element) ? element : null;
          }
          if (!document.body || !(document.body.innerText || '').includes(text)) return null;
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          let best = document.body;
          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (node.textContent.includes(text) && node.parentElement && visible(node.parentElement)) { best = node.parentElement; break; }
          }
          return best;
        };
        for (;;) {
          const element = find();
          if (element) return { found: true, ref: refOf(element), elapsed: Date.now() - started };
          if (Date.now() - started >= timeout) return { found: false, elapsed: Date.now() - started };
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
        """
}
