import Foundation

/// How sure the assistant must be before it acts (#243). Voice alone only ever answers (status, summaries); every
/// action is shown first and needs a yes. A spoken yes is enough only for ordinary actions: text that could destroy,
/// publish or widen permissions, and anything sent to an SSH pane, needs Return or a click.
public enum AssistantSafety {
    public enum Confirmation: String, Equatable, Sendable {
        /// "yes" / "はい", Return or the button.
        case voiceOrKey
        /// Return or the button only.
        case keyOrClick
    }

    /// Why an action needs Return or a click. Raw values are what `debug.assistant` reports.
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// `rm`, `rmdir`, `git clean`, `git reset --hard`, `drop table`, `mkfs`, `dd`, 削除.
        case destructive
        /// `git push`, `npm publish`, releases.
        case publish
        /// Deploys, production.
        case deploy
        /// `--dangerously-skip-permissions`, `--yolo`, "don't ask again", sudo.
        case permissions
        /// The pane is an SSH session (the text runs on a server).
        case sshPane
    }

    private static let checks: [(Reason, Pattern)] = [
        (.destructive, Pattern(#"(^|[^a-z0-9_-])(rm|rmdir|unlink|shred|mkfs|dd)( |$)|git +clean|reset +--hard|checkout +--? +\.|drop +(table|database|schema)|truncate +table|delete +from|--force-with-lease|(^|\s)-rf?( |$)|削除|消して|消去|全部消|初期化|フォーマット"#)),
        (.publish, Pattern(#"git +push|push +--force|push +-f|(npm|pnpm|yarn|cargo|gem|twine) +publish|release|リリース|公開して|プッシュ"#)),
        (.deploy, Pattern(#"deploy|デプロイ|production|本番|prod( |$)|kubectl +(apply|delete)|terraform +(apply|destroy)|wrangler +deploy|firebase +deploy"#)),
        (.permissions, Pattern(#"dangerously|skip-permissions|bypass ?permissions|--yolo|full-auto|sudo( |$)|chmod|chown|don'?t ask again|do not ask again|always allow|allow all|今後(は)?(確認|聞か)|毎回許可|すべて許可|全部許可"#)),
    ]

    /// The reasons `text` (and, for picking an option, the agent's question and the option's label in `context`)
    /// needs more than a spoken yes.
    public static func reasons(text: String, context: [String] = [], sshPane: Bool) -> [Reason] {
        let haystack = ([text] + context).map { $0.precomposedStringWithCompatibilityMapping.lowercased() }.joined(separator: "\n")
        var found = checks.filter { $0.1.occurs(in: haystack) }.map(\.0)
        if sshPane { found.append(.sshPane) }
        return found
    }

    public static func confirmation(for reasons: [Reason]) -> Confirmation {
        reasons.isEmpty ? .voiceOrKey : .keyOrClick
    }
}
