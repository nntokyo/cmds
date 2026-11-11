# Voice assistant

> Ask cmds by voice what your agents are doing, and answer them: "Jarvis, status", "ジャービス、apiは何してる？",
> "Jarvis, approve api". macOS 26 and later; in beta and free for now (#243).

The assistant listens on this Mac for its name, answers about your workspaces aloud and in a floating HUD, and can
type a reply or pick an agent's option for you after you confirm. It is off until you turn it on.

## Turning it on

- **Settings › Assistant › Turn on the assistant**, or **Assistant** in the menu bar item's menu. cmds remembers the
  choice. The first time, macOS asks whether cmds may use the microphone and speech recognition; and it may download
  the recognition model for your language once.
- **Pause Listening** in the menu bar item's menu turns the microphone off until you choose Resume Listening (or
  restart cmds). While the assistant is on, the menu bar icon has a small cyan dot: pulsing while it listens, hollow
  while paused.
- On macOS 14 and 15 the assistant and its settings do not appear.
- It is in beta and free for now; it will later be part of a cmds subscription
  ([#244](https://github.com/nntokyo/cmds/issues/244)).

## Talking to it

Start with its name: **ジャービス** or **Jarvis** (Settings › Assistant › Name: your own names, comma separated). For a
few seconds after it has spoken you can go on without the name. The shortcut (default **⌥⌘J**, Settings › Assistant ›
Shortcut) makes it listen for one command without the name, also while paused.

It understands the app's language (cmds › Language): Japanese or English.

| Say | It does |
|---|---|
| "status" / 「状況は？」 | Which workspaces need you, what they ask, which are working |
| "what is api doing" / 「apiは何してる？」 | A short summary of that workspace's agent, from its state and screen |
| "summarize api in detail" / 「apiを詳しく要約して」 | A longer summary by Claude Code (`claude -p`, see below) |
| "reply to api: run the tests" / 「apiに『テストを実行して』と返信」 | Offers to type the text into the agent's pane and press Return |
| "approve api" / 「apiを承認して」 | Offers to pick option 1 of the agent's question |
| "choose 2 for api" / 「apiで2番を選んで」 | Offers to pick that option |
| "start Claude in web" / 「webでクロードを起動して」 | Offers a new workspace in that workspace's folder (or a folder path) running `claude` / `codex` |
| "pause listening" / 「一時停止」 | Pauses the microphone |
| "turn off" / 「おやすみ」 | Turns the assistant off |
| anything else | A question for Apple's on-device model (needs Apple Intelligence) |

Without a workspace name, "approve" and "choose" go to the one workspace that waits for you. When a name fits
several workspaces, or a workspace has several panes that could be meant, it asks back instead of guessing; answer
with the workspace's name.

## Confirming

Voice alone only ever answers. Anything that types into a pane or starts a session shows a card in the HUD with the
workspace, the pane and the exact text, and runs only when you confirm:

- Say **yes / はい**, press **Return**, or click the button. **No / いいえ**, **Esc** or Cancel drops it; so does
  saying nothing for a minute.
- Text that may delete, push, publish or deploy (`rm`, `git push`, `deploy`, 本番…), widen permissions
  (`--dangerously-skip-permissions`, "don't ask again"), or goes to an SSH pane needs **Return or a click**: a spoken
  yes is not enough. Approving an agent's question about such a command counts too.
- While a card shows, Return and Esc go to the assistant, not to the terminal.

## The HUD

A floating panel at the top right that never takes the keyboard. **JARVIS** style (default): an animated orb whose
rings and colour follow the state (standing by, listening, thinking, speaking, waiting for your OK; orange when a
workspace needs you), the microphone level, what it heard, the answer, and a ring per workspace with an agent.
**Quiet** style: the text and the card only. With Reduce Motion the orb does not move. The HUD hides a few seconds
after the assistant is done.

Settings › Assistant also chooses the voice and its rate, or **Show answers without speaking**.

## Privacy and cost

- Speech is recognised on this Mac (SpeechAnalyzer). What is not addressed to the assistant is dropped at once; no
  audio and no transcript is stored.
- Answers come from the workspaces' state and Apple's on-device model. Nothing is sent to a server, except a detailed
  summary you ask for: that runs `claude -p` (your Claude Code login) in an empty temporary folder, with the
  screen's text as input, a read-only prompt, the tools that run or change things denied, no permission-skipping
  flag, and a 90-second limit.
- No paid API is used.

## Not yet

Announcing on its own when an agent needs you is planned (opt-in, phase 2). Auto-pausing during calls is not done.
