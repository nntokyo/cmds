import Foundation

/// `cmds-remote.sh`: a dependency-free POSIX sh client for the API socket an SSH pane forwards to the server
/// (docs/internals/ssh.md). The app installs it into `~/.local/bin` on the server only when the user asks ("Install Remote
/// Helper…"); `cmds remote-helper` prints it for a manual install.
public enum RemoteHelperScript {
    public static let fileName = "cmds-remote.sh"

    /// One line typed into the remote shell: writes `~/.local/bin/cmds-remote.sh` (and a `cmds` link when the
    /// server has no `cmds`). Runs under `sh -c` so it works whatever the login shell is (fish, tcsh…); the script
    /// travels base64-encoded as `$0`. Starts with a space (kept out of history where `ignorespace` is set).
    public static func installCommand() -> String {
        let payload = Data(source.utf8).base64EncodedString()
        let script = [
            #"d="$HOME/.local/bin""#,
            #"mkdir -p "$d""#,
            #"printf %s "$0" | base64 -d > "$d/cmds-remote.sh.tmp""#,
            #"chmod 755 "$d/cmds-remote.sh.tmp""#,
            #"mv -f "$d/cmds-remote.sh.tmp" "$d/cmds-remote.sh""#,
            #"if command -v cmds >/dev/null 2>&1; then :; else ln -sf cmds-remote.sh "$d/cmds"; fi"#,
            #"echo "cmds: installed $d/cmds-remote.sh""#,
            #"case ":$PATH:" in *":$d:"*) ;; *) echo "cmds: add $d to PATH" ;; esac"#,
        ].joined(separator: "; ")
        return " sh -c '\(script)' \(payload)"
    }

    public static let source = ##"""
#!/bin/sh
# cmds-remote.sh - talk to the cmds app on your Mac from a server you reached
# through a cmds SSH pane. Uses the Unix socket the pane forwards over SSH
# ($CMDS_SOCKET_PATH); the app only lets it reach its own pane.
# Transport: python3, else socat, else nc -U (first one found).
# Exit codes: 0 ok, 1 request failed, 2 usage, 3 app not reachable.
# Part of cmds (GPL-3.0). Safe to delete; nothing else is installed.

CMDS_REMOTE_VERSION=1
timeout=5

usage() {
    cat >&2 <<'EOF'
usage: cmds-remote.sh <command> [args]
  notify [--title T] <text...|->   light the pane's ring + sidebar text
  status <text...>                 set the sidebar text ("" clears)
  hook claude                      Claude Code hook (JSON on stdin)
  hook claude-status               Claude Code status-line reporter (JSON on stdin)
  prompt                           report $PWD and git branch (for PROMPT_COMMAND)
  ls | panes                       this pane's workspace (JSON)
  send [--enter] <text...|->       type into this pane
  read [--scrollback N]            print this pane's screen / scrollback
  ping | identify | version
  rpc <method> [json-params]       raw call (only this pane's methods are allowed)
EOF
    exit 2
}

have() { command -v "$1" >/dev/null 2>&1; }

transport() {
    if [ -n "$CMDS_TRANSPORT" ]; then echo "$CMDS_TRANSPORT"
    elif have python3; then echo python3
    elif have socat; then echo socat
    elif have nc; then echo nc
    else echo none; fi
}

# JSON string literal of $1.
json_str() {
    printf '%s\n' "$1" | awk 'BEGIN { ORS = ""; printf "\"" }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
          gsub(/[\001-\010\013\014\016-\037]/, ""); if (NR > 1) printf "\\n"; printf "%s", $0 }
        END { printf "\"" }'
}

# Sends one request line ($1) and prints the response line.
send_line() {
    if [ -z "$CMDS_SOCKET_PATH" ] || [ ! -S "$CMDS_SOCKET_PATH" ]; then
        echo "cmds-remote: not inside a cmds SSH pane (no forwarded socket)" >&2
        return 3
    fi
    case "$(transport)" in
    python3)
        printf '%s\n' "$1" | python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(float(sys.argv[2]))
s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read())
s.shutdown(socket.SHUT_WR)
b = b""
while not b.endswith(b"\n"):
    d = s.recv(65536)
    if not d:
        break
    b += d
sys.stdout.buffer.write(b)
' "$CMDS_SOCKET_PATH" "$timeout" 2>/dev/null ;;
    socat)
        printf '%s\n' "$1" | socat -t "$timeout" - "UNIX-CONNECT:$CMDS_SOCKET_PATH" 2>/dev/null ;;
    nc)
        # OpenBSD nc (Debian's netcat-openbsd) keeps the socket open after EOF unless -N; macOS nc closes it.
        if nc -h 2>&1 | grep -q 'Shutdown the network socket after EOF'; then
            printf '%s\n' "$1" | nc -N -U "$CMDS_SOCKET_PATH" 2>/dev/null
        else
            printf '%s\n' "$1" | nc -w "$timeout" -U "$CMDS_SOCKET_PATH" 2>/dev/null
        fi ;;
    *)
        echo "cmds-remote: needs python3, socat or nc (with -U) on this server" >&2
        return 3 ;;
    esac || return 3
}

# Prints the value of "result" from a response line, or the error message on stderr (exit 1).
call() { # method [params-json]
    req="{\"id\":1,\"method\":\"$1\""
    if [ -n "$2" ]; then req="$req,\"params\":$2"; fi
    resp=$(send_line "$req}") || return 3
    [ -n "$resp" ] || { echo "cmds-remote: no reply from the app" >&2; return 3; }
    case "$resp" in
    *'"error":{'*)
        msg=$(printf '%s' "$resp" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
        echo "cmds-remote: ${msg:-request failed}" >&2
        return 1 ;;
    esac
    printf '%s\n' "$resp"
}

# Prints a JSON string field of the response's result (decoded), e.g. "text".
result_string() { # key
    if have python3; then
        python3 -c 'import json, sys
v = json.loads(sys.stdin.read()).get("result", {}).get(sys.argv[1], "")
sys.stdout.write(v if v.endswith("\n") else v + "\n")' "$1"
    else
        sed -n "s/.*\"$1\":\"\\(.*\\)\"}.*/\\1/p" | sed 's/\\n/\
/g; s/\\t/	/g; s/\\"/"/g; s/\\\\/\\/g'
    fi
}

print_result() {
    if have python3; then
        python3 -c 'import json, sys; print(json.dumps(json.loads(sys.stdin.read()).get("result"), indent=2, ensure_ascii=False))'
    else
        sed 's/^{"id":1,"result":\(.*\)}$/\1/'
    fi
}

# Reads stdin (hook JSON) as one line; empty if it is not a JSON object.
read_json_stdin() {
    input=$(head -c 1048576 2>/dev/null | tr -d '\r\n')
    trimmed=$(printf '%s' "$input" | sed 's/^[[:space:]]*//')
    case "$trimmed" in
    "{"*) printf '%s' "$trimmed" ;;
    esac
}

# Like call, then pretty-prints the result (exit code of the call is kept).
call_print() {
    out=$(call "$@") || exit $?
    printf '%s\n' "$out" | print_result
}

text_args() { # joins "$@" with spaces; "-" reads stdin
    if [ "$#" -eq 1 ] && [ "$1" = "-" ]; then cat; else printf '%s' "$*"; fi
}

cmd="$1"
[ -n "$cmd" ] || usage
shift

case "$cmd" in
ping)
    call system.ping >/dev/null && echo pong ;;
identify)
    call_print system.identify ;;
version)
    echo "cmds-remote.sh $CMDS_REMOTE_VERSION" ;;
notify)
    title=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --title|-t) [ "$#" -ge 2 ] || usage; title="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
        esac
    done
    [ "$#" -gt 0 ] || usage
    body=$(text_args "$@")
    params="{\"body\":$(json_str "$body")"
    [ -n "$title" ] && params="$params,\"title\":$(json_str "$title")"
    call notify "$params}" >/dev/null ;;
status)
    [ "$#" -gt 0 ] || usage
    call sidebar.set_status "{\"text\":$(json_str "$*")}" >/dev/null ;;
hook)
    # Hooks never fail and never print: Claude Code must not be disturbed.
    [ -n "$CMDS_SOCKET_PATH" ] && [ -S "$CMDS_SOCKET_PATH" ] || { cat >/dev/null 2>&1; exit 0; }
    case "$1" in
    claude) method=agent.claude_hook ;;
    claude-status) method=agent.claude_status ;;
    *) cat >/dev/null 2>&1; exit 0 ;;
    esac
    json=$(read_json_stdin)
    [ -n "$json" ] || exit 0
    timeout=2
    call "$method" "{\"input\":$json}" >/dev/null 2>&1
    exit 0 ;;
prompt)
    [ -n "$CMDS_SOCKET_PATH" ] && [ -S "$CMDS_SOCKET_PATH" ] || exit 0
    branch=""
    if have git; then branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null); fi
    params="{\"cwd\":$(json_str "$PWD")"
    [ -n "$branch" ] && params="$params,\"branch\":$(json_str "$branch")"
    timeout=2
    call remote.location "$params}" >/dev/null 2>&1
    exit 0 ;;
ls)
    call_print workspace.list ;;
panes)
    call_print pane.list ;;
send)
    enter=""
    if [ "$1" = "--enter" ] || [ "$1" = "-e" ]; then enter=1; shift; fi
    [ "$#" -gt 0 ] || usage
    text=$(text_args "$@")
    [ -n "$enter" ] && text="$text
"
    call pane.send_text "{\"text\":$(json_str "$text")}" >/dev/null ;;
read)
    params=""
    if [ "$1" = "--scrollback" ] || [ "$1" = "-n" ]; then
        case "$2" in ''|*[!0-9]*) usage ;; esac
        params="{\"scrollback\":$2}"
    fi
    out=$(call pane.read_text "$params") || exit $?
    printf '%s\n' "$out" | result_string text ;;
open)
    echo "cmds-remote: open is not available over SSH: the file is on this server, not on the Mac (copy it to the Mac and run cmds open there)" >&2
    exit 1 ;;
rpc)
    [ "$#" -ge 1 ] || usage
    params="$2"
    [ "$params" = "-" ] && params=$(cat)
    call_print "$1" "$params" ;;
-h|--help|help)
    usage ;;
*)
    echo "cmds-remote: unknown command: $cmd" >&2
    usage ;;
esac
"""##
}
