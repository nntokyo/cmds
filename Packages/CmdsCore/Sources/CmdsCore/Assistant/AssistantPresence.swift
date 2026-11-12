import CoreGraphics
import Foundation

/// What of the assistant is on screen (#243): nothing, the small orb that waits at the bottom right (Settings ›
/// Assistant › Show while waiting), or the full HUD while it is addressed, thinks, speaks or waits for an OK (and a few
/// seconds after). The orb grows into the HUD and comes back when the HUD goes.
public enum AssistantPresence {
    /// The orb's size (Settings › Assistant).
    public enum Size: String, CaseIterable, Sendable {
        case small
        case medium

        /// Points across.
        public var side: CGFloat {
            switch self {
            case .small: return 56
            case .medium: return 72
            }
        }
    }

    /// How the waiting orb looks.
    public enum Look: String, Equatable, Sendable {
        /// Listening for its name: slow breathing.
        case standingBy
        /// The microphone picks up speech: the orb follows the level.
        case hearing
        /// A workspace needs the user: orange.
        case attention
        /// Listening paused: dim and hollow.
        case paused
    }

    public enum Shown: Equatable, Sendable {
        case none
        case orb(Look)
        case hud
    }

    /// Off: nothing (a goodbye still shows on the HUD). The HUD when it shows; else the orb while on, if wanted.
    /// Hearing beats attention: the user sees at once that they are heard.
    public static func shown(phase: AssistantMachine.Phase, hudShown: Bool, showWhileWaiting: Bool, attention: Bool,
                             hearing: Bool) -> Shown {
        if hudShown { return .hud }
        guard showWhileWaiting else { return .none }
        switch phase {
        case .off: return .none
        case .paused: return .orb(.paused)
        case .idle, .listening, .thinking, .speaking, .confirming:
            if hearing { return .orb(.hearing) }
            return .orb(attention ? .attention : .standingBy)
        }
    }

    /// The gap to the edges of the visible frame (above the Dock, left of the screen's right edge).
    public static let margin: CGFloat = 20

    /// The orb's centre by default: bottom right of `visible` (the screen's frame without the menu bar and the Dock).
    public static func defaultCenter(visible: CGRect, side: CGFloat) -> CGPoint {
        CGPoint(x: visible.maxX - margin - side / 2, y: visible.minY + margin + side / 2)
    }

    /// Where the orb goes: `saved` (its centre, where the user dragged it) moved fully inside the visible frame of the
    /// screen that holds it, or of the nearest one when it was dropped just past an edge (onto the Dock, below the
    /// screen); the default on `visibles[0]` (the menu bar's screen) when there is none or no screen is near it any
    /// more (a display was unplugged).
    public static func center(saved: CGPoint?, side: CGFloat, visibles: [CGRect]) -> CGPoint {
        guard let main = visibles.first else { return saved ?? .zero }
        func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
        }
        guard let saved, let screen = visibles.min(by: { distance($0, saved) < distance($1, saved) }),
              distance(screen, saved) <= nearScreen else {
            return defaultCenter(visible: main, side: side)
        }
        let half = side / 2
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { high < low ? (low + high) / 2 : min(max(value, low), high) }
        return CGPoint(x: clamp(saved.x, screen.minX + half, screen.maxX - half),
                       y: clamp(saved.y, screen.minY + half, screen.maxY - half))
    }

    /// How far outside a screen's visible frame a dropped orb still belongs to that screen (the Dock, the menu bar).
    public static let nearScreen: CGFloat = 160

    /// The saved centre as stored in the defaults ("x,y"); nil for anything else.
    public static func parse(_ text: String?) -> CGPoint? {
        guard let parts = text?.split(separator: ","), parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)), x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    public static func format(_ point: CGPoint) -> String {
        "\(Int(point.x.rounded())),\(Int(point.y.rounded()))"
    }

    /// A press that moved less than this is a click, not a drag.
    public static let dragThreshold: CGFloat = 4

    /// Whether the microphone picks up speech, from its level (0…1, about 20 times a second): on above `onLevel`,
    /// off only after `hold` below `offLevel`, so the orb does not flicker between words.
    public struct Hearing: Equatable, Sendable {
        public static let onLevel: Float = 0.15
        public static let offLevel: Float = 0.08
        public static let hold: TimeInterval = 0.6

        public private(set) var isHearing = false
        private var quietSince: Date?

        public init() {}

        /// Returns true when `isHearing` changed.
        @discardableResult
        public mutating func update(level: Float, now: Date) -> Bool {
            let before = isHearing
            if level >= Self.onLevel {
                isHearing = true
                quietSince = nil
            } else if isHearing {
                if level >= Self.offLevel {
                    quietSince = nil
                } else if let since = quietSince {
                    if now.timeIntervalSince(since) >= Self.hold {
                        isHearing = false
                        quietSince = nil
                    }
                } else {
                    quietSince = now
                }
            }
            return isHearing != before
        }

        /// The microphone stopped (paused, off): nothing is heard.
        public mutating func reset() {
            isHearing = false
            quietSince = nil
        }
    }
}
