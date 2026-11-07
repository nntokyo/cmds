import Foundation

/// A terminal colour as the program set it: an index into the palette (0–15 the ANSI colours, which each side maps to
/// its own palette; 16–255 the xterm cube and greys) or a direct RGB colour. Default colours are not a value: a nil
/// colour is the default.
public enum TerminalColor: Hashable, Sendable {
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    /// Wire form (sync `styles`): 0–255 a palette index, `0x1000000 + 0xRRGGBB` an RGB colour.
    public var wireValue: Int {
        switch self {
        case .palette(let index): return Int(index)
        case .rgb(let r, let g, let b): return Self.rgbFlag | Int(r) << 16 | Int(g) << 8 | Int(b)
        }
    }

    public init?(wireValue: Int) {
        switch wireValue {
        case 0...255: self = .palette(UInt8(wireValue))
        case Self.rgbFlag...(Self.rgbFlag | 0xFFFFFF):
            self = .rgb(UInt8(wireValue >> 16 & 0xFF), UInt8(wireValue >> 8 & 0xFF), UInt8(wireValue & 0xFF))
        default: return nil
        }
    }

    static let rgbFlag = 0x100_0000
}

/// The look of a stretch of cells. The default (all nil / empty) is the terminal's own colours, unstyled.
public struct TerminalStyle: Hashable, Sendable {
    public struct Attributes: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let bold = Attributes(rawValue: 1)
        public static let faint = Attributes(rawValue: 2)
        public static let italic = Attributes(rawValue: 4)
        public static let underline = Attributes(rawValue: 8)
        /// Foreground and background swapped.
        public static let inverse = Attributes(rawValue: 16)
        public static let strikethrough = Attributes(rawValue: 32)
        /// Text drawn in the background colour (SGR 8).
        public static let invisible = Attributes(rawValue: 64)

        /// Every bit this build knows; others are dropped when decoding.
        public static let all: Attributes = [.bold, .faint, .italic, .underline, .inverse, .strikethrough, .invisible]
    }

    public var attributes: Attributes
    public var foreground: TerminalColor?
    public var background: TerminalColor?

    public init(attributes: Attributes = [], foreground: TerminalColor? = nil, background: TerminalColor? = nil) {
        self.attributes = attributes
        self.foreground = foreground
        self.background = background
    }

    public static let plain = TerminalStyle()
    public var isPlain: Bool { self == .plain }
}

/// Cells `column ..< column + length` of a row drawn in `style` (never the plain style: plain cells carry no run).
/// Columns count cells as the phone's grid does (`TerminalCells`: 2 for a wide character) over the row's text; a run
/// may go past the end of the text (a background up to the right edge), over blank cells.
///
/// Wire form (sync `styles`, `LineChange.runs`): an array of integers `[column, length, attributes, fg, bg]`, colours
/// as `TerminalColor.wireValue`, -1 for the default colour; trailing defaults (0 attributes, -1 colours) left out.
/// E.g. `[0,4,1]` bold, `[6,3,0,1]` palette red, `[0,80,16,-1,4]` inverse on palette blue.
public struct StyleRun: Hashable, Sendable {
    public var column: Int
    public var length: Int
    public var style: TerminalStyle

    public init(column: Int, length: Int, style: TerminalStyle) {
        self.column = column
        self.length = length
        self.style = style
    }

    public var end: Int { column + length }
}

extension StyleRun: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        column = try c.decode(Int.self)
        length = try c.decode(Int.self)
        let attributes = c.isAtEnd ? 0 : try c.decode(Int.self)
        let fg = c.isAtEnd ? -1 : try c.decode(Int.self)
        let bg = c.isAtEnd ? -1 : try c.decode(Int.self)
        guard column >= 0, length > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad run"))
        }
        style = TerminalStyle(attributes: TerminalStyle.Attributes(rawValue: attributes).intersection(.all),
                              foreground: TerminalColor(wireValue: fg), background: TerminalColor(wireValue: bg))
    }

    public func encode(to encoder: Encoder) throws {
        var values = [column, length, style.attributes.rawValue,
                      style.foreground?.wireValue ?? -1, style.background?.wireValue ?? -1]
        while values.count > 2, values.last == (values.count == 3 ? 0 : -1) { values.removeLast() }
        var c = encoder.unkeyedContainer()
        try c.encode(contentsOf: values)
    }
}

/// A row read from the terminal as VT text (cmds' libghostty patch `ghostty_surface_read_text_vt`) turned into its
/// plain text and style runs (pure; the Mac sends both to phones with `SyncFeature.styles`).
///
/// Understands what Ghostty's formatter writes for a row: SGR (also with `:` sub-parameters), CUF over blank cells,
/// ECH for cells that only carry a background, OSC 8 hyperlinks (skipped). Blank cells become spaces, so the text is
/// the row's plain text (`ghostty_surface_read_text`) plus, at most, trailing spaces where styled blank cells are.
public enum TerminalStyledText {
    public static func parse(_ vt: String) -> (text: String, runs: [StyleRun]) {
        var parser = Parser()
        parser.run(vt)
        return (parser.text, parser.runs)
    }

    private struct Parser {
        var text = ""
        var runs: [StyleRun] = []
        var column = 0
        var style = TerminalStyle.plain
        /// Cells that ECH erased at the cursor (with the current background) and that the CUF after it steps over.
        var erased = 0

        mutating func run(_ vt: String) {
            let scalars = Array(vt.unicodeScalars)
            var i = 0
            var printable = String.UnicodeScalarView()
            func flush(_ parser: inout Parser) {
                guard !printable.isEmpty else { return }
                parser.put(String(printable))
                printable.removeAll()
            }
            while i < scalars.count {
                let scalar = scalars[i]
                switch scalar.value {
                case 0x1B:
                    flush(&self)
                    i = escape(scalars, at: i)
                case 0x0A:
                    printable.append(" ")
                    i += 1
                case 0x00..<0x20, 0x7F:
                    i += 1 // \r and other controls draw nothing
                default:
                    printable.append(scalar)
                    i += 1
                }
            }
            flush(&self)
        }

        /// Handles the escape sequence at `start`; returns the index after it.
        mutating func escape(_ s: [Unicode.Scalar], at start: Int) -> Int {
            var i = start + 1
            guard i < s.count else { return i }
            switch s[i] {
            case "[":
                i += 1
                var params = ""
                while i < s.count, (0x30...0x3F).contains(s[i].value) {
                    params.unicodeScalars.append(s[i])
                    i += 1
                }
                while i < s.count, (0x20...0x2F).contains(s[i].value) { i += 1 } // intermediates
                guard i < s.count else { return i }
                let final = s[i]
                i += 1
                csi(params, final)
            case "]", "P", "_", "^", "X":
                // OSC (hyperlinks) and other strings: up to BEL or ST.
                i += 1
                while i < s.count {
                    if s[i].value == 0x07 { return i + 1 }
                    if s[i].value == 0x1B, i + 1 < s.count, s[i + 1] == "\\" { return i + 2 }
                    i += 1
                }
            default:
                i += 1
            }
            return i
        }

        mutating func csi(_ params: String, _ final: Unicode.Scalar) {
            let count = max(1, Int(params) ?? 1)
            switch final {
            case "m":
                sgr(params)
                erased = 0
            case "C":
                let stepped = min(count, erased)
                erased = 0
                blanks(count - stepped, style: .plain)
            case "X":
                erased = 0
                blanks(count, style: style)
                erased = count
            default:
                erased = 0
            }
        }

        mutating func put(_ string: String) {
            erased = 0
            for character in string {
                let width = TerminalCells.width(of: character)
                text.append(character)
                mark(width, style: style)
            }
        }

        mutating func blanks(_ count: Int, style: TerminalStyle) {
            guard count > 0 else { return }
            text.append(String(repeating: " ", count: count))
            mark(count, style: style)
        }

        /// The next `width` cells are in `style`.
        mutating func mark(_ width: Int, style: TerminalStyle) {
            defer { column += width }
            guard !style.isPlain, width > 0 else { return }
            if let last = runs.last, last.end == column, last.style == style {
                runs[runs.count - 1].length += width
            } else {
                runs.append(StyleRun(column: column, length: width, style: style))
            }
        }

        mutating func sgr(_ params: String) {
            // Each `;` parameter, split into its `:` sub-parameters (empty = 0, as in `38:2::r:g:b`).
            let groups = params.split(separator: ";", omittingEmptySubsequences: false).map {
                $0.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            }
            var i = 0
            while i < groups.count {
                let group = groups[i]
                let code = group.first ?? 0
                i += 1
                switch code {
                case 0: style = .plain
                case 1: style.attributes.insert(.bold)
                case 2: style.attributes.insert(.faint)
                case 3: style.attributes.insert(.italic)
                case 4:
                    if group.count > 1, group[1] == 0 { style.attributes.remove(.underline) }
                    else { style.attributes.insert(.underline) }
                case 7: style.attributes.insert(.inverse)
                case 8: style.attributes.insert(.invisible)
                case 9: style.attributes.insert(.strikethrough)
                case 21: style.attributes.insert(.underline)
                case 22: style.attributes.subtract([.bold, .faint])
                case 23: style.attributes.remove(.italic)
                case 24: style.attributes.remove(.underline)
                case 27: style.attributes.remove(.inverse)
                case 28: style.attributes.remove(.invisible)
                case 29: style.attributes.remove(.strikethrough)
                case 30...37: style.foreground = .palette(UInt8(code - 30))
                case 39: style.foreground = nil
                case 40...47: style.background = .palette(UInt8(code - 40))
                case 49: style.background = nil
                case 90...97: style.foreground = .palette(UInt8(code - 90 + 8))
                case 100...107: style.background = .palette(UInt8(code - 100 + 8))
                case 38, 48, 58:
                    let color: TerminalColor?
                    if group.count > 1 {
                        color = Self.extendedColor(Array(group.dropFirst()))
                    } else {
                        // `38;5;N` / `38;2;R;G;B`: the arguments are the following parameters.
                        let kind = i < groups.count ? groups[i].first ?? 0 : 0
                        let argc = kind == 5 ? 1 : kind == 2 ? 3 : 0
                        let args = groups[min(i, groups.count)..<min(i + 1 + argc, groups.count)].map { $0.first ?? 0 }
                        i = min(i + 1 + argc, groups.count)
                        color = Self.extendedColor(args)
                    }
                    if code == 38 { style.foreground = color } else if code == 48 { style.background = color }
                default: break // blink, overline, underline colour (58/59), fonts: not drawn
                }
            }
        }

        /// `5, N` or `2, R, G, B` (also `2, colourspace, R, G, B` from the `:` form).
        static func extendedColor(_ args: [Int]) -> TerminalColor? {
            guard let kind = args.first else { return nil }
            func byte(_ value: Int) -> UInt8 { UInt8(clamping: value) }
            switch kind {
            case 5 where args.count >= 2: return .palette(byte(args[1]))
            case 2 where args.count >= 5: return .rgb(byte(args[2]), byte(args[3]), byte(args[4]))
            case 2 where args.count >= 4: return .rgb(byte(args[1]), byte(args[2]), byte(args[3]))
            default: return nil
            }
        }
    }
}

/// The phone's colours for `TerminalColor`s: its own ANSI 0–15, made for its dark terminal screen (the Mac's theme is
/// not sent), the xterm 6×6×6 cube for 16–231 and the grey ramp for 232–255; RGB colours as they are.
public enum TerminalPalette {
    public struct RGB: Hashable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// ANSI 0–7 and their bright forms 8–15, readable on a near-black background (also black and dark grey, which
    /// programs use as text colour too).
    public static let ansi: [RGB] = [
        RGB(0x4A, 0x4A, 0x4A), RGB(0xEF, 0x5F, 0x58), RGB(0x6B, 0xC4, 0x6D), RGB(0xD9, 0xB5, 0x4A),
        RGB(0x5A, 0x9C, 0xF5), RGB(0xC6, 0x78, 0xDD), RGB(0x4F, 0xC1, 0xD9), RGB(0xD0, 0xD0, 0xD0),
        RGB(0x80, 0x80, 0x80), RGB(0xFF, 0x7B, 0x72), RGB(0x8E, 0xE5, 0x9A), RGB(0xF2, 0xD3, 0x6B),
        RGB(0x82, 0xB6, 0xFF), RGB(0xE0, 0x9C, 0xF0), RGB(0x7F, 0xDD, 0xEE), RGB(0xFF, 0xFF, 0xFF),
    ]

    public static func rgb(_ color: TerminalColor) -> RGB {
        switch color {
        case .rgb(let r, let g, let b): return RGB(r, g, b)
        case .palette(let index):
            switch index {
            case 0..<16: return ansi[Int(index)]
            case 16..<232:
                let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
                let i = Int(index) - 16
                return RGB(levels[i / 36], levels[i / 6 % 6], levels[i % 6])
            default:
                let grey = UInt8(8 + 10 * (Int(index) - 232))
                return RGB(grey, grey, grey)
            }
        }
    }
}
