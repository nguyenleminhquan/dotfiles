# Platform detection: real container first, then fixture files to simulate
# other hosts. Fixtures live in a private temp dir so cases never collide.
# shellcheck source=/dev/null
. /src/lib/log.sh
# shellcheck source=/dev/null
. /src/lib/detect.sh

fx="$(mktemp -d)"

df_detect
assert_eq "$DF_ARCH" "x86_64" "arch"
assert_ok "real container supported" -- df_platform_supported
assert_ok "glibc detected" -- test -n "$DF_GLIBC"
case "$DF_ROW" in
  u20-*) assert_eq "$DF_OS_ID $DF_OS_VERSION" "ubuntu 20.04" "real os ($DF_ROW)"; assert_eq "$DF_GLIBC" "2.31" "real glibc ($DF_ROW)" ;;
  u22)   assert_eq "$DF_OS_ID $DF_OS_VERSION" "ubuntu 22.04" "real os ($DF_ROW)"; assert_eq "$DF_GLIBC" "2.35" "real glibc ($DF_ROW)" ;;
  u24-*) assert_eq "$DF_OS_ID $DF_OS_VERSION" "ubuntu 24.04" "real os ($DF_ROW)"; assert_eq "$DF_GLIBC" "2.39" "real glibc ($DF_ROW)" ;;
  r9)    assert_eq "$DF_OS_ID" "rocky" "real os ($DF_ROW)"; assert_eq "${DF_OS_VERSION%%.*}" "9" "real rocky major ($DF_ROW)"; assert_eq "$DF_GLIBC" "2.34" "real glibc ($DF_ROW)" ;;
  d12)   assert_eq "$DF_OS_ID $DF_OS_VERSION" "debian 12" "real os ($DF_ROW)"; assert_eq "$DF_GLIBC" "2.36" "real glibc ($DF_ROW)" ;;
  d13)   assert_eq "$DF_OS_ID $DF_OS_VERSION" "debian 13" "real os ($DF_ROW)"; assert_eq "$DF_GLIBC" "2.41" "real glibc ($DF_ROW)" ;;
esac

# WSL detection from /proc/version fixtures.
printf 'Linux version 4.4.0-26100-Microsoft\n' >"$fx/pv1"
DF_PROC_VERSION_FILE="$fx/pv1" df_detect
assert_eq "$DF_WSL" "1" "wsl1 detected"
printf 'Linux version 5.15.153.1-microsoft-standard-WSL2\n' >"$fx/pv2"
DF_PROC_VERSION_FILE="$fx/pv2" df_detect
assert_eq "$DF_WSL" "2" "wsl2 detected"
printf 'Linux version 6.1.0-18-amd64 (debian-kernel@lists.debian.org)\n' >"$fx/pv0"
DF_PROC_VERSION_FILE="$fx/pv0" df_detect
assert_eq "$DF_WSL" "0" "native linux is not wsl"
DF_PROC_VERSION_FILE="$fx/missing" df_detect
assert_eq "$DF_WSL" "0" "missing /proc/version means not wsl"

# os-release fixtures: parsing (quoted/unquoted) and the support matrix.
printf 'ID=rocky\nVERSION_ID="8.10"\n' >"$fx/osr"
DF_OS_RELEASE_FILE="$fx/osr" df_detect
assert_eq "$DF_OS_ID $DF_OS_VERSION" "rocky 8.10" "rocky 8 parsed"
assert_fail "rocky 8 rejected" -- df_platform_supported

printf 'ID="rocky"\nVERSION_ID="9.4"\n' >"$fx/osr"
DF_OS_RELEASE_FILE="$fx/osr" df_detect
assert_eq "$DF_OS_ID $DF_OS_VERSION" "rocky 9.4" "rocky 9.4 parsed"
assert_ok "rocky 9.4 supported" -- df_platform_supported

for v in 20.04 22.04 24.04; do
  printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="%s"\nID_LIKE=debian\n' "$v" >"$fx/osr"
  DF_OS_RELEASE_FILE="$fx/osr" df_detect
  assert_eq "$DF_OS_ID $DF_OS_VERSION" "ubuntu $v" "ubuntu $v parsed"
  assert_ok "ubuntu $v supported" -- df_platform_supported
done

printf 'ID=ubuntu\nVERSION_ID="18.04"\n' >"$fx/osr"
DF_OS_RELEASE_FILE="$fx/osr" df_detect
assert_fail "ubuntu 18.04 rejected" -- df_platform_supported

printf 'ID=ubuntu\nVERSION_ID="23.10"\n' >"$fx/osr"
DF_OS_RELEASE_FILE="$fx/osr" df_detect
assert_fail "ubuntu 23.10 rejected" -- df_platform_supported

for v in 12 13; do
  printf 'PRETTY_NAME="Debian GNU/Linux %s"\nID=debian\nVERSION_ID="%s"\n' "$v" "$v" >"$fx/osr"
  DF_OS_RELEASE_FILE="$fx/osr" df_detect
  assert_eq "$DF_OS_ID $DF_OS_VERSION" "debian $v" "debian $v parsed"
  assert_ok "debian $v supported" -- df_platform_supported
done

printf 'ID=debian\nVERSION_ID="11"\n' >"$fx/osr"
DF_OS_RELEASE_FILE="$fx/osr" df_detect
assert_fail "debian 11 rejected" -- df_platform_supported

# testing and sid have no VERSION_ID
printf 'PRETTY_NAME="Debian GNU/Linux forky/sid"\nID=debian\n' >"$fx/osr"
DF_OS_RELEASE_FILE="$fx/osr" df_detect
assert_eq "$DF_OS_ID $DF_OS_VERSION" "debian " "debian sid parsed without a version"
assert_fail "debian sid rejected" -- df_platform_supported

# ID_LIKE must not make a derivative count as a supported distro.
printf 'ID=raspbian\nID_LIKE=debian\nVERSION_ID="12"\n' >"$fx/osr"
DF_OS_RELEASE_FILE="$fx/osr" df_detect
assert_eq "$DF_OS_ID" "unknown" "raspbian is unknown"
assert_fail "raspbian rejected" -- df_platform_supported

DF_OS_RELEASE_FILE="$fx/missing" df_detect
assert_eq "$DF_OS_ID" "unknown" "missing os-release is unknown"
assert_fail "missing os-release rejected" -- df_platform_supported

# Architecture gate: a supported distro on a non-x86_64 CPU is rejected.
df_detect
DF_ARCH=aarch64
assert_fail "aarch64 rejected" -- df_platform_supported
DF_ARCH=x86_64

# Rejections explain themselves on stderr; support is silent.
printf 'ID=rocky\nVERSION_ID="8.10"\n' >"$fx/osr"
DF_OS_RELEASE_FILE="$fx/osr" df_detect
err="$(df_platform_supported 2>&1 >/dev/null || true)"
assert_ok "rejection logs a reason" -- grep -q 'rocky' <<<"$err"
df_detect
assert_eq "$(df_platform_supported 2>&1)" "" "supported platform logs nothing"

# lib/log.sh: stderr only, plain text when stderr is not a tty, die exits 1.
assert_eq "$(log_info hello 2>&1 >/dev/null)" "[info] hello" "log_info goes to stderr"
assert_eq "$(log_info hello 2>/dev/null)" "" "log_info is silent on stdout"
assert_eq "$(log_warn careful 2>&1 >/dev/null)" "[warn] careful" "log_warn format"
assert_eq "$(log_error broken 2>&1 >/dev/null)" "[error] broken" "log_error format"
rc=0
out="$(die "fatal thing" 2>&1)" || rc=$?
assert_eq "$rc" "1" "die exits 1"
assert_eq "$out" "[error] fatal thing" "die prints an error"

rm -rf "$fx"
