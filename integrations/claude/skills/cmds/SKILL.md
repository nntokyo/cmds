---
name: cmds
description: cmds（ネイティブ macOS のターミナルワークスペースアプリ）の中で作業しているときに、ペイン分割・アプリ内ブラウザ・ファイルのプレビュー・サイドバー表示・通知を `cmds` CLI で使う手順（Claude Code・Codex 共通）。環境変数 CMDS_PANE_ID が設定されているとき（cmds のターミナル内）に、開発サーバーを動かす、Web ページを開く・確認・撮影する（Chrome ではなく cmds のブラウザペインを使う）、生成した画像・レポート・差分をユーザーに見せる、長い作業の状況を表示する、別ペインの出力を読むときに使う。CMDS_PANE_ID がなければ使わない。
---

# cmds の中での作業

cmds のターミナルでは `cmds` CLI が PATH にあり、`CMDS_PANE_ID` / `CMDS_WORKSPACE_ID` が自分のペインを指す。
まず `[ -n "$CMDS_PANE_ID" ] && cmds ping` で使えるか確かめる。失敗したらこのスキルは使わない。

## 守ること

- **入力を送るのは、自分がこのセッションで作ったペインだけ。** ユーザーや他のエージェントのペインに `cmds send` しない。
  ペイン ID はアプリの再起動で振り直されるので決め打ちしない。`cmds split` / `cmds browser open` / `cmds open` が返した ID を使う。
- 自分が作っていないペイン・ワークスペースを閉じない。`cmds read` で他のペインを読むのは、ユーザーに頼まれたときだけ。
- ペインを開くときは `--no-focus` を付ける。付けないと、ユーザーが打っているキーボードの入力先が移ってしまう。
- 終わったら、自分が起動したサーバーやウォッチャーを止め（`cmds send --pane <id> $'\x03'`）、ペインを閉じる（`cmds close-pane <id>`）。
- **スケジュール（`cmds schedule add`）は、ユーザーに頼まれたときだけ作る。** 後で実行したほうがよい作業（上限のリセット後に続ける、夜間に回す）に気づいたら、
  コマンド例を示して提案するところまでにする。作ったスケジュールは確認なしで実行され、ウインドウには「CLI から作成」と表示される。

## Web ページは cmds のブラウザペインで開く

cmds の中では、Web ページを開く・確認するときに Chrome（Claude in Chrome、Codex のブラウザ機能、`open <URL>`）を使わず、
`cmds browser` でブラウザペインを開く。ページがターミナルの隣に出て、ユーザーがエージェントの見ている画面をその場で確かめられる。
cmds の MCP サーバー（`cmds mcp`。ツール名 `browser_open` / `browser_eval` / `browser_snapshot` / `open_file` / `close_pane` など）が
使えるなら、同じことをそのツールで行う（スクリーンショットが画像で直接返る）。`close_pane` は、自分のターミナルから開いたペイン
（CLI の `cmds browser open` / `cmds open` で開いたもの、MCP サーバーの再起動前に開いたものも含む）を閉じられる。
`close_pane` が断ったペインは自分のターミナルから開いたものではないので、ユーザーに頼まれたときだけ `cmds close-pane <id>` で閉じる。以下は CLI での手順。

- 開く: `B=$(cmds browser open --no-focus <URL>)`。同じペインで別のページへは `cmds browser navigate --pane "$B" <URL>`。
- 見る: `cmds browser snapshot --pane "$B" -o /tmp/cmds-page.png`（Read ツールで見る）、`cmds browser url --pane "$B"`。
- 読む・操作する: `cmds browser eval --pane "$B" '<JavaScript>'`（結果は JSON で出る）。例:
  `'document.body.innerText.slice(0, 2000)'`、`'document.querySelector("button[type=submit]").click()'`、
  入力欄は値を設定してから `input` イベントを送る（`el.value = "x"; el.dispatchEvent(new Event("input", {bubbles: true}))`）。
- 使い終わったら自分が開いたブラウザペインを閉じる（`cmds close-pane "$B"`）。

Chrome を使うのは次のときだけ:
- ユーザーが Chrome を指定したとき。
- ユーザーの Chrome のログイン状態・保存済みパスワード・拡張機能が要るページ（ChatGPT、管理画面など）。cmds のブラウザペインは Chrome とログイン状態を共有しない。
- `cmds browser eval` では足りない操作（ファイルのアップロード、ネイティブのダイアログなど）。

## よく使う手順

開発サーバーを下のペインで動かし、ログを読む:

```sh
P=$(cmds split down --no-focus -- npm run dev)    # 新しいペインの ID が出力される
sleep 5; cmds read --pane "$P" --scrollback 100    # 起動ログを確認
```

Web 画面を開いて確認する（スクリーンショットは Read ツールで見る）:

```sh
B=$(cmds browser open --no-focus http://localhost:3000)
cmds browser snapshot --pane "$B" -o /tmp/cmds-page.png
cmds browser eval --pane "$B" 'document.title'
cmds browser eval --pane "$B" 'await fetch("/api/health").then(r => r.status)'
cmds browser navigate --pane "$B" http://localhost:3000/settings
```

作ったファイル（画像・PDF・Markdown のレポート・差分）をユーザーに見せる（右にプレビューペインが開き、ファイルが変わると自動で再読み込みされる）:

```sh
V=$(cmds open --no-focus out/chart.png)            # 画像・PDF・動画・Office・テキストを表示
cmds open --pane "$V" REPORT.md                    # 同じプレビューペインで別のファイルを表示（Markdown は整形される）
git diff | cmds open --no-focus --diff -           # 差分を色付きで表示（.diff / .patch はそのまま開ける）
```

- `cmds open` はこの Mac 上のファイルだけ開ける。SSH ペイン（サーバー上）からは使えない。
- 見せ終わったら、自分が開いたプレビューペインを閉じる（`cmds close-pane "$V"`）。
- 出力先のフォルダを一覧で見せるときは `F=$(cmds files --no-focus out)`（ファイル一覧ペイン。ファイルを渡すとそのフォルダで選択した状態になる）。見せ終わったら `cmds close-pane "$F"`。

長い作業の状況をサイドバーに出す（リングは光らない）:

```sh
cmds status "テスト実行中 (3/10)"
cmds status ""                                     # 消す
```

- 入力待ち・完了の通知は Claude Code のフック（`cmds hook claude`）、Codex の OSC 9 通知で自動で出る。自分で `cmds notify` を使うのは、
  途中でユーザーの判断が要る出来事（長いビルドの失敗など）があるときだけにする。
- ユーザーに頼まれて、上限のリセット後にこのセッションを続けるとき: `cmds schedule add --name "上限後に続ける" --after-limit <アカウント> --continue`
  （Codex は `--after-codex-limit --continue`。リセットのたびに続けるなら `--repeat`。既存のペインに後で入力するなら
  `--send TEXT --to shell|agent`。`cmds schedule` で一覧、`cmds schedule history` で結果）。
- 状態を機械的に読むときは `--json` を付ける（例: `cmds ls --json`、`cmds stats --json`）。
- 詳しい使い方: `cmds --help`、`cmds <command> --help`。
