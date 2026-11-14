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
few seconds after it has finished speaking you can go on without the name, with a short follow-up ("what about
api?", 「大阪は？」); a yes or no answers a card. The shortcut (default **⌥⌘J**, Settings › Assistant › Shortcut) makes it
listen for one command without the name, also while paused. Each request stands on its own: only the answer to its
own question ("Which one?") or to a card goes with the one before.

It takes what you said as finished about a second after you stop speaking, so pause no longer than that in the middle
of a request. It goes by how much louder you are than the room, so this works in a café or on a platform too; when the
noise is about as loud as your voice (or is people talking right next to you) it waits for speech recognition to
decide, which takes longer.

## Loud places

- **Settings › Assistant › Listening**: **Automatic** (the default), **Automatic with noise reduction** (macOS's voice
  processing on the microphone: it suppresses the noise around you and the assistant's own voice; other apps' sound is
  not turned down), or **Push to talk**: it hears only while you hold the shortcut (⌥⌘J by default), without its name,
  and letting go ends what you said at once. Push to talk is the most reliable in very loud places; it also uses noise
  reduction.
- **Settings › Assistant › Microphone**: **Automatic** uses a headset such as AirPods when one is connected (close to
  your mouth, it hears much less of the room), else the system's input; or **System Default**, or one microphone. When
  you connect or remove one while the assistant listens, it switches without being turned off.
- In a loud room it is stricter about its name: a name speech recognition is unsure of is ignored, so a passer-by's
  word that merely sounds like it does not wake it (say the name clearly, or use the shortcut). It still has to come
  first. Cards still wait for your yes, as always.

## Siri and Shortcuts

Two actions in the Shortcuts app (macOS 26): **Agent Status** returns and says the same short status the assistant
gives; **Ask the Assistant** hands it a request as if you said it with its name (it must be on and listening) and
returns its answer. Anything it would do still waits for your yes on the Mac. Siri knows them as "cmds status" /
「cmdsの状況」 and "Ask cmds" / 「cmdsに頼む」. Instead of "cmds" you can say "Commands" / 「コマンズ」 or 「シーエムディーエス」 (spoken names given to Siri; not yet
tried with Siri itself). For a morning or evening summary, make a personal automation in Shortcuts
(time of day → Agent Status → Speak Text or Show Notification).

## Calls

While another app uses the microphone (a call in Zoom, FaceTime, Teams or Meet in a browser, a recording, dictation in
another app) the assistant stops listening by itself, without a word, and listens again about 2 seconds after that
ends. The menu bar says which app it paused for. Its reports on tasks you gave wait until then. **Resume Listening**
during the call keeps it on until the call ends; a pause of your own stays until you resume, also after a call. Turn
it off in **Settings › Assistant › Pause while another app uses the microphone**.

An app that keeps the microphone open all the time (voice control, a noise filter, OBS) would keep it paused: choose
**Don’t Pause for …** under the reason in the menu bar, and it listens again at once and never pauses for that app
again. A command-line tool that records (sox, ffmpeg) is named and ignored by its file name, so it stays ignored when an
upgrade moves it (Homebrew runs it from a versioned folder). Settings › Assistant lists
those apps under the setting; **Remove** takes one off the list, or all of them.

Two cmds open at once answer only once: a cmds Dev build pauses while the released app's assistant listens, and of
two copies of the same app the one opened later pauses.

Its name interrupts it at any time: while it speaks or works out an answer (also while Claude is searching), "Jarvis,
…" / 「ジャービス、…」 stops it and takes the new request at once; Claude's late answer to the old one is dropped. While it
speaks, and for a second after, nothing else it hears counts, and something that is mostly what it just said (its own
voice picked up by the microphone) is never taken as a command.

Answers are short: only what was asked, in a sentence ("明日の船橋は晴れ、最高20度、最低9度です。"). When an answer is
still long, only its first sentence is spoken; the HUD shows all of it.

It understands the app's language (cmds › Language): Japanese or English.

| Say | It does |
|---|---|
| "status" / 「状況は？」 | How many workspaces wait for you and which, and which are working (「入力待ち2件: api, api-v2。作業中1件: web。」); ask about one workspace for what it asks |
| "what is api doing" / 「apiは何してる？」 | A short summary of that workspace's agent, from its state and screen; without an agent, that none runs and what its shell runs (a program's name, or idle), never a guess from the screen |
| "summarize api in detail" / 「apiを詳しく要約して」 | A longer summary by Claude Code (`claude -p`, see below) |
| "reply to api: run the tests" / 「apiに『テストを実行して』と返信」 | Offers to type the text into the agent's pane and press Return |
| "approve api" / 「apiを承認して」 | Offers to pick option 1 of the agent's question |
| "choose 2 for api" / 「apiで2番を選んで」 | Offers to pick that option |
| "start Claude in web" / 「webでクロードを起動して」 | Offers a new workspace in that workspace's folder, a project folder of that name, or a folder path, running `claude` / `codex` |
| 「cmds のリポジトリで Claude Code を起動して、ログイン画面のテストを書かせて」, "start Claude in api and have it fix the failing tests" | The same, with that task as the new agent's first prompt (shown on the card) |
| 「api で Claude にこのバグを直させて」 | Gives the task to the Claude running in api; if none runs there, offers to start one with it |
| 「Claude Code を立ち上げて、API の進捗を教えて」 | Several requests in one: done one after the other, the next after the card; no to one card skips only that one (「Claudeの起動は取り消しました。」) and the rest goes on |
| "tell api and web to run the tests" / 「apiとwebに『テストを実行して』と伝えて」 | Offers to send the same text to each of them, on one card |
| "approve all" / 「入力待ちのものに全部はいと答えて」 | Offers to pick option 1 in every workspace that asks, on one card |
| "check all sessions" / 「全部のセッションを確認して」, 「入力待ちのセッションを全部見て」 | Goes through every session (or the waiting / working ones) and says what each agent is doing, one line each; 「詳しく」 / "in detail" uses Claude Code |
| "api の Claude にログイン画面のテストを書くよう指示して", "tell the api agent to fix the failing test" | An instruction in your own words: Claude Code works out the target and phrases the message ("ログイン画面のテストを書いてください"), then it is offered like a reply (see below) |
| "pause listening" / 「一時停止」 | Pauses the microphone |
| "turn off" / 「おやすみ」 | Turns the assistant off |
| "what's the weather in Funabashi tomorrow" / 「明日の船橋の天気を教えて」, "search …" / 「…を検索して」 | A web question for Claude Code (`claude -p` with web search only, see below) |
| anything else | A question for Apple's on-device model (needs Apple Intelligence) |

**Instructions in your own words.** The fixed phrases above are tried first. Something else that names a workspace or
speaks of agents, sessions or all of them goes to Claude Code (**Use Claude to understand free commands**, Settings ›
Assistant, on by default), which turns it into an instruction, a check of the sessions or an approval. It gets only
what you said and the workspaces' names, agents and states, never screen text, and no tools. Its result is only a
proposal: the card shows each target pane and the exact message it phrased, and nothing is sent before you confirm.
If it is not a command, it is answered as a question.

**Web questions.** The on-device model has no internet. With **Use Claude for web questions** on (Settings ›
Assistant, on by default), a question goes to Claude Code instead when you ask to search (検索 / 調べて / ググって /
ネットで / インターネット / Claudeに聞いて, search / look up / google / search online / ask Claude) or when it is about
something live (天気 / weather, ニュース / news, 株価 / stock price, 為替 / exchange rate, 運行 / train status, 今日の /
today's, 最新のバージョン / the latest version of…, latest news, "is GitHub down", scores…). "Online" or "latest" alone
are not enough: "what is an online algorithm" or "the latest commit in api" are no web questions. Other questions still go to the on-device model first; when it says the answer needs current
or outside information, Claude is asked after all. The HUD shows "Asking Claude…" meanwhile, and a small "Claude"
under the answer. Claude gets only what you said, today's date, your time zone and locale (never screen text), and
answers in a sentence (asking back only when it cannot tell, such as which place). It takes a few seconds to a minute and uses
your Claude Code usage; when `claude` is missing or fails, the assistant says so. When Claude takes longer than a
moment (a web question, a summary in detail), the assistant first says 「調べます。」 / "Checking.", and a detailed summary
is spoken sentence by sentence as Claude writes it. The same web question again within ten minutes (the same day) is
answered at once from the last answer. Turned off, every question goes to
the on-device model as before.

**Starting agents with work to do.** The place is a workspace (its folder) or a folder of that name up to three levels
inside your project folders (Settings › Assistant › Project folders; by default ~/Source, ~/Developer, ~/Projects and
~/src, those that exist; git repositories first, not searched inside). When several folders fit it names up to three
and asks which; when none does, 「どのフォルダで起動しますか？」. Without a place, it starts where the last request was
about, else in the selected workspace. The agent runs in a new workspace (called `api-2`, `api-3`… when a workspace is already called like its folder, so
"api" still means the first one and "api 2" the new one) as `claude '<task>'` (`codex '<task>'`): the
task is one quoted argument, so nothing in it reaches the shell, and no permission-skipping flag is ever added. A
spoken yes starts it, unless the task mentions deleting, pushing or deploying (then Return or a click).

**Follow-through.** For a session it started with a task, or gave an instruction to, it says in one sentence when the
agent is done (「api の Claude が完了しました」) or asks you something (「api の Claude が確認を求めています: …」), from the
agent state cmds already shows (no screen is read). Settings › Assistant › **Report on tasks I gave** (on by default);
other sessions are never announced.

**Misheard names.** Speech recognition is told to expect the assistant's names, Claude Code, Codex, cmds and your
workspaces' names. 「クロトコート」 or "cloud code" still means Claude Code, and a workspace name heard in katakana or as
other letters (エーピーアイ, or EPA for api) finds the workspace when none is called exactly that; when two sound alike,
it asks which. When Apple's on-device model is asked to do something, it does not answer: the request goes to the
interpreter, else the assistant says how to ask.

Without a workspace name, "approve" and "choose" go to the one workspace that waits for you. When a name fits
several workspaces, or a workspace has several panes that could be meant, it asks back instead of guessing; answer
with the workspace's name.

## Confirming

Voice alone only ever answers. Anything that types into a pane or starts a session shows a card in the HUD with the
workspace, the pane and the exact text, and runs only when you confirm:

- Say **yes / はい**, press **Return**, or click the button. **No / いいえ**, **Esc** or Cancel drops it; so does
  saying nothing for a minute. A short yes or no (はい, いいえ, OK, キャンセル…) counts without the name also while the
  card is still being read out, unless the card itself says that word (a reply "yes" to api): then wait until it has
  been read out.
- Text that may delete, push, publish or deploy (`rm`, `git push`, `deploy`, 本番…), widen permissions
  (`--dangerously-skip-permissions`, "don't ask again"), or goes to an SSH pane needs **Return or a click**: a spoken
  yes is not enough. Approving an agent's question about such a command counts too.
- While a card shows, Return and Esc go to the assistant, not to the terminal.
- A card for several sessions lists each workspace › pane with its text and confirms or cancels them all at once. If
  any one of them needs Return or a click, the whole card does. With "all" or "the waiting ones", a session whose
  pane is unclear, or that asks nothing, is left out and named.

## The HUD

A floating panel at the top right that never takes the keyboard. **JARVIS** style (default): an animated orb whose
rings and colour follow the state (standing by, listening, thinking, speaking, waiting for your OK; orange when a
workspace needs you), the microphone level, what it heard, the answer, and a ring per workspace with an agent.
**Quiet** style: the text and the card only. With Reduce Motion the orb does not move. The HUD hides a few seconds
after the assistant is done.

**While it waits.** While the assistant is on and waits for its name, a small orb stays at the bottom right of the
screen, above the Dock: it breathes slowly while standing by, follows your voice while it hears speech, turns orange
when a workspace needs you, and is dim and hollow while listening is paused. When you speak to it, it grows into the
HUD, and comes back when the HUD goes. It never takes the keyboard, and clicks around it go to the window below. Click
it to see the last answer again; drag it anywhere (cmds remembers where). In the Quiet style it is a plain dot. Turn it
off with Settings › Assistant › **Show while waiting**, or make it larger with **Orb size** (small 56 pt, medium
72 pt).

Settings › Assistant also chooses the voice and its rate, or **Show answers without speaking**.

**Personal Voice.** Your own Personal Voice (made in System Settings › Accessibility › Personal Voice) can speak the
answers: click **Use my Personal Voice…**, allow cmds when macOS asks, and pick it in the Voice list, marked
"(Personal Voice)". Only Personal Voices that speak the app's language are listed; if yours speaks another language
(often English only), Settings says so and answers in this language use the system voice. Settings also says when
cmds was not allowed, when this Mac does not support it, or when you have none yet, with a button to System Settings.
Speech stays on this Mac; cmds never records or copies a voice. The permission belongs to the app, so a Debug build
(cmds Dev) asks again.

## Privacy and cost

- Speech is recognised on this Mac (SpeechAnalyzer). What is not addressed to the assistant is dropped at once; no
  audio and no transcript is stored.
- Answers come from the workspaces' state and Apple's on-device model. Nothing is sent to a server, except a detailed
  summary you ask for, web questions and free instructions: they run `claude -p` (your Claude Code login) in an empty
  temporary folder, without MCP servers or any permission-skipping flag, with a time limit, and without your own
  Claude Code setup (CLAUDE.md, hooks, output style, plugins) or saved sessions; web answers and detailed summaries use
  Sonnet. A detailed summary gets
  the screen's text as input and no tools at all; a web question gets only your words and only the WebSearch and
  WebFetch tools; a free instruction gets your words and the workspaces' names and states, no tools, and the small
  model (Haiku).
- No paid API is used.

## Not yet

Announcing on its own when an agent needs you is planned (opt-in, phase 2). Auto-pausing during calls is not done.
