#!/bin/bash
set -u

if [ -n "${DEBUG}" ]; then
  set -x
fi

# -------------------
#
_detect_binary() {
  os="$(uname)"
  case "$os" in
    Linux)
      echo "k0s"
      ;;
    *)
      echo "Unsupported operating system: $os" 1>&2; return 1
      ;;
  esac
  unset os
}

_detect_arch() {
  arch="$(uname -m)"
  case "$arch" in
    amd64|x86_64)
      echo "amd64"
      ;;
    arm64|aarch64)
      echo "arm64"
      ;;
    armv7l|armv8l|arm)
      echo "arm"
      ;;
    *)
      echo "Unsupported processor architecture: $arch" 1>&2; return 1
      ;;
  esac
  unset arch
}

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

# String formatters
if [[ -t 1 ]]
then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"


# Fail fast with a concise message when not using bash
# Single brackets are needed here for POSIX compatibility
# shellcheck disable=SC2292
if [ -z "${BASH_VERSION:-}" ]
then
  abort "Bash is required to interpret this script."
fi
