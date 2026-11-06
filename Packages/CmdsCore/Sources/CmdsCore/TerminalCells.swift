import Foundation

/// How many terminal cells a character takes: 2 for wide characters (CJK, Hangul, full-width forms, most emoji), else 1.
/// The Mac sends a row as its text without the spacer cells after wide characters, so the phone lays the text out on
/// the cell grid with this (#115); agent prompt detection counts columns with it too.
public enum TerminalCells {
    public static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1FAFF,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// Cells the whole text takes.
    public static func width(of text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }
}
