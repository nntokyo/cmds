import Foundation

/// Paths typed into a terminal (files dropped on a terminal pane, pasted file URLs): one word each in sh, bash, zsh
/// and fish.
public enum ShellQuoting {
    /// Characters a shell would treat specially; each gets a backslash.
    private static let special = Set(" \\()[]{}<>\"'`!#$&;|*?~^%")

    /// `My File (1).txt` → `My\ File\ \(1\).txt`. A path with a control character (a newline in a file name) is put
    /// in single quotes instead, where a backslash before a newline would join lines.
    public static func quote(_ path: String) -> String {
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var out = ""
        out.reserveCapacity(path.count)
        for character in path {
            if special.contains(character) || character == "\t" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// The paths quoted and separated by spaces.
    public static func quote(_ paths: [String]) -> String { paths.map(quote).joined(separator: " ") }
}
