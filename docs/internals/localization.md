# Localization

> How the apps are translated (English and Japanese), how to add a string, and which text deliberately stays English.

## Catalogs

English is the development language; Japanese (`ja`) is the other localization. Each app has its own String
Catalogs: `App/Resources/Localizable.xcstrings` + `InfoPlist.xcstrings` (Mac) and the same in `iOS/Resources`
(permission texts: local network, Bluetooth, camera). `CFBundleLocalizations` is `[en, ja]` (`project.yml`).

## Choosing the language

- **Mac**: follows the system (System Settings › General › Language & Region, which also has per-app languages).
  The app also has cmds › Language › System / 日本語 / English (`App/Sources/App/AppLanguage.swift`): it sets
  `AppleLanguages` in the app's own defaults domain (System removes it) and offers to relaunch. An isolated instance
  never writes it; launch it with `-AppleLanguages '(ja)'` or `'(en)'`.
- **iOS**: the companion follows the device language; Settings › cmds › Language picks a per-app language. Nothing to
  configure in the app.

## Adding a string

- AppKit takes `String`, so write `String(localized: "Split Right")`; SwiftUI `Text("…")`, `Button("…")`, `Label`,
  `navigationTitle` take `LocalizedStringKey` and need nothing.
- Interpolate instead of concatenating (`String(localized: "Resume All (\(count))")` → key `Resume All (%lld)`;
  String → `%@`, Int → `%lld`); translations reorder with `%1$@`/`%2$lld`. Format numbers to strings first (a
  `Double` becomes `%lf`). Helpers that take `String.LocalizationValue` (`MainMenu.item`) are extracted at their call
  sites.
- Then build and run `scripts/l10n-sync.sh` (or build in Xcode, which syncs the catalogs itself) and add the Japanese
  in Xcode's catalog editor or the JSON. English plurals go in the catalog's plural variations (`%lld processes…`).

```sh
xcodebuild -scheme CmdsApp -derivedDataPath build/dd build
xcodebuild -scheme CmdsCompanion -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd-ios build
scripts/l10n-sync.sh
```

## What stays English

- The socket API, `cmds` CLI output and its error messages (scripts parse them; also what `--json` and the
  [CLI reference](../reference/cli.md) document), sync protocol strings, identifiers, file names, commands and log
  lines.
- Status texts that the UI shows and the API reports (`SyncServer`/`SyncBluetoothPeripheral`/`SyncRemoteAccess`
  status) are a `LocalizedStatus`: `.localized` for the UI, `.english` for `sync.status`.

## CmdsCore text in the UI

`CmdsCore` (shared with the CLI) has no catalogs and stays English. Its `AgentFormat` functions take
`strings: AgentFormat.Strings` (default `.english`, what the CLI and tests use; `CmdsCLITests` pins it); the apps pass
`.localized`, defined in `Shared/Sources/SharedLocalization.swift`, which both app targets compile, so its keys
(`AgentFormat.Text.english` with `%@`/`%lld`) land in both catalogs. The same file has `MemoryPressure.localizedName`
and `DefaultTitle.localized` (the model, API and sync keep "Terminal", "Browser", "Workspace"; the UI shows
`displayTitle`). Errors whose `description` stays English get app-side text: `SSHLaunch.InvalidInput.reason`,
`LidSleepError` (Mac, `CoreErrorText.swift`), `SSHTunnelError` and the Mac's sync error codes (iOS,
`CoreErrorText.swift`). `AgentSession.summary` stays English; the banner builds its own.

## Units and style

- **Units**: compact labels stay as they are in every language (`ctx`, `5h`, `7d`, `527k`, `%`, `$`, GB); sentences
  use Japanese units (`5時間の上限`, `7日間の上限`, `3時間25分`, `3分前`, `/時間`). Only `spend` becomes `利用額`.
- **Japanese style**: Apple's current terms (設定, ウインドウ, しまう, 取り消す/やり直す, すべてを選択), no space
  between Japanese and Latin text (`cmdsを終了`), full-width （）and ：in prose, the same terms on Mac and iPhone
  (ペアリング, 識別情報, 中継ホスト, iPhone/iPad), keyboard shortcuts unchanged, product/protocol names (cmds, SSH,
  Wi‑Fi, Bluetooth, TLS) as is.
- **UI tests** find elements by accessibility identifier, never by visible (localized) text.
