#!/usr/bin/env bash
set -eo pipefail

if [ -n "${DEBUG}" ]; then
  set -x
fi

bold() {
  echo -e "\e[1m$1\e[0m"
}

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

# Fail fast with a concise message when not using bash
# Single brackets are needed here for POSIX compatibility
# shellcheck disable=SC2292
if [ -z "${BASH_VERSION:-}" ]
then
  abort "ERROR: Bash is required to interpret this script."
fi

set -u

# -------------------------------
# Environment variables and flags
# -------------------------------

SUPPORTED_LINUX_OS_DIST="Ubuntu 16.04+, Centos 7.9+"
K0S_VERSION="v1.23.8+k0s.0"
K0S_ROLE="controller"
K0S_JOIN_TOKEN=""

print_help() {
  echo "usage: $0 [options]"
  echo "Bootstraps a node into an k8s cluster connectable to VESSL"
  echo ""
  echo "-h,--help print this help"
  echo "--role    node's role in the cluster (controller or worker)"
  echo "--token   token to join k0s cluster - necessary when --role=worker."
  echo "          run 'sudo k0s token create --role worker' from a controller node to get one"
}

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -h|--help)
      print_help
      exit 1
      ;;
    --role)
      K0S_ROLE="$2"
      if [ "$K0S_ROLE" != "controller" ] && [ "$K0S_ROLE" != "worker" ]; then
        abort "ERROR: --role must be either 'controller' or 'worker'"
      fi
      shift
      shift
      ;;
    --token)
      K0S_JOIN_TOKEN="$2"
      shift
      shift
      ;;
    --meow)
      echo "meow"
      exit 2
      ;;
    *)
      # unknown option, save it in an array for later
      POSITIONAL+=("$1")
      shift # past argument
      ;;
  esac
done

# ----------------
# Helper functions
# ----------------

_command_exists() {
  command -v "$@" > /dev/null 2>&1
}

_cuda_version() {
  if nvcc --version 2&> /dev/null; then
    # Determine CUDA version using default nvcc binary
    nvcc --version | sed -n 's/^.*release \([0-9]\+\.[0-9]\+\).*$/\1/p'
  elif /usr/local/cuda/bin/nvcc --version 2&> /dev/null; then
    # Determine CUDA version using /usr/local/cuda/bin/nvcc binary
    /usr/local/cuda/bin/nvcc --version | sed -n 's/^.*release \([0-9]\+\.[0-9]\+\).*$/\1/p'
  elif [ -f "/usr/local/cuda/version.txt" ]; then
    # Determine CUDA version using /usr/local/cuda/version.txt file
    < /usr/local/cuda/version.txt sed 's/.* \([0-9]\+\.[0-9]\+\).*/\1/'
  elif [ -f "/usr/local/cuda/version.json" ] && _command_exists jq; then
    # Determine CUDA version using /usr/local/cuda/version.txt file
    < /usr/local/cuda/version.json jq -r '.cuda_nvcc.version'
  else
    echo ""
  fi
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
      printf 'ERROR: Unsupported processor architecture: %s' "$arch" 1>&2
      return 1
      ;;
  esac
  unset arch
}

# -------------------------
# Install and enable Docker
# -------------------------
if ! _command_exists docker; then
  bold "Command 'docker' not found, installing Docker"
  docker_script_path=$(mktemp)
  curl -fsSL get.docker.com -o "${docker_script_path}"
  sudo sh "${docker_script_path}"
  sudo rm -f "${docker_script_path}"
  unset docker_script_path

  bold "Adding user to Docker usergroup"
  if ! getent group docker > /dev/null; then
    sudo groupadd docker
    newgrp docker
  else
    sudo usermod -aG docker "$(whoami)"
  fi
fi

bold "Enabling Docker daemon"
sudo systemctl --now enable docker

# ----------------------------------------------------------------------------------------------
# Install NVIDIA Container Toolkit
# FWIW: differences between packages provided by NVIDIA
#  * libnvidia-container: library for let containers run with NVIDIA GPU support
#  * nvidia-container-toolkit: implements the interface required by a runC prestart hook
#  * nvidia-container-runtime: thin wrapper around the native runC with NVIDIA specific code
#  * nvidia-docker2: package for GPU support to Docker containers using nvidia-container-runtime
# i.e. nvidia-docker2 will let machine run GPU containers with k8s + Docker
# https://github.com/NVIDIA/nvidia-docker/issues/1268#issuecomment-632692949
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/arch-overview.html
# ----------------------------------------------------------------------------------------------
if ! _command_exists nvidia-smi; then
  bold "NVIDIA Driver not found in the node (Node does not have GPU?), skipping nvidia-docker2 installation."
  bold "Please reach out to support@vessl.ai if you need technical support for non-NVIDIA accelerators."
elif ! _command_exists nvidia-container-toolkit; then
  bold "NVIDIA Container Toolkit not found, Installing nvidia-docker2"
  os="$(_detect_os)"
  case "$os" in
    ubuntu)
      if [ -n "$(find /etc/apt/sources.list.d -name '*nvidia*' | head -1)" ]; then
        bold "Moving existing nvidia-docker source repository targets to /tmp/apt-sources-nvidia-docker"
        sudo mkdir -p /tmp/apt-sources-nvidia-docker
        sudo mv -v /etc/apt/sources.list.d/*nvidia* /tmp/apt-sources-nvidia-docker
      fi

      bold "Setting up nvidia-container-toolkit repository and GPG key"
      # shellcheck source=/dev/null
      distribution=$(. /etc/os-release; echo "$ID""$VERSION_ID" | tr "[:upper:]" "[:lower:]")
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -sL https://nvidia.github.io/libnvidia-container/"$distribution"/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

      bold "Updating public keys for nvidia-container-toolkit repositories"
      # GPG keys for nvidia-container-toolkit repositories: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#ubuntu-installation-network
      # GPG keys for DGX machines https://docs.nvidia.com/dgx/dgx-os-release-notes/index.html#rotating-gpg-keys
      sudo apt-key del 7fa2af80
      nvidia_keyring_path=$(mktemp)
      curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/${distribution//.}/$(uname -m)/cuda-keyring_1.0-1_all.deb" -o "${nvidia_keyring_path}"
      yes | sudo dpkg -i "${nvidia_keyring_path}"
      sudo rm -f "${nvidia_keyring_path}"
      unset nvidia_keyring_path
      sudo apt-key adv --fetch-keys "https://developer.download.nvidia.com/compute/cuda/repos/${distribution//.}/$(uname -m)/3bf863cc.pub"
      sudo apt-key adv --fetch-keys "https://developer.download.nvidia.com/compute/machine-learning/repos/${distribution//.}/$(uname -m)/7fa2af80.pub"
      sudo apt-get update

      bold "Installing nvidia-docker"
      sudo apt-get install -y nvidia-docker2
      ;;
    centos)
      bold "Setting up nvidia-container-toolkit repository and GPG key"
      # shellcheck source=/dev/null
      distribution=$(. /etc/os-release; echo "$ID$VERSION_ID") \
        && curl -s -L https://nvidia.github.io/libnvidia-container/"$distribution"/libnvidia-container.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo

      bold "Installing nvidia-docker"
      centos_major_version="$(< /etc/centos-release tr -dc '0-9)')"
      if [ "$centos_major_version" == "7" ]; then
        sudo yum clean expire-cache
        sudo yum install -y nvidia-docker2
      else
        sudo dnf clean expire-cache --refresh
        sudo dnf install -y nvidia-docker2
      fi
      unset centos_major_version
      ;;
  esac
else
  bold "NVIDIA Driver and Container Toolkit already installed, skipping"
fi

if _command_exists nvidia-container-toolkit; then
  bold "Updating Docker runtime to nvidia-container-runtime"
  if [ -f /etc/docker/daemon.json ]; then
    bold "Found existing /etc/docker/daemon.json, backing up to /etc/docker/daemon.json.bak"
    sudo mv -v /etc/docker/daemon.json /etc/docker/daemon.json.bak
  fi
  cat <<-EOF | sudo tee /etc/docker/daemon.json
{
    "default-runtime": "nvidia",
    "live-restore": true,
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF

  bold "Restarting Docker daemon"
  sudo systemctl restart docker

  bold "Verifying nvidia-docker2 is working correctly"
  cuda_major_version="$(_cuda_version | cut -d '.' -f 1)"
  test_container_ubuntu_version="18.04"
  if [ "$cuda_major_version" == "9" ]; then
    test_container_ubuntu_version="16.04"
  fi
  if ! sudo docker run --gpus all "nvidia/cuda:$cuda_major_version.0-base-ubuntu$test_container_ubuntu_version" nvidia-smi; then
    abort "ERROR: nvidia-docker is not working correctly.\nIf the problem persists after retry, please reach out support@vessl.ai for technical support."
  fi
  unset cuda_major_version
  unset test_container_ubuntu_version
fi

# -----------
# Install k0s
# -----------
if ! _command_exists k0s; then
  bold "k0s (portable Kubernetes runtime) not found in the node. Installing k0s $K0S_VERSION"
  curl -sSLf https://get.k0s.sh | sudo K0S_VERSION="$K0S_VERSION" sh
fi

# -------
# Run k0s
# -------
bold "Checking if there is existing k0s running"
k0s_executable="/usr/local/bin/k0s" # See https://get.k0s.sh/ to see where this is located (k0sInstallPath)
if sudo $k0s_executable status 2&> /dev/null; then
  k0s_role="$(k0s status | grep "Role" | awk -F': ' '{print $2}')"
  abort "ERROR: k0s is already running as $k0s_role.\nIf you want to reset the cluster, run 'sudo k0s stop && sudo k0s reset' before retrying the script."
fi

bold "Running k0s as $K0S_ROLE"
k0s_config_path="/opt/vessl/k0s"
bold "Writing k0s cluster configuration to $k0s_config_path"
sudo mkdir -p $k0s_config_path

if [ "$K0S_ROLE" == "controller" ]; then
  sudo $k0s_executable config create | sudo tee $k0s_config_path/k0s.yaml
  sudo sed -i -e 's/provider: kuberouter/provider: calico/g' $k0s_config_path/k0s.yaml
  sudo $k0s_executable install controller -c $k0s_config_path/k0s.yaml \
    --enable-worker \
    --cri-socket=docker:unix:///var/run/docker.sock \
    --kubelet-extra-args="--network-plugin=cni"
elif [ "$K0S_ROLE" == "worker" ]; then
  if [ "$K0S_JOIN_TOKEN" == "" ]; then
    abort "ERROR: cluster join token is not set.\nPlease set --token option to join the cluster."
  fi
  echo "$K0S_JOIN_TOKEN" | sudo tee $k0s_config_path/token
  sudo $k0s_executable install worker \
    --token-file $k0s_config_path/token \
    --cri-socket=docker:unix:///var/run/docker.sock \
    --kubelet-extra-args="--network-plugin=cni"
fi

bold "Running k0s as $K0S_ROLE"
sudo $k0s_executable start

bold "Waiting for k0s $K0S_ROLE to be ready"
sleep 3
count=0
until sudo systemctl is-active --quiet "k0s$K0S_ROLE" || [[ $count -eq 10 ]]; do
  (( count++ ))
  echo -e "...\c"
  sleep 3
done
if [[ $count -eq 10 ]]; then
  sudo systemctl status "k0s$K0S_ROLE" --no-pager -l
  abort "ERROR: k0s $K0S_ROLE failed to start. Please check error logs using 'journalctl -u k0s$K0S_ROLE.service'.\nIf the problem persists after retry, please reach out support@vessl.ai for technical support."
fi

bold "-------------------\nBootstrap complete!\n-------------------\n"
if [ "$K0S_ROLE" == "controller" ]; then
  k0s_token=$(sudo $k0s_executable token create --role=worker)
  bold "Node is configured as a control plane node."
  bold "To join other nodes to the cluster, run the following command on the worker node:"
  bold "  curl -sSLf https://install.dev.vssl.ai | sudo bash -s -- --role worker --token '$k0s_token'\n\n"
  bold "To get Kubernetes admin's kubeconfig file, run the following command on the control plane node:"
  bold "  /usr/local/bin/k0s kubeconfig admin"
  unset k0s_token
elif [ "$K0S_ROLE" == "worker" ]; then
  bold "Node is configured as a worker node and joined the cluster.\n"
fi

