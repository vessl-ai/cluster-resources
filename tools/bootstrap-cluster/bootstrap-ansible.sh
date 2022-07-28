#!/usr/bin/env bash
set -eo pipefail

if [ -n "${DEBUG}" ]; then
  set -x
fi

# Fail fast with a concise message when not using bash
# Single brackets are needed here for POSIX compatibility
# shellcheck disable=SC2292
if [ -z "${BASH_VERSION:-}" ]
then
  abort "ERROR: Bash is required to interpret this script."
fi

set -u

# ---------------------
# Environment variables
# ---------------------
VSSL_PYTHON_VERSION="3.8.12"

# ----------------
# Helper functions
# ----------------

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

_command_exists() {
  command -v "$@" > /dev/null 2>&1
}

_detect_os() {
  if [ ! -f /etc/os-release ]; then
    printf 'ERROR: Failed to get OS information.\nVESSL cluster bootstrapper currently supports following OS: %s.\n' "$SUPPORTED_LINUX_OS_DIST" 1>&2
    return 1
  fi
  # shellcheck source=/dev/null
  os=$(. /etc/os-release; echo "$ID" | tr "[:upper:]" "[:lower:]")
  case "$os" in
    ubuntu)
      echo "ubuntu"
      ;;
    centos)
      echo "centos"
      ;;
    *)
      printf 'ERROR: Unsupported operating system: %s.\nVESSL cluster bootstrapper currently supports following OS: %s.\n' "$os" "$SUPPORTED_LINUX_OS_DIST" 1>&2
      return 1
      ;;
  esac
  unset os
}

# -------------------
# Installation script
# -------------------

# Install asdf to $VSSL_ASDF_PATH
if ! _command_exists asdf; then
  # shellcheck disable=SC2001
  vssl_asdf_path=$(echo "${VSSL_ASDF_PATH:-$HOME/.asdf}" | sed "s:/*$::")

  echo "Installing asdf (tool version manager) to $vssl_asdf_path ..."
  if [ -d "$vssl_asdf_path" ] || [ -f "$vssl_asdf_path" ]; then
    abort "ERROR: There is existing directory or file in $vssl_asdf_path .\nTry setting VSSL_ASDF_PATH={new_path} to configure path to install tool version manager.\n"
  fi
  git clone https://github.com/asdf-vm/asdf.git "$vssl_asdf_path" --branch v0.10.2
  # shellcheck source=/dev/null
  . "$vssl_asdf_path/asdf.sh"
  unset vssl_asdf_path
fi

# Make sure OpenSSL is installed (Used for Python installation)
echo "Making sure OpenSSL and libffi is installed..."
os=$(_detect_os)
case "$os" in
  ubuntu)
    sudo apt-get install -y -qq libssl-dev libffi-dev libreadline-dev
    ;;
  centos)
    rpm -q > /dev/null 2>&1 openssl-devel || sudo yum install -y -q openssl-devel libffi-devel readline-devel
    ;;
esac

# Confirgure installation environment
echo "Setting up virtualenv to install required tools..."
asdf install python $VSSL_PYTHON_VERSION
asdf local python $VSSL_PYTHON_VERSION
python -m pip install virtualenv
asdf reshim python
virtualenv -p "$(asdf where python)/bin/python" vessl-bootstrap-cluster
# shellcheck source=/dev/null
source ./vessl-bootstrap-cluster/bin/activate

echo "Installing Ansible (remote deployment automation tool) to virtualenv..."
pip install ansible==5.10.0
