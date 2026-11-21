# Network debug tools and helpers (shell/netdebug.sh). Every row checks the
# helpers offline in bash and, where there is one, zsh; minimal rows run with
# --network none and stop there. Server rows install the full tool list once
# and run all their checks against that install.
# SC2016: the snippets are meant to be expanded by the shell under test.
# shellcheck disable=SC2016
nd=/src/shell/netdebug.sh
cfg=/src/config/mise/config.toml

# nd_run <shell> <snippet>: run the snippet in a fresh shell that has sourced netdebug.sh.
nd_run() { "$1" -c ". $nd; $2"; }
# nd_rc <shell> <snippet>: its exit status, whatever it is.
nd_rc() {
  local rc=0
  nd_run "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# A tty is needed to see colours: netshoot only paints a terminal.
red1="$(printf '\033[1;31m')"
red2="$(printf '\033[31;1m')"

fx="$(mktemp -d)"
mkdir -p "$fx/bin"
kubeconfig() { # <file> <context>
  printf 'apiVersion: v1\nkind: Config\ncurrent-context: %s\ncontexts:\n- context:\n    cluster: c\n    namespace: argocd\n    user: u\n  name: %s\n' "$2" "$2" >"$1"
}
kubeconfig "$fx/dev" homelab
kubeconfig "$fx/prod" gke-prod
# A kubectl that only reports what it was asked to do.
printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' >"$fx/bin/kubectl"
chmod +x "$fx/bin/kubectl"
# What a real session has loaded by the time netshoot runs: the df_kube_* helpers.
cat >"$fx/ns.sh" <<EOF
DF_PROMPT_FUNCTIONS_ONLY=1
. /src/shell/prompt-minimal.sh
. $nd
netshoot "\$@"
EOF

assert_ok "openssl is on this row" -- command -v openssl
assert_ok "timeout is on this row" -- command -v timeout
assert_fail "no kubectl on PATH before the install" -- command -v kubectl

# check_helpers <shell>: everything that needs neither a tool nor the network.
check_helpers() {
  local sh="$1" start out line re f rc

  assert_eq "$("$sh" -c ". $nd" 2>&1)" "" "$sh: sourcing netdebug.sh prints nothing"
  for f in port certinfo netshoot df_ping_group_ok; do
    assert_ok "$sh: $f is defined" -- nd_run "$sh" "type $f"
  done

  # case_port_and_certinfo_offline. 203.0.113.1 (TEST-NET-3) either fails at
  # once (no network) or hangs until the timeout (network): both must be quick.
  start=$(date +%s)
  assert_fail "$sh: port fails offline" -- nd_run "$sh" 'port 203.0.113.1 443 2'
  assert_ok "$sh: port returns within timeout" -- test $(($(date +%s) - start)) -le 3
  assert_eq "$(nd_run "$sh" 'port 203.0.113.1 443 2' 2>&1 || true)" "closed 203.0.113.1:443" "$sh: port says closed"
  assert_eq "$(nd_run "$sh" 'port 127.0.0.1 1' 2>&1 || true)" "closed 127.0.0.1:1" "$sh: refused connection is closed"
  assert_eq "$(nd_rc "$sh" 'port 127.0.0.1 1')" 1 "$sh: closed exits 1"
  assert_eq "$(nd_rc "$sh" 'port')" 2 "$sh: port without arguments is a usage error"
  assert_eq "$(nd_rc "$sh" 'port 127.0.0.1')" 2 "$sh: port without a port is a usage error"
  assert_eq "$(nd_rc "$sh" 'port 127.0.0.1 http')" 2 "$sh: non-numeric port is rejected"
  assert_eq "$(nd_rc "$sh" 'port 127.0.0.1 70000')" 2 "$sh: port above 65535 is rejected"
  assert_eq "$(nd_rc "$sh" 'port 127.0.0.1 0')" 2 "$sh: port 0 is rejected"
  assert_eq "$(nd_rc "$sh" 'port 127.0.0.1 80 soon')" 2 "$sh: bad timeout is rejected"

  assert_fail "$sh: certinfo fails cleanly offline" -- nd_run "$sh" 'certinfo 203.0.113.1'
  assert_eq "$(nd_run "$sh" 'certinfo 203.0.113.1' 2>&1 >/dev/null || true)" "certinfo: cannot connect to 203.0.113.1:443" "$sh: certinfo message"
  assert_eq "$(nd_run "$sh" 'certinfo 203.0.113.1' 2>/dev/null || true)" "" "$sh: certinfo prints nothing on stdout when it fails"
  assert_eq "$(nd_run "$sh" 'certinfo 127.0.0.1:1' 2>&1 >/dev/null || true)" "certinfo: cannot connect to 127.0.0.1:1" "$sh: certinfo keeps the given port"
  assert_eq "$(nd_run "$sh" 'certinfo "[::1]:1"' 2>&1 >/dev/null || true)" "certinfo: cannot connect to ::1:1" "$sh: certinfo takes a bracketed IPv6 literal"
  assert_eq "$(nd_rc "$sh" 'certinfo 127.0.0.1:1')" 1 "$sh: certinfo exits 1 when it cannot connect"
  assert_eq "$(nd_rc "$sh" 'certinfo')" 2 "$sh: certinfo without arguments is a usage error"
  assert_eq "$(nd_rc "$sh" 'certinfo 127.0.0.1:https')" 2 "$sh: certinfo rejects a named port"

  # case_netshoot_without_kubectl: a PATH with no kubectl in it, and no rc file
  # that could add one (the installed ~/.zshenv puts the mise shims on PATH).
  nokube() { PATH=/usr/bin:/bin "$sh" ${nokube_opt[@]+"${nokube_opt[@]}"} -c ". $nd; netshoot"; }
  nokube_opt=()
  if [ "${sh##*/}" = zsh ]; then nokube_opt=(-f); fi
  assert_ok "kubectl is not under /usr/bin or /bin" -- env PATH=/usr/bin:/bin bash -c '! command -v kubectl'
  out="$(nokube 2>&1 >/dev/null || true)"
  assert_eq "$out" "netshoot: kubectl not found" "$sh: netshoot without kubectl says so on stderr"
  assert_eq "$(nokube 2>/dev/null || true)" "" "$sh: netshoot without kubectl prints nothing on stdout"
  rc=0
  nokube >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 1 "$sh: netshoot without kubectl exits 1"

  # case_netshoot_with_kubectl: a stub in front of PATH. Stdout is the stub's
  # report of its arguments, stderr the context line; no tty, so no colours.
  out="$(PATH="$fx/bin:$PATH" KUBECONFIG="$fx/dev" USER=Test_User "$sh" "$fx/ns.sh" foo 2>&1)"
  assert_eq "$(sed -n 1p <<<"$out")" "netshoot: context homelab, namespace foo" "$sh: netshoot prints the context first"
  line="$(sed -n 2p <<<"$out")"
  re='^run netshoot-test-user-[0-9]+ --rm -it --restart=Never -n foo --image=nicolaka/netshoot:v[0-9][0-9.]* -- zsh$'
  [[ $line =~ $re ]] || _fail "$sh: unexpected kubectl call: $line"
  assert_eq "$(sed -n 3p <<<"$out")" "" "$sh: netshoot prints nothing else"
  out="$(PATH="$fx/bin:$PATH" KUBECONFIG="$fx/dev" "$sh" "$fx/ns.sh" 2>&1)"
  assert_ok "$sh: the namespace defaults to default" -- grep -q -- ' -n default ' <<<"$out"
  assert_ok "$sh: no colour without a terminal" -- test -z "$(grep -aF -e "$red1" -e "$red2" <<<"$out" || true)"
  # With a terminal, a prod context is bold red and any other is not.
  out="$(PATH="$fx/bin:$PATH" KUBECONFIG="$fx/prod" script -qec "$sh $fx/ns.sh foo" /dev/null </dev/null 2>&1 | tr -d '\r')"
  assert_ok "$sh: prod context is bold red" -- grep -aqF -e "$red1" -e "$red2" <<<"$out"
  assert_ok "$sh: the prod context is named" -- grep -aqF 'context gke-prod, namespace foo' <<<"$out"
  out="$(PATH="$fx/bin:$PATH" KUBECONFIG="$fx/dev" script -qec "$sh $fx/ns.sh foo" /dev/null </dev/null 2>&1 | tr -d '\r')"
  assert_fail "$sh: non-prod context is not red" -- grep -aqF -e "$red1" -e "$red2" <<<"$out"
  assert_ok "$sh: the context is named" -- grep -aqF 'context homelab, namespace foo' <<<"$out"

  # df_ping_group_ok: the kernel's range file, replaced by fixtures.
  printf '1 0\n' >"$fx/range"
  assert_eq "$(DF_PING_GROUP_RANGE_FILE="$fx/range" nd_rc "$sh" df_ping_group_ok)" 1 "$sh: range '1 0' is closed to everybody"
  printf '0 2147483647\n' >"$fx/range"
  assert_eq "$(DF_PING_GROUP_RANGE_FILE="$fx/range" nd_rc "$sh" df_ping_group_ok)" 0 "$sh: the full range includes the user"
  printf '%s %s\n' "$(id -g)" "$(id -g)" >"$fx/range"
  assert_eq "$(DF_PING_GROUP_RANGE_FILE="$fx/range" nd_rc "$sh" df_ping_group_ok)" 0 "$sh: a range of just the user's group"
  printf '%s 2147483647\n' $(($(id -G | tr ' ' '\n' | sort -n | tail -1) + 1)) >"$fx/range"
  assert_eq "$(DF_PING_GROUP_RANGE_FILE="$fx/range" nd_rc "$sh" df_ping_group_ok)" 1 "$sh: a range above the user's groups"
  printf 'garbage\n' >"$fx/range"
  assert_eq "$(DF_PING_GROUP_RANGE_FILE="$fx/range" nd_rc "$sh" df_ping_group_ok)" 1 "$sh: an unreadable range is a no"
  assert_eq "$(DF_PING_GROUP_RANGE_FILE="$fx/missing" nd_rc "$sh" df_ping_group_ok)" 1 "$sh: a missing range file is a no"
}

check_helpers bash
zsh_checked=0
if command -v zsh >/dev/null 2>&1; then
  check_helpers zsh
  zsh_checked=1
fi

# The pinned image is a version, never "latest".
assert_ok "netshoot image is pinned to a version" -- grep -Eq '^DF_NETSHOOT_IMAGE="\$\{DF_NETSHOOT_IMAGE:-nicolaka/netshoot:v[0-9][0-9.]*\}"$' "$nd"

# Both shells load the helpers in every profile, and stay silent doing it.
pty() { timeout 60 script -qec "$1" /dev/null </dev/null | tr -d '\r'; }
check_interactive() { # <zsh binary or empty>
  assert_eq "$(pty "DOTFILES_IN_ZSH=1 TERM=xterm-256color bash -i -c 'type -t port certinfo netshoot'")" \
    "$(printf 'function\nfunction\nfunction')" "interactive bash has the network helpers"
  assert_eq "$(pty "DOTFILES_IN_ZSH=1 TERM=xterm-256color bash -i -c 'true'")" "" "interactive bash stays silent"
  if [ -n "$1" ]; then
    assert_eq "$(pty "TERM=xterm-256color $1 -i -c 'whence -w port certinfo netshoot'")" \
      "$(printf 'port: function\ncertinfo: function\nnetshoot: function')" "interactive zsh has the network helpers"
    assert_eq "$(pty "TERM=xterm-256color $1 -i -c 'true'")" "" "interactive zsh stays silent"
  fi
  assert_eq "$(bash -c '. ~/.bashrc; type -t port' 2>&1)" "" "a non-interactive shell defines nothing and prints nothing"
}

# --- minimal rows: offline, nothing downloaded ---------------------------------------
if [ "$DF_PROFILE" = minimal ]; then
  bash /src/install.sh --profile minimal >/dev/null 2>&1
  zsh_bin=''
  if command -v zsh >/dev/null 2>&1; then zsh_bin="$(command -v zsh)"; fi
  check_interactive "$zsh_bin"
  for p in .local/bin/mise .local/share/mise .cache/mise .config/mise; do
    assert_file_absent "$HOME/$p"
  done
  for t in doggo xh grpcurl websocat step stern trip; do
    assert_eq "$(bash -lc "command -v $t || echo none")" none "no $t on minimal"
  done
  return 0
fi

# --- server rows ------------------------------------------------------------------------
# The tools are pinned in the config: exact versions, the aqua registry where
# its asset is static, the github backend with a musl pattern otherwise.
for key in doggo:mr-karan/doggo xh:ducaale/xh grpcurl:fullstorydev/grpcurl websocat:vi/websocat \
  step:smallstep/cli stern:stern/stern; do
  assert_ok "config pins aqua:${key#*:}" -- grep -Eq "^\"aqua:${key#*:}\" = \"[0-9][0-9.]*\"$" "$cfg"
done
assert_ok "config pins trippy to a musl asset" -- \
  grep -Eq '^"github:fujiapple852/trippy" = \{ version = "[0-9][0-9.]*", asset_pattern = "[^"]*x86_64-unknown-linux-musl[^"]*" \}$' "$cfg"

log="$(mktemp)"
bash /src/install.sh --profile server >"$log" 2>&1 || { cat "$log" >&2; _fail "install.sh --profile server failed"; }
export PATH="$HOME/.local/bin:$PATH"
zsh_bin="$(command -v zsh)"
assert_ok "a usable zsh exists" -- "$zsh_bin" -fc 'exit 0'
if [ "$zsh_checked" = 0 ]; then check_helpers "$zsh_bin"; fi
check_interactive "$zsh_bin"

# case_tools_run: u20-* has glibc 2.31, so these also prove the builds do not
# need a newer one. Found through the login shell's PATH like a real session.
for cmd in 'doggo --version' 'xh --version' 'grpcurl --version' 'websocat --version' 'step version' \
  'stern --version' 'trip --version'; do
  assert_ok "$cmd runs" -- bash -lc "$cmd"
done

# Helpers with the real network (the server rows have it).
assert_eq "$(nd_run bash 'port github.com 443')" "open github.com:443" "port reaches github.com:443"
assert_eq "$("$zsh_bin" -c ". $nd; port github.com 443")" "open github.com:443" "zsh: port reaches github.com:443"
cert="$(nd_run bash 'certinfo github.com')"
assert_ok "certinfo shows the SAN" -- grep -qi 'subject alternative name\|subjectAltName' <<<"$cert"
assert_ok "certinfo shows the expiry" -- grep -q 'notAfter=' <<<"$cert"
assert_ok "certinfo shows the issuer" -- grep -q '^issuer=' <<<"$cert"
assert_ok "certinfo accepts host:port and an SNI" -- nd_run bash 'certinfo github.com:443 github.com'
assert_ok "zsh: certinfo shows the expiry" -- grep -q 'notAfter=' <<<"$(nd_run "$zsh_bin" 'certinfo github.com')"
assert_nonempty() { [ -n "$1" ] || _fail "$2"; }
assert_nonempty "$(bash -lc 'doggo github.com A --short' 2>&1)" "doggo resolves github.com"

# An open port, served by one of the new tools (a WebSocket server on loopback).
lport=18765
bash -lc "websocat -s 127.0.0.1:$lport" >/dev/null 2>&1 &
ws_pid=$!
up=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if nd_run bash "port 127.0.0.1 $lport 1" >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 0.5
done
[ "$up" = 1 ] || _fail "the websocat test server did not come up"
assert_eq "$(nd_run bash "port 127.0.0.1 $lport")" "open 127.0.0.1:$lport" "port sees an open port"
assert_eq "$(nd_run "$zsh_bin" "port 127.0.0.1 $lport")" "open 127.0.0.1:$lport" "zsh: port sees an open port"
assert_eq "$(nd_rc bash "port 127.0.0.1 $lport")" 0 "open exits 0"
pkill -P "$ws_pid" 2>/dev/null || true
kill "$ws_pid" 2>/dev/null || true
wait "$ws_pid" 2>/dev/null || true

# case_trippy_unprivileged: trippy 0.13 has no unprivileged mode on Linux (it
# needs CAP_NET_RAW, whatever net.ipv4.ping_group_range says), so this either
# works or fails with trippy's own, clear message about privileges. Nothing else.
rc=0
trip_err="$(bash -lc 'trip --unprivileged --mode silent --report-cycles 1 127.0.0.1' 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -ne 0 ]; then
  assert_ok "trip says why it cannot run unprivileged: $trip_err" -- \
    grep -Eqi 'not supported on this platform|privileges are required|permission|ping_group_range|not permitted' <<<"$trip_err"
fi
