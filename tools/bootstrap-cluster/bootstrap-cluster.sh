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

K0S_EXECUTABLE="/usr/local/bin/k0s" # See https://get.k0s.sh/ to see where this is located (k0sInstallPath)
K0S_CONFIG_PATH="/opt/vessl/k0s"
K0S_VERSION="v1.25.12+k0s.0"
K0S_ROLE=""
K0S_JOIN_TOKEN=""
K0S_TAINT_CONTROLLER="false"
SKIP_NVIDIA_GPU_DEPENDENCIES="false"

print_help() {
  echo "usage: $0 [options]"
  echo "Bootstraps a node into an k8s cluster connectable to VESSL"
  echo ""
  echo "-h,--help                       print this help"
  echo "--role=[ROLE]                   node's role in the cluster (controller or worker)"
  echo "--taint-controller              Use control plane nodes only dedicated to node management"
  echo "                                In default, control plane nodes are also used for running workloads"
  echo "--skip-nvidia-gpu-dependencies  Do not abort script when NVIDIA GPU dependencies are not installed"
  echo "--token=[TOKEN]                 token to join k0s cluster; necessary when --role=worker."
}

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -h|--help)
      print_help
      exit 1
      ;;
    --role*)
      K0S_ROLE="${1#*=}"
      shift
      ;;
    --taint-controller)
      K0S_TAINT_CONTROLLER="true"
      shift
      ;;
    --skip-nvidia-gpu-dependencies)
      SKIP_NVIDIA_GPU_DEPENDENCIES="true"
      shift
      ;;
    --token*)
      K0S_JOIN_TOKEN="${1#*=}"
      shift
      ;;
    *)
      printf "ERROR: unknown option: %s\n" "$1"
      print_help
      exit 1
      ;;
  esac
done

# Validate arguments
if [ "$K0S_ROLE" != "controller" ] && [ "$K0S_ROLE" != "worker" ]; then
  printf "ERROR: unexpected role: %s\n\n" "$K0S_ROLE"
  print_help
  exit 1
fi

if [ "$K0S_ROLE" == "worker" ] && [ -z "$K0S_JOIN_TOKEN" ]; then
  printf "ERROR: missing join token for worker\n"
  printf "Run following command on the controller node to get one:\n"
  printf "  /usr/local/bin/k0s token create --role=worker\n\n"
  print_help
  exit 1
fi

# ----------------
# Helper functions
# ----------------

_command_exists() {
  command -v "$@" > /dev/null 2>&1
}

_cuda_version() {
  if [ -f "/usr/local/cuda/bin/nvcc" ] && /usr/local/cuda/bin/nvcc --version 2&> /dev/null; then
    # Determine CUDA version using /usr/local/cuda/bin/nvcc binary
    /usr/local/cuda/bin/nvcc --version | sed -n 's/^.*release \([0-9]\+\.[0-9]\+\).*$/\1/p'
  elif [ -f "/usr/local/cuda/version.txt" ]; then
    # Determine CUDA version using /usr/local/cuda/version.txt file
    < /usr/local/cuda/version.txt sed 's/.* \([0-9]\+\.[0-9]\+\).*/\1/'
  elif [ -f "/usr/local/cuda/version.json" ] && _command_exists jq; then
    # Determine CUDA version using /usr/local/cuda/version.txt file
    < /usr/local/cuda/version.json jq -r '.cuda_nvcc.version'
  elif [ -f "/usr/bin/nvcc" ] && /usr/bin/nvcc --version 2&> /dev/null; then
    # Determine CUDA version using /usr/bin/nvcc binary (usually conflicted with /usr/local/cuda, should use as a last resort)
    /usr/bin/nvcc --version | sed -n 's/^.*release \([0-9]\+\.[0-9]\+\).*$/\1/p'
  else
    echo ""
  fi
}

_detect_os() {
  if [ ! -f /etc/os-release ]; then
    abort "ERROR: Failed to get OS information.\nVESSL cluster bootstrapper currently supports following OS: Ubuntu 20.04+, Centos 7.9+.\n"
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
      printf 'ERROR: Unsupported operating system: %s.\nVESSL cluster bootstrapper currently supports following OS: Ubuntu 20.04+, Centos 7.9+.\n' "$os" 1>&2
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

_print_nvidia_dependency_error() {
  if SKIP_NVIDIA_GPU_DEPENDENCIES != "true"; then
    abort "ERROR: $*"
  else
    bold "WARNING: $*"
    bold "Running with --skip-nvidia-gpu-dependencies; Skipping NVIDIA GPU dependencies check."
  fi
}

# ----------
# Main logic
# ----------

ensure_hostname_lowercase() {
  [[ $hostname  =~ [A-Z] ]] && abort "Machine's hostname '$hostname' contains uppercase characters. Please set hostname to lowercase to make k8s cluster working."
}

ensure_nvidia_gpu_dependencies() {
  # Install NVIDIA Container Toolkit
  # FWIW: differences between packages provided by NVIDIA
  #  * libnvidia-container: library for let containers run with NVIDIA GPU support
  #  * nvidia-container-toolkit: implements the interface required by a runC prestart hook
  #  * nvidia-container-runtime: thin wrapper around the native runC with NVIDIA specific code
  # https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/arch-overview.html
  bold "Checking NVIDIA GPU dependencies..."

  # Check if NVIDIA GPU is available
  if sudo lshw -C display | grep -q "vendor: NVIDIA"; then
    bold "NVIDIA GPU not found in the system; skipping NVIDIA GPU dependencies check."
    bold "Please reach out to support@vessl.ai if you need technical support for non-NVIDIA accelerators."
    return 0
  fi

  # Check if nvidia-driver has been installed
  if ! _command_exists nvidia-smi; then
    _print_nvidia_dependency_error "NVIDIA driver not found. Please install NVIDIA driver first."
  fi

  if ! _command_exists nvcc; then
    _print_nvidia_dependency_error "nvidia-cuda-toolkit not found.\nRun following command to install nvidia-cuda-toolkit:\n  sudo apt-get install -y nvidia-cuda-toolkit"
  fi

  if ! _command_exists nvidia-container-toolkit; then
    # shellcheck disable=SC1091
    nvidia_toolkit_command="\n
      distribution=$(. /etc/os-release;echo \$ID\$VERSION_ID) \\\n
        && curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add - \\\n
        && curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list \n
      sudo apt-get install -y nvidia-container-toolkit"
    # shellcheck disable=SC1091
    if [ "$(_detect_os)" = "centos" ]; then
      nvidia_toolkit_command="\n
        distribution=$(. /etc/os-release;echo \$ID\$VERSION_ID) \\\n
          && curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo \n
        sudo dnf clean expire-cache && sudo dnf install -y nvidia-container-toolkit"
    fi
    _print_nvidia_dependency_error "nvidia-container-toolkit not found.\nRun following command to install nvidia-container-toolkit:\n$nvidia_toolkit_command"
  fi
}

enforce_nvidia_device_visibility_to_volume_mounts() {
  # To prevent unprivileged container access all host GPUs, Set accept-nvidia-visible-devices-envvar-when-unprivileged=false
  # VESSL will only allow GPU access by volume mounts by setting accept-nvidia-visible-devices-as-volume-mounts=true
  # See also: https://docs.google.com/document/d/1zy0key-EL6JH50MZgwg96RPYxxXXnVUdxLZwGiyqLd8/edit
  bold "Setting NVIDIA GPU device visibility method as volume mounts"
  if ! _command_exists nvidia-container-runtime; then
    bold "nvidia-container-runtime not found; skipping setting NVIDIA GPU device visibility."
    return
  fi
  cat << EOF > /etc/nvidia-container-runtime/config.toml
disable-require = false
#swarm-resource = "DOCKER_RESOURCE_GPU"
accept-nvidia-visible-devices-envvar-when-unprivileged = false
accept-nvidia-visible-devices-as-volume-mounts = true

[nvidia-container-cli]
#root = "/run/nvidia/driver"
#path = "/usr/bin/nvidia-container-cli"
environment = []
#debug = "/var/log/nvidia-container-toolkit.log"
#ldcache = "/etc/ld.so.cache"
load-kmods = true
#no-cgroups = false
#user = "root:video"
ldconfig = "@/sbin/ldconfig.real"

[nvidia-container-runtime]
#debug = "/var/log/nvidia-container-runtime.log"
EOF
}

install_k0s() {
  if ! _command_exists k0s; then
    bold "k0s (portable Kubernetes runtime) not found in the node. Installing k0s $K0S_VERSION"
    curl -sSLf https://get.k0s.sh | sudo K0S_VERSION="$K0S_VERSION" sh
  fi
}

ensure_no_existing_k0s_running() {
  bold "Checking if there is existing k0s running"
  if sudo $K0S_EXECUTABLE status 2&> /dev/null; then
    existing_k0s_role="$(k0s status | grep "Role" | awk -F': ' '{print $2}')"
    abort "ERROR: k0s is already running as $existing_k0s_role.\nIf you want to reset the cluster, run 'sudo k0s stop && sudo k0s reset' before retrying the script."
  fi
}

install_k0s_controller() {
  bold "Installing k0scontroller.service on systemd"
  no_taint_option=""
  [[ "$K0S_TAINT_CONTROLLER" == "false" ]] && no_taint_option="--no-taints"

  sudo $K0S_EXECUTABLE config create | sudo tee $K0S_CONFIG_PATH/k0s.yaml
  sudo sed -i -e 's/provider: kuberouter/provider: calico/g' $K0S_CONFIG_PATH/k0s.yaml

  sudo $K0S_EXECUTABLE install controller -c $K0S_CONFIG_PATH/k0s.yaml \
    ${no_taint_option:+"--no-taints"} \
    --enable-worker \
    --enable-cloud-provider \
    --enable-k0s-cloud-provider=true

  bold "Starting k0scontroller.service"
  sudo $K0S_EXECUTABLE start
}

install_k0s_worker() {
  bold "Installing k0sworker.service on systemd"

  if [ "$K0S_JOIN_TOKEN" == "" ]; then
    abort "ERROR: cluster join token is not set.\nPlease set --token option to join the cluster."
  fi
  echo "$K0S_JOIN_TOKEN" | sudo tee $K0S_CONFIG_PATH/token
  sudo $K0S_EXECUTABLE install worker \
    --token-file $K0S_CONFIG_PATH/token \
    --enable-cloud-provider

  bold "Starting k0sworker.service"
  sudo $K0S_EXECUTABLE start
}

run_k0s() {
  bold "Writing k0s cluster configuration to $K0S_CONFIG_PATH"
  sudo mkdir -p "$K0S_CONFIG_PATH"
  if [ "$K0S_ROLE" == "controller" ]; then
    install_k0s_controller
  elif [ "$K0S_ROLE" == "worker" ]; then
    install_k0s_worker
  fi
}

wait_for_k0s_daemon() {
  bold "Waiting for k0s $K0S_ROLE to be up and running"
  sleep 3
  count=0
  until sudo systemctl is-active --quiet "k0s$K0S_ROLE" || [[ $count -eq 10 ]]; do
    (( count++ ))
    echo -e "...\c"
    sleep 3
  done
  if [[ $count -eq 10 ]]; then
    sudo systemctl status "k0s$K0S_ROLE" --no-pager -l
    bold "ERROR: k0s $K0S_ROLE failed to start. Please check error logs using 'journalctl -xeu k0s$K0S_ROLE.service --no-pager'."
    bold "If the problem persists after retry, please reach out support@vessl.ai for technical support."
    abort ""
  fi
}

change_k0s_containerd_runtime_to_nvidia_container_runtime() {
  if [ ! -f /etc/k0s/containerd.toml ]; then
    bold "k0s containerd config file not found; skipping changing containerd runtime to nvidia-container-runtime."
    return
  fi
  if ! _command_exists nvidia-container-runtime; then
    bold "nvidia-container-runtime not found; skipping changing containerd runtime to nvidia-container-runtime."
    return
  fi

  cat <<EOT >> /etc/k0s/containerd.toml
[plugins."io.containerd.grpc.v1.cri".containerd.default_runtime]
  runtime_type = "io.containerd.runtime.v1.linux"
  runtime_engine = ""
  runtime_root = ""
  privileged_without_host_devices = false
  base_runtime_spec = ""
    [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime.options]
      Runtime = "nvidia-container-runtime"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvdia]
      runtime_type = "io.containerd.runtime.v1.linux"
      runtime_engine = ""
      runtime_root = ""
      privileged_without_host_devices = false
      base_runtime_spec = ""
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvdia.options]
          Runtime = "nvidia-container-runtime"
EOT
}

# -----------
# Main script
# -----------

ensure_hostname_lowercase
ensure_nvidia_gpu_dependencies
enforce_nvidia_device_visibility_to_volume_mounts
install_k0s
ensure_no_existing_k0s_running
run_k0s
wait_for_k0s_daemon
change_k0s_containerd_runtime_to_nvidia_container_runtime

# TODO: Verify containerd in k0s can run GPU container using `k0s ctr` command

bold "-------------------\nBootstrap complete!\n-------------------\n"
if [ "$K0S_ROLE" == "controller" ]; then
  k0s_token=$(sudo "$K0S_EXECUTABLE" token create --role=worker)
  bold "Node is configured as a control plane node."
  bold "To join other nodes to the cluster, run the following command on the worker node:"
  bold ""
  bold "  curl -sSLf https://install.dev.vssl.ai | sudo bash -s -- --role=worker --token='$k0s_token'"
  bold ""
  bold "To get Kubernetes admin's kubeconfig file, run the following command on the control plane node:"
  bold "  $K0S_EXECUTABLE kubeconfig admin"
  unset k0s_token
elif [ "$K0S_ROLE" == "worker" ]; then
  bold "Node is configured as a worker node and joined the cluster.\n"
fi

