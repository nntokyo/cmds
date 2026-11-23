import Foundation

// Network requests of a browser pane's page (docs/guide/ai-agents.md "Browser DevTools"; #174 G3). WKWebView has no
// network API, so the page's own view is recorded: `fetch` and `XMLHttpRequest` are wrapped (method, status, time,
// failure), and the browser's Resource Timing adds what else loaded (scripts, styles, images, the document; no status
// there). Same transport as the console (`ConsoleCapture`): a page-world hook hands records to a listener in cmds'
// world through a DOM event whose name only the two know.

/// One request of the page.
public struct NetworkEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fetch, xhr
        /// From Resource Timing: a script, style, image, font, the document… (no method or status).
        case resource
    }

    /// Order of arrival in the pane (for `since`).
    public var seq: Int
    public var kind: Kind
    /// `GET`, `POST`…; nil for resources.
    public var method: String?
    public var url: String
    /// HTTP status; 0 when the request failed before an answer (network error, CORS, aborted); nil for resources.
    public var status: Int?
    /// Why it failed (`TypeError: Load failed`, `abort`, `timeout`).
    public var error: String?
    /// Milliseconds from start to the end of the answer.
    public var duration: Double?
    /// Bytes transferred (Resource Timing) or the answer's Content-Length, when known.
    public var size: Int?
    /// Resource Timing's initiator (`script`, `img`, `link`, `css`…; `document` for the page itself), for resources.
    public var initiator: String?
    /// When it started, seconds since 1970.
    public var time: Double
    /// The page that made it.
    public var page: String?

    public init(seq: Int = 0, kind: Kind, method: String? = nil, url: String, status: Int? = nil, error: String? = nil,
                duration: Double? = nil, size: Int? = nil, initiator: String? = nil, time: Double, page: String? = nil) {
        self.seq = seq
        self.kind = kind
        self.method = method
        self.url = url
        self.status = status
        self.error = error
        self.duration = duration
        self.size = size
        self.initiator = initiator
        self.time = time
        self.page = page
    }

    /// A record of the page script (`NetworkCapture.hook`).
    public init?(message: [String: Any]) {
        guard let rawKind = message["kind"] as? String, let kind = Kind(rawValue: rawKind),
              let url = message["url"] as? String, !url.isEmpty else { return nil }
        func int(_ key: String) -> Int? { (message[key] as? NSNumber).map { $0.intValue } }
        self.init(kind: kind,
                  method: (message["method"] as? String).map { String($0.prefix(16)).uppercased() },
                  url: String(url.prefix(ConsoleBuffer.maxURLLength)),
                  status: int("status"),
                  error: (message["error"] as? String).map { String($0.prefix(300)) },
                  duration: (message["duration"] as? NSNumber).map { ($0.doubleValue * 10).rounded() / 10 },
                  size: int("size").flatMap { $0 > 0 ? $0 : nil },
                  initiator: (message["initiator"] as? String).map { String($0.prefix(32)) },
                  time: (message["time"] as? NSNumber).map { $0.doubleValue / 1000 } ?? Date().timeIntervalSince1970,
                  page: (message["page"] as? String).map { String($0.prefix(ConsoleBuffer.maxURLLength)) })
    }

    /// Failed: no answer (status 0 or an error) or an HTTP error (4xx, 5xx). Resources carry no status: only a fetch or
    /// XHR can fail here.
    public var failed: Bool {
        if error != nil { return true }
        guard let status else { return false }
        return status == 0 || status >= 400
    }

    /// `12:03:04  POST 500    83 ms  fetch  https://api.example.com/save  (TypeError: …)`.
    public func line(timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: time))
        let clock = String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let method = (method ?? "").padding(toLength: 6, withPad: " ", startingAt: 0)
        let status = (status.map(String.init) ?? "-").padding(toLength: 4, withPad: " ", startingAt: 0)
        let time = duration.map { String(format: "%5.0f ms", $0) } ?? "      - "
        let label = (kind == .resource ? (initiator ?? "resource") : kind.rawValue).padding(toLength: 8, withPad: " ", startingAt: 0)
        var text = "\(clock)  \(method)\(status)\(time)  \(label) \(url)"
        if let size { text += "  \(NetworkEntry.bytes(size))" }
        if let error { text += "  (\(error))" }
        return text
    }

    static func bytes(_ count: Int) -> String {
        if count < 1_024 { return "\(count) B" }
        if count < 1_048_576 { return String(format: "%.1f KB", Double(count) / 1_024) }
        return String(format: "%.1f MB", Double(count) / 1_048_576)
    }
}

/// The last `capacity` requests of a pane; older ones are dropped (and counted).
public struct NetworkBuffer: Sendable {
    public static let defaultCapacity = 500

    public let capacity: Int
    public private(set) var entries: [NetworkEntry] = []
    public private(set) var dropped = 0
    private var nextSeq = 1

    public init(capacity: Int = NetworkBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ entry: NetworkEntry) {
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

    public func entries(_ request: BrowserNetworkRequest) -> [NetworkEntry] {
        var result = entries.filter { entry in
            (!request.failed || entry.failed) && (request.since.map { entry.seq > $0 } ?? true)
                && (request.includeResources || entry.kind != .resource)
        }
        if let limit = request.limit, result.count > limit { result = Array(result.suffix(limit)) }
        return result
    }

    /// `browser.network`'s answer: `{entries, dropped, last}` (`last`: the newest seq, for `since`).
    public func json(_ request: BrowserNetworkRequest) -> JSONValue {
        .object([
            "entries": (try? JSONValue.from(entries(request))) ?? .array([]),
            "dropped": .number(Double(dropped)),
            "last": .number(Double(nextSeq - 1)),
        ])
    }
}

/// `browser.network` params: `failed?` (only failed fetch/XHR: no answer, 4xx, 5xx), `resources?` (also scripts,
/// styles, images… from Resource Timing; default only fetch and XHR), `since?`, `limit?`, `clear?`.
public struct BrowserNetworkRequest: Equatable, Sendable {
    public var failed = false
    public var includeResources = false
    public var since: Int?
    public var limit: Int?
    public var clear = false

    public init(failed: Bool = false, includeResources: Bool = false, since: Int? = nil, limit: Int? = nil, clear: Bool = false) {
        self.failed = failed
        self.includeResources = includeResources
        self.since = since
        self.limit = limit
        self.clear = clear
    }

    public init(params: JSONValue?) throws {
        let values = RequestParams(params)
        failed = try values.bool("failed") ?? false
        includeResources = try values.bool("resources") ?? false
        clear = try values.bool("clear") ?? false
        func count(_ key: String) throws -> Int? {
            switch values[key] {
            case nil: return nil
            case .number(let value)? where value >= 0 && value.rounded() == value && value < 1e12: return Int(value)
            default: throw RPCError.invalidParams("\(key) must be a non-negative whole number")
            }
        }
        since = try count("since")
        limit = try count("limit")
    }

    public var params: [String: JSONValue?] {
        var result: [String: JSONValue?] = [:]
        if failed { result["failed"] = .bool(true) }
        if includeResources { result["resources"] = .bool(true) }
        if let since { result["since"] = .number(Double(since)) }
        if let limit { result["limit"] = .number(Double(limit)) }
        if clear { result["clear"] = .bool(true) }
        return result
    }
}

/// The scripts that fill a pane's network buffer (see the top of this file).
public enum NetworkCapture {
    public static let handlerName = "cmdsNetwork"
    /// Most records the page sends per second; the rest are counted as dropped there.
    public static let maxPerSecond = 200

    /// Page world, document start. Wraps `fetch` and `XMLHttpRequest` (keeping their behaviour) and observes Resource
    /// Timing for the rest (fetch and XHR entries skipped: they are recorded with their status already).
    public static func hook(eventName: String) -> String {
        """
        (() => {
          const name = \(ConsoleCapture.jsonString(eventName));
          const dispatch = EventTarget.prototype.dispatchEvent, Custom = CustomEvent, stringify = JSON.stringify;
          const now = () => performance.now();
          const send = (record) => {
            record.page = location.href;
            try { dispatch.call(document, new Custom(name, { detail: stringify(record) })); } catch (e) {}
          };
          const absolute = (url) => { try { return new URL(String(url), location.href).href; } catch (e) { return String(url); } };
          const length = (value) => { const n = parseInt(value || '', 10); return Number.isFinite(n) ? n : undefined; };
          const originalFetch = window.fetch;
          if (typeof originalFetch === 'function') {
            window.fetch = function (input, init) {
              const start = now(), time = Date.now();
              let method = (init && init.method) || (input && typeof input === 'object' && input.method) || 'GET';
              const url = absolute(input && typeof input === 'object' && 'url' in input ? input.url : input);
              const promise = originalFetch.apply(this, arguments);
              promise.then((response) => {
                send({ kind: 'fetch', method, url, status: response.status, duration: now() - start, time,
                       size: length(response.headers && response.headers.get('content-length')) });
              }, (error) => {
                send({ kind: 'fetch', method, url, status: 0, duration: now() - start, time,
                       error: error && error.name === 'AbortError' ? 'abort' : String(error) });
              });
              return promise;
            };
          }
          const XHR = window.XMLHttpRequest;
          if (XHR && XHR.prototype) {
            const open = XHR.prototype.open, sendRequest = XHR.prototype.send;
            XHR.prototype.open = function (method, url) {
              this.__cmdsRequest = { method: String(method || 'GET'), url: absolute(url) };
              return open.apply(this, arguments);
            };
            XHR.prototype.send = function () {
              const info = this.__cmdsRequest;
              if (info) {
                const start = now(), time = Date.now();
                let failure;
                for (const type of ['error', 'abort', 'timeout']) this.addEventListener(type, () => { failure = type; });
                this.addEventListener('loadend', () => {
                  send({ kind: 'xhr', method: info.method, url: info.url, status: this.status, duration: now() - start, time,
                         error: failure, size: length(this.getResponseHeader && (() => { try { return this.getResponseHeader('content-length'); } catch (e) { return null; } })()) });
                });
              }
              return sendRequest.apply(this, arguments);
            };
          }
          const resource = (entry) => {
            if (entry.initiatorType === 'fetch' || entry.initiatorType === 'xmlhttprequest') return;
            send({ kind: 'resource', url: entry.name, initiator: entry.initiatorType || entry.entryType,
                   duration: entry.duration, size: entry.transferSize || entry.encodedBodySize || undefined,
                   time: Math.round(performance.timeOrigin + entry.startTime) });
          };
          try {
            new PerformanceObserver((list) => list.getEntries().forEach(resource))
              .observe({ type: 'resource', buffered: true });
          } catch (e) {}
          // The document itself, once its timing is complete (after the load event has ended).
          window.addEventListener('load', () => setTimeout(() => {
            const nav = performance.getEntriesByType && performance.getEntriesByType('navigation')[0];
            if (nav) resource({ name: nav.name, initiatorType: 'document', duration: nav.duration,
                                transferSize: nav.transferSize, startTime: nav.startTime });
          }, 0), { once: true });
        })();
        """
    }

    /// cmds' world, document start: batches the records to the `cmdsNetwork` handler (100 ms, at most
    /// `maxPerSecond`).
    public static func listener(eventName: String) -> String {
        """
        (() => {
          if (window.__cmdsNetworkListening) return;
          window.__cmdsNetworkListening = true;
          let queue = [], timer = null, windowStart = 0, sent = 0;
          const flush = () => {
            timer = null;
            const batch = queue; queue = [];
            if (batch.length) window.webkit.messageHandlers.\(handlerName).postMessage(batch);
          };
          document.addEventListener(\(ConsoleCapture.jsonString(eventName)), (event) => {
            const now = Date.now();
            if (now - windowStart > 1000) { windowStart = now; sent = 0; }
            if (++sent > \(maxPerSecond)) return;
            try { queue.push(JSON.parse(event.detail)); } catch (e) { return; }
            if (!timer) timer = setTimeout(flush, 100);
          });
        })();
        """
    }
}
