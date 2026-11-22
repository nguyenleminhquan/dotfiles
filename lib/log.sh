# Logging helpers. Meant to be sourced; defines functions only.
# Everything goes to stderr so stdout stays clean for data. Colour is used only
# when stdout and stderr are both terminals (a piped or captured run gets plain text).

_log_emit() {
  local color="$1" label="$2"
  shift 2
  if [ -t 1 ] && [ -t 2 ]; then
    printf '\033[%sm[%s]\033[0m %s\n' "$color" "$label" "$*" >&2
  else
    printf '[%s] %s\n' "$label" "$*" >&2
  fi
}

log_info() { _log_emit 34 info "$@"; }
log_warn() { _log_emit 33 warn "$@"; }
log_error() { _log_emit 31 error "$@"; }

# die <msg>: log an error and exit the current shell with status 1.
die() {
  log_error "$@"
  exit 1
}
