# shellcheck disable=SC2034  # DF_* variables are the public interface, consumed by callers
# Platform detection. Meant to be sourced; defines functions only.
#
# df_detect sets:
#   DF_OS_ID       ubuntu | rocky | unknown
#   DF_OS_VERSION  VERSION_ID from os-release (e.g. 20.04, 9.4), may be empty
#   DF_WSL         0 (not WSL) | 1 | 2
#   DF_ARCH        output of uname -m
#   DF_GLIBC       glibc version (e.g. 2.31), may be empty
#
# DF_OS_RELEASE_FILE and DF_PROC_VERSION_FILE override the files that are read
# and exist for tests only.

# _df_os_field <key> <file>: value of KEY=value, without surrounding quotes.
# The file is parsed, never sourced, so it cannot clobber variables or run code.
_df_os_field() {
  local key="$1" file="$2"
  [ -r "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | head -n 1 | tr -d "\"'"
}

df_detect() {
  local os_file="${DF_OS_RELEASE_FILE:-/etc/os-release}"
  local proc_file="${DF_PROC_VERSION_FILE:-/proc/version}"
  local id glibc

  # Only ID is consulted, not ID_LIKE: derivatives are not supported targets.
  id="$(_df_os_field ID "$os_file")"
  case "$id" in
    ubuntu | rocky) DF_OS_ID="$id" ;;
    *) DF_OS_ID=unknown ;;
  esac
  DF_OS_VERSION="$(_df_os_field VERSION_ID "$os_file")"

  # WSL2 kernels say "...-microsoft-standard-WSL2"; WSL1 reports a Windows
  # build as "4.4.0-<build>-Microsoft" with no WSL2 marker.
  DF_WSL=0
  if [ -r "$proc_file" ] && grep -qi microsoft "$proc_file"; then
    if grep -qi wsl2 "$proc_file"; then DF_WSL=2; else DF_WSL=1; fi
  fi

  DF_ARCH="$(uname -m)"

  # "getconf GNU_LIBC_VERSION" prints "glibc 2.31"; keep the number.
  glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
  DF_GLIBC="${glibc#* }"
  [ "$DF_GLIBC" != "$glibc" ] || DF_GLIBC=""
}

# df_platform_supported: 0 for Ubuntu 20.04/22.04/24.04 or Rocky 9.x on
# x86_64 (native or WSL); otherwise 1 with the reason on stderr.
df_platform_supported() {
  if [ "$DF_ARCH" != "x86_64" ]; then
    log_error "unsupported architecture: $DF_ARCH (x86_64 only)"
    return 1
  fi
  case "$DF_OS_ID:$DF_OS_VERSION" in
    ubuntu:20.04 | ubuntu:22.04 | ubuntu:24.04) return 0 ;;
    rocky:9 | rocky:9.*) return 0 ;;
  esac
  log_error "unsupported platform: ${DF_OS_ID} ${DF_OS_VERSION:-(no version)}; supported: Ubuntu 20.04/22.04/24.04, Rocky 9"
  return 1
}
