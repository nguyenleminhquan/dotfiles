# shellcheck shell=bash
# Network debugging helpers, sourced by ~/.bashrc and ~/.zshrc for every profile
# (minimal included: they need nothing but bash, coreutils and openssl, and
# they download nothing). Sourcing only defines functions: no fork, no output.
#
#   port <host> <port> [timeout_s=3]   TCP probe through bash's /dev/tcp
#   certinfo <host[:port]> [sni]       subject, issuer, SAN and dates of a TLS certificate
#   netshoot [namespace]               throwaway nicolaka/netshoot pod in the current cluster
#   df_ping_group_ok                   may this user open an unprivileged ICMP socket (rootless ping)?

# Pinned: never `latest`, so a debug pod is the same image everywhere.
DF_NETSHOOT_IMAGE="${DF_NETSHOOT_IMAGE:-nicolaka/netshoot:v0.16}"

# port <host> <port> [timeout_s=3]: prints "open <host>:<port>" and returns 0,
# or "closed <host>:<port>" and returns 1. Never takes longer than timeout_s + 1
# seconds: `timeout` stops a connect that hangs, and -k 1 kills one that
# ignores the signal. The probe runs in bash even when the caller is zsh,
# because /dev/tcp is a bash feature.
port() {
  local host="${1:-}" p="${2:-}" t="${3:-3}"
  if [[ -z $host || -z $p || $# -gt 3 ]]; then
    echo "usage: port <host> <port> [timeout_s]" >&2
    return 2
  fi
  case $p in
    '' | *[!0-9]*)
      echo "port: invalid port: $p" >&2
      return 2
      ;;
  esac
  if ((10#$p < 1 || 10#$p > 65535)); then
    echo "port: invalid port: $p" >&2
    return 2
  fi
  case $t in
    '' | *[!0-9.]* | *.*.* | .)
      echo "port: invalid timeout: $t" >&2
      return 2
      ;;
  esac
  # GNU timeout treats 0 (also 0.0, 00) as "no timeout": a hung connect would never return.
  case $t in
    *[1-9]*) ;;
    *)
      echo "port: the timeout must be greater than 0: $t" >&2
      echo "usage: port <host> <port> [timeout_s]" >&2
      return 2
      ;;
  esac
  if ! command -v timeout >/dev/null 2>&1; then
    echo "port: timeout (coreutils) not found" >&2
    return 2
  fi
  if timeout -k 1 "$t" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$p" >/dev/null 2>&1; then
    printf 'open %s:%s\n' "$host" "$p"
    return 0
  fi
  printf 'closed %s:%s\n' "$host" "$p"
  return 1
}

# certinfo <host[:port]> [sni]: port defaults to 443, SNI to the host. IPv6
# literals are written [::1] or [::1]:8443. Prints what `openssl x509` shows of
# the certificate the server presents; fails with
# "certinfo: cannot connect to <host>:<port>" on stderr when there is none.
certinfo() {
  local target="${1:-}" sni="${2:-}" host port connect out
  local -a sni_args=()
  if [[ -z $target || $# -gt 2 ]]; then
    echo "usage: certinfo <host[:port]> [sni]" >&2
    return 2
  fi
  if ! command -v openssl >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    echo "certinfo: openssl and timeout are required" >&2
    return 1
  fi
  case $target in
    \[*\]:*)
      host="${target#\[}"
      host="${host%%\]*}"
      port="${target##*\]:}"
      ;;
    \[*\])
      host="${target#\[}"
      host="${host%\]}"
      port=443
      ;;
    # A bare IPv6 literal: more than one colon and no brackets.
    *:*:*)
      host="$target"
      port=443
      ;;
    *:*)
      host="${target%:*}"
      port="${target##*:}"
      ;;
    *)
      host="$target"
      port=443
      ;;
  esac
  case $port in
    '' | *[!0-9]*)
      echo "certinfo: invalid port in $target" >&2
      return 2
      ;;
  esac
  # An IP literal is not a valid SNI name, so none is sent unless one is given.
  if [[ -z $sni ]]; then
    case $host in
      *:*) ;;
      *[!0-9.]*) sni="$host" ;;
      *) ;;
    esac
  fi
  [[ -z $sni ]] || sni_args=(-servername "$sni")
  connect="$host:$port"
  if [[ $host == *:* ]]; then connect="[$host]:$port"; fi
  out="$(timeout -k 1 5 openssl s_client -connect "$connect" ${sni_args[@]+"${sni_args[@]}"} </dev/null 2>/dev/null)" || :
  case $out in
    *'BEGIN CERTIFICATE'*) ;;
    *)
      echo "certinfo: cannot connect to $host:$port" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$out" | openssl x509 -noout -subject -issuer -ext subjectAltName -dates
}

# netshoot [namespace]: an interactive zsh in a pod that is removed when the
# shell exits. The context is printed first, in bold red when it looks like
# production, because the pod lands in whichever cluster kubectl points at.
netshoot() {
  local ns="${1:-default}" ctx='' who name
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "netshoot: kubectl not found" >&2
    return 1
  fi
  # The df_kube_* helpers come from shell/prompt-minimal.sh (loaded by tools.sh).
  if type df_kube_context >/dev/null 2>&1; then
    ctx="$(df_kube_context 2>/dev/null)" || ctx=''
  fi
  if [[ -t 2 ]] && type df_kube_is_prod >/dev/null 2>&1 && df_kube_is_prod "$ctx"; then
    printf '\033[1;31mnetshoot: context %s, namespace %s\033[0m\n' "$ctx" "$ns" >&2
  else
    printf 'netshoot: context %s, namespace %s\n' "${ctx:-(none)}" "$ns" >&2
  fi
  # Pod names are DNS labels: lower case letters, digits and "-", at most 63.
  who="$(printf '%s' "${USER:-$(id -un 2>/dev/null)}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | cut -c1-30)"
  name="netshoot-${who:-user}-$RANDOM"
  kubectl run "$name" --rm -it --restart=Never -n "$ns" --image="$DF_NETSHOOT_IMAGE" -- zsh
}

# df_ping_group_ok: succeed when a group of the current user is inside
# net.ipv4.ping_group_range, which is what lets an unprivileged process open an
# ICMP socket (rootless ping). Fails when the file is unreadable or the range
# is empty ("1 0" is the kernel's "nobody"). Note that trippy does not use this
# on Linux: `trip` needs CAP_NET_RAW whatever the range says.
# DF_PING_GROUP_RANGE_FILE overrides the path (tests).
df_ping_group_ok() {
  local file="${DF_PING_GROUP_RANGE_FILE:-/proc/sys/net/ipv4/ping_group_range}" lo hi g
  [[ -r $file ]] || return 1
  read -r lo hi <"$file" || return 1
  [[ $lo =~ ^[0-9]+$ && $hi =~ ^[0-9]+$ ]] || return 1
  for g in $(id -G 2>/dev/null); do
    if ((g >= lo && g <= hi)); then return 0; fi
  done
  return 1
}
