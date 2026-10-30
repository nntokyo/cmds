#!/bin/bash
# Throwaway sshd on 127.0.0.1 for testing remote access via SSH (docs/internals/sync-protocol.md "Remote access via SSH").
# Runs as the current user, no root, nothing outside <dir>; never touches ~/.ssh.
#
#   test-relay-sshd.sh start <dir> <port>   # keys, configs, sshd in the background (pid in <dir>/sshd.pid)
#   test-relay-sshd.sh stop <dir>
#
# <dir>/ssh_config has Host "cmds-test-relay" (Mac side: CMDS_SYNC_REMOTE_SSH_CONFIG=<dir>/ssh_config),
# <dir>/host_ed25519.pub is the host key to pin, <dir>/authorized_keys takes the phone key.
set -euo pipefail

cmd=${1:?start|stop}
dir=${2:?directory}

case "$cmd" in
start)
    port=${3:?port}
    mkdir -p "$dir"
    chmod 700 "$dir"
    [ -f "$dir/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C cmds-test-host -f "$dir/host_ed25519"
    [ -f "$dir/other_host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C cmds-test-other -f "$dir/other_host_ed25519"
    [ -f "$dir/mac_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C cmds-test-mac -f "$dir/mac_ed25519"
    [ -f "$dir/authorized_keys" ] || cp "$dir/mac_ed25519.pub" "$dir/authorized_keys"
    chmod 600 "$dir/authorized_keys"
    cat > "$dir/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $dir/host_ed25519
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PidFile $dir/sshd.pid
AllowTcpForwarding yes
GatewayPorts no
LogLevel VERBOSE
EOF
    echo "[127.0.0.1]:$port $(cut -d' ' -f1,2 "$dir/host_ed25519.pub")" > "$dir/known_hosts"
    cat > "$dir/ssh_config" <<EOF
Host cmds-test-relay
    HostName 127.0.0.1
    Port $port
    User $(id -un)
    IdentityFile $dir/mac_ed25519
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile $dir/known_hosts
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking yes
EOF
    /usr/sbin/sshd -t -f "$dir/sshd_config"
    /usr/sbin/sshd -D -e -f "$dir/sshd_config" >> "$dir/sshd.log" 2>&1 &
    echo $! > "$dir/sshd.pid"
    sleep 0.5
    kill -0 "$(cat "$dir/sshd.pid")"
    echo "sshd pid $(cat "$dir/sshd.pid") on 127.0.0.1:$port"
    ;;
stop)
    if [ -f "$dir/sshd.pid" ]; then kill "$(cat "$dir/sshd.pid")" 2>/dev/null || true; rm -f "$dir/sshd.pid"; fi
    ;;
*)
    echo "usage: $0 start <dir> <port> | stop <dir>" >&2
    exit 2
    ;;
esac
