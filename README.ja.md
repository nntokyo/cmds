<p align="center"><img src="design/icon/macos-1024.png" width="128" height="128" alt="cmdsのアプリアイコン"></p>

# cmds

[English](README.md)

cmdsは、AIコーディングエージェントを動かすためのmacOSネイティブのターミナルワークスペースです。ワークスペースは縦に並ぶサイドバーのタブで、
その中をターミナル（[libghostty](https://github.com/ghostty-org/ghostty)で描画）、Webページ、ファイルのライブプレビューのペインに分割できます。
エージェントが入力を待つとペインが光り、サイドバーには各エージェントのコンテキスト、コスト、アカウントの利用上限が表示されます。
`cmds`コマンドを使えば、エージェントやスクリプトからアプリを操作できます。iPhone/iPad用のコンパニオンアプリは、
暗号化した接続でターミナルをミラーします。SwiftとAppKitで書かれています。ライセンスはGPL-3.0です。

> ドキュメント（`docs/`）は英語です。

## 主な機能

- **ワークスペースと分割**：gitブランチ、ディレクトリ、待ち受けポート、CPU、メモリを表示する縦タブ。右・下への入れ子の分割、
  ペインのズーム、コンパクトなサイドバー。
- **注目リング**：OSC 9/777の通知、ベル、`cmds notify`でペインが光ります。⇧⌘Uで最新のペインへ移動。
- **ブラウザペイン**：ターミナルの隣にWebKitのブラウザ。スクリプトから操作できます（`cmds browser eval`、`snapshot`）。
- **プレビューペイン**：画像、PDF、動画、Officeファイル（Quick Look）、整形したMarkdown、色分けした差分を表示し、
  ファイルが変わると再読み込みします。ターミナルのパスを⌘クリックしても開けます。
- **SSHワークスペース**：自分の`ssh`をそのまま使い、制限付きのソケットをサーバーへ転送するので、通知・ステータス・
  エージェントの利用状況がリモートでも使えます。切断時は再接続の表示。
- **コーディングエージェント**：Claude Codeのフックとステータスライン連携、Codexはセッションファイルから利用状況を取得。
  ペインごとのモデル、コンテキスト、コスト、5時間・7日間・利用額の上限。Claude Code用のスキル付き。
- **セッションの復元と再開**：再起動後にレイアウトとディレクトリが戻り、Claude Code／Codexのセッションの再開を提案します。
  書き出し・読み込みで別のインスタンスへ移せます。
- **`cmds` CLIとソケットAPI**：分割、入力、画面の読み取り、通知、ファイル表示、ブラウザ操作、一覧、統計、イベント。JSON出力も可。
- **iPhone/iPadコンパニオン**：QRコードでペアリングし、Mac自身の証明書に固定したTLS 1.3で接続。ローカルネットワーク
  （ピアツーピアWi‑Fiを含む）、Wi‑FiがオフのときはBluetooth LE、外出先ではSSHの中継ホスト経由で接続します。
- **スリープ防止**：cmdsの実行中はアイドルスリープしません。蓋を閉じてもスリープしない設定も選べます。
- 両アプリとも**英語と日本語**に対応。

## 動作環境

- Appleシリコン搭載のMac、macOS 14 Sonoma以降（arm64専用のビルドです）。
- コンパニオンを使う場合はiOS/iPadOS 17以降のiPhone/iPad（任意）。
- ビルドには、Xcode（Swift 5.10のためXcode 15.3以降。開発はXcode 27）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、
  GhosttyKitのビルド用に[Zig](https://ziglang.org) 0.17.0（固定しているGhosttyが要求するバージョン）が必要です。

## ソースからのビルド

```sh
git clone --recurse-submodules https://github.com/nntokyo/cmds.git
cd cmds                                   # 既存のクローンでは: git submodule update --init

# 1. GhosttyサブモジュールからGhosttyKit.xcframeworkを作る
(cd vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native \
  -Demit-macos-app=false -Doptimize=ReleaseFast)
ln -s "$PWD/vendor/ghostty/macos/GhosttyKit.xcframework" vendor/GhosttyKit.xcframework

# 2. Xcodeプロジェクトを生成する（生成物なのでコミットしない）
brew install xcodegen
xcodegen generate

# 3. Macアプリ（スキームCmdsApp）。Xcodeでcmds.xcodeprojを開いてもよい
xcodebuild -scheme CmdsApp -derivedDataPath build/dd build
open build/dd/Build/Products/Debug/cmds.app
```

- iOSコンパニオンは`CmdsCompanion`スキームです。Xcodeから実機で実行してください。
- **署名**：`project.yml`はメンテナーのチーム（`DEVELOPMENT_TEAM: LY354RVYHA`）で署名します。自分のチームに書き換えるか
  （`xcodebuild`に`DEVELOPMENT_TEAM=…`を渡してもよい）、変更後に`xcodegen generate`をもう一度実行してください。
  詳細とリリースビルド：[docs/internals/release.md](docs/internals/release.md)。
- CLIだけをビルドする場合：`swift build --package-path Packages/CmdsCore --product cmds`。ユニットテストは
  `Packages/CmdsCore`で`swift test`（[テスト](docs/internals/testing.md)）。

## インストール

1. `cmds.app`を`/Applications`（または`~/Applications`）にコピーし、そこから開きます。
2. macOSのファイアウォールがオンの場合、受信接続の許可を求められたら**許可**を選びます（iPhoneコンパニオンに必要）。
   通知も許可してください。
3. 任意：**cmds › コマンドラインツールをインストール…**で`/usr/local/bin/cmds`へのリンクを作ると、cmds以外のターミナルでも
   `cmds`が使えます（cmdsのターミナルでは最初から`PATH`にあります）。

詳しくは[docs/guide/getting-started.md](docs/guide/getting-started.md)。

## クイックスタート

- **⌘N**でワークスペースを開き、**⌘D**／**⇧⌘D**で右／下に分割、**⇧⌘B**でブラウザを分割表示、**⇧⌘O**でファイルを
  プレビュー、**⇧⌘N**でSSHでサーバーに接続します。
- cmdsのターミナルから：

  ```sh
  cmds split down -- npm run dev            # 下の新しいペインで開発サーバーを起動
  cmds browser open http://localhost:3000   # 右にブラウザペイン
  git diff | cmds open --diff -             # プレビューペインに色分けした差分
  long-task; cmds notify "done: $?"         # 終わったらこのペインを光らせる
  ```

- コーディングエージェント：Claude Codeのフックとステータスラインを設定し、Codexの通知をオンにします —
  [docs/guide/ai-agents.md](docs/guide/ai-agents.md)。
- iPhone：Macで**cmds › iPhone/iPadとペアリング…**を選び、コンパニオンで**ペアリングコードをスキャン** —
  [docs/guide/iphone.md](docs/guide/iphone.md)。

## キーボードショートカット

| 操作 | キー |
|---|---|
| 新規ワークスペース／新規SSHワークスペース | ⌘N / ⇧⌘N |
| ワークスペース1〜9を選択 | ⌘1 … ⌘9 |
| 次／前のワークスペース | ⇧⌘] / ⇧⌘[、⌃Tab / ⌃⇧Tab |
| ワークスペースの名前を変更 | ⇧⌘R |
| 右／下に分割 | ⌘D / ⇧⌘D |
| 左／右／上／下のペインへ移動 | ⌥⌘← / → / ↑ / ↓ |
| ペインをズーム | ⇧⌘↩ |
| 最新の注目ペインへ移動 | ⇧⌘U |
| ブラウザを分割表示／プレビューで開く | ⇧⌘B / ⇧⌘O |
| アドレスバー／再読み込み（SSHは再接続）／戻る／進む | ⌘L / ⌘R / ⌘[ / ⌘] |
| ペインを閉じる／ワークスペースを閉じる | ⌘W / ⇧⌘W |
| サイドバーの表示切り替え／コンパクト表示 | ⌘B / ⌃⌘S |

すべてのショートカット：[docs/reference/shortcuts.md](docs/reference/shortcuts.md)。

## ドキュメント

| ガイド | リファレンス | 内部構造 |
|---|---|---|
| [はじめに](docs/guide/getting-started.md) | [CLI](docs/reference/cli.md) | [アーキテクチャ](docs/internals/architecture.md) |
| [ワークスペースとペイン](docs/guide/workspaces-and-panes.md) | [ソケットAPI](docs/reference/api.md) | [同期プロトコル](docs/internals/sync-protocol.md) |
| [iPhoneとiPad](docs/guide/iphone.md) | [キーボードショートカット](docs/reference/shortcuts.md) | [SSHペイン](docs/internals/ssh.md) |
| [AIコーディングエージェント](docs/guide/ai-agents.md) | [環境変数](docs/reference/environment.md) | [ローカライズ](docs/internals/localization.md) |
| | | [テスト](docs/internals/testing.md) |
| | | [リリース](docs/internals/release.md) |

目次：[docs/README.md](docs/README.md)。変更履歴：[CHANGELOG.md](CHANGELOG.md)。

## ライセンス

cmdsは[GNU General Public License v3.0](LICENSE)のフリーソフトウェアです。

### サードパーティのソフトウェア

| コンポーネント | 使用箇所 | ライセンス |
|---|---|---|
| [Ghostty](https://github.com/ghostty-org/ghostty)（libghostty、terminfoとシェル統合のリソース。サブモジュール`vendor/ghostty`） | Macアプリ | MIT（[vendor/ghostty/LICENSE](https://github.com/ghostty-org/ghostty/blob/main/LICENSE)）。Ghostty自身の依存関係はGhosttyのリポジトリを参照 |
| [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh)、[SwiftNIO](https://github.com/apple/swift-nio)、[SwiftNIO Transport Services](https://github.com/apple/swift-nio-transport-services)、[Swift Crypto](https://github.com/apple/swift-crypto)と、その依存先のswift-asn1、swift-atomics、swift-collections、swift-system | iOSコンパニオン（`Packages/CmdsSSH`） | Apache-2.0 |

MacアプリとCLIは、libghostty以外にはAppleのフレームワークだけを使っています。
