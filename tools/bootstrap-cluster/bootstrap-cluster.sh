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
K0S_CONTAINER_RUNTIME="containerd"
K0S_TAINT_CONTROLLER="false"
SKIP_NVIDIA_GPU_DEPENDENCIES="false"
K0S_NETWORK_PLUGIN="None"

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
  echo "--k0s-version=[VERSION]         k0s version to install (default: 1.25.12+k0s.0)"
  echo "--network-plugin=[PLUGIN]       kubelet network plugin to use. (default: None)"
  echo "--container-runtime=[RUNTIME]   container runtime to use. containerd or docker can be selected. (default: containerd)"
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
    --k0s-version*)
      K0S_VERSION="${1#*=}"
      shift
      ;;
    --network-plugin*)
      K0S_NETWORK_PLUGIN="${1#*=}"
      shift
      ;;
    --container-runtime*)
      K0S_CONTAINER_RUNTIME="${1#*=}"
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

# Validate Container Runtime
if [ "$K0S_CONTAINER_RUNTIME" != "containerd" ] && [ "$K0S_CONTAINER_RUNTIME" != "docker" ]; then
  printf "ERROR: unexpected container runtime: %s\n\n" "$K0S_CONTAINER_RUNTIME"
  print_help
  exit 1
fi

if [ "$K0S_NETWORK_PLUGIN" != "None" ] && [ "$K0S_NETWORK_PLUGIN" != "cni" ]; then
  printf "ERROR: unexpected network plugin: %s\n\n" "$K0S_NETWORK_PLUGIN"
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
  if [ "$SKIP_NVIDIA_GPU_DEPENDENCIES" = true ] ; then
    bold "\nWARNING: NVIDIA depencency missing. (Running with --skip-nvidia-gpu-dependencies; resuming the script)\n$*"
  else
    bold "\nERROR: NVIDIA depencency missing.\n$*"
    abort ""
  fi
}

_install_dependency() {
  # ex. _install_dependency curl
  # ex. _install_dependency "iscsi dependency" open-iscsi iscsi-initiator-utils
  local dependency_name=$1
  local apt_dependency_name=${2:-$1}
  local yum_dependency_name=${3:-$1}

  bold "Installing ${dependency_name}"
  if [ "$(_detect_os)" = "ubuntu" ]; then
    sudo apt-get install -y "${apt_dependency_name}"
  elif [ "$(_detect_os)" = "centos" ]; then
    sudo yum install -y "${yum_dependency_name}"
  fi
}

# ----------
# Main logic
# ----------

ensure_lshw_command() {
  bold "Checking if lshw command exists..."
  if ! _command_exists lshw; then
    _install_dependency lshw
  fi
}

ensure_hostname_lowercase() {
  bold "Checking if hostname is lowercase..."
  current_hostname=$(hostname)
  if [ "$current_hostname" != "${current_hostname,,}" ]; then
    abort "Machine's hostname '$(hostname)' contains uppercase characters.\nPlease set hostname to lowercase to make k8s cluster working:\n  sudo hostnamectl set-hostname \"$(hostname | tr '[:upper:]' '[:lower:]')\""
  fi
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
  if ! (lspci | grep NVIDIA); then
    echo "NVIDIA GPU not found in the system; skipping NVIDIA GPU dependencies check."
    return
  fi

  # Check if nvidia-driver has been installed
  if ! _command_exists nvidia-smi; then
    _print_nvidia_dependency_error "NVIDIA driver not found. Please install NVIDIA driver first."
  fi

  if ! _command_exists nvcc; then
    _print_nvidia_dependency_error "nvidia-cuda-toolkit not found.\nRun following command to install nvidia-cuda-toolkit and bootstrap again:\n  sudo apt-get install -y nvidia-cuda-toolkit"
  fi

  if ! _command_exists nvidia-container-toolkit; then
    # shellcheck disable=SC1091
    nvidia_toolkit_command="
  distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID) \\
    && curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add - \\
    && curl -s -L https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
    # shellcheck disable=SC1091
    if [ "$(_detect_os)" = "centos" ]; then
      nvidia_toolkit_command="
  distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID) \\
    && curl -s -L https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
  sudo dnf clean expire-cache && sudo dnf install -y nvidia-container-toolkit"
    fi
    _print_nvidia_dependency_error "nvidia-container-toolkit not found.\nRun following command to install nvidia-container-toolkit:\n$nvidia_toolkit_command"
  fi

  # Check if the instance has multiple GPUs of specified models and install nvidia-fabricmanager
  models=("A100" "H100" "V100" "H800" "A800")

  install_nvidia_fabricmanager=false
  for model in "${models[@]}"; do
    gpu_count=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader,nounits | grep -c "$model" || true)
    if [ "$gpu_count" -gt 1 ]; then
      install_nvidia_fabricmanager=true
      break
    fi
  done

  if $install_nvidia_fabricmanager; then
    bold "Detected multiple GPUs of specified models. Initiating nvidia-fabricmanager installation..."

    # Check if nvidia-fabricmanager is not already active
    if ! systemctl --all | grep -q nvidia-fabricmanager; then
      nvidia_driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits | head -n 1 | cut -d '.' -f 1)

      # Check the OS and install the appropriate package
      _install_dependency cuda-drivers-fabricmanager-"$nvidia_driver_version"
    fi

    # Enable and start nvidia-fabricmanager
    (sudo systemctl enable nvidia-fabricmanager && sudo systemctl start nvidia-fabricmanager) || true
    if systemctl is-active nvidia-fabricmanager; then
      echo "nvidia-fabricmanager is active."
    elif grep -q NOTHING_TO_DO <(systemctl status nvidia-fabricmanager 2>&1); then
      echo "nvidia-fabricmanager is not required. Skipping fabricmanager installation..."
    else
      _print_nvidia_dependency_error "nvidia-fabricmanager is not active. This might be due to a CUDA minor version conflict. For example, if you encounter the error 'Failed to initialize NVML: Driver/library version mismatch' when running nvidia-smi, consider rebooting your instance."
    fi
  fi
}

ensure_nvidia_device_volume_mounts() {
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
log-level = "info"

# Specify the runtimes to consider. This list is processed in order and the PATH
# searched for matching executables unless the entry is an absolute path.
runtimes = [
    "runc",
]
EOF
}

install_k0s() {
  bold "Checking if k0s command exists..."
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

run_k0s_controller_daemon() {
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

run_k0s_worker_daemon() {
  bold "Installing k0sworker.service on systemd"

  if [ "$K0S_JOIN_TOKEN" == "" ]; then
    abort "ERROR: cluster join token is not set.\nPlease set --token option to join the cluster."
  fi
  echo "$K0S_JOIN_TOKEN" | sudo tee $K0S_CONFIG_PATH/token

  # Check the container runtime and set CRI_SOCKET_OPTION accordingly
  if [ "$K0S_CONTAINER_RUNTIME" == "docker" ]; then
    CRI_SOCKET_OPTION="--cri-socket docker:unix:///var/run/docker.sock"
  else
    CRI_SOCKET_OPTION=""
  fi

  KUBELET_EXTRA_ARGS="--kubelet-extra-args=--cgroup-driver=systemd"
  if [ "$K0S_NETWORK_PLUGIN" != "None" ]; then
    KUBELET_EXTRA_ARGS="$KUBELET_EXTRA_ARGS --network-plugin=$K0S_NETWORK_PLUGIN"
  fi

  sudo $K0S_EXECUTABLE install worker \
    --token-file $K0S_CONFIG_PATH/token \
    $CRI_SOCKET_OPTION \
    --enable-cloud-provider \
   $KUBELET_EXTRA_ARGS

  bold "Starting k0sworker.service"
  sudo $K0S_EXECUTABLE start
}

check_node_disk_size() {
  disk_size=$(df -h | awk '/ \/$/ { print $4 }')

  # Extract the numeric value and unit
  numeric_value=$(echo "$disk_size" | sed 's/[A-Za-z]//g')
  unit=$(echo "$disk_size" | sed 's/[0-9.]//g')

  # Convert units to GiB
  case "$unit" in
      T) numeric_value=$(awk "BEGIN { print $numeric_value * 1024 }") ;;
      M) numeric_value=$(awk "BEGIN { print $numeric_value / 1024 }") ;;
      K) numeric_value=$(awk "BEGIN { print $numeric_value / 1024 / 1024 }") ;;
  esac

  if [ "$(echo "$numeric_value < 100" | bc -l)" -eq 1 ]; then
      bold "Warning: Node does not have enough disk space on the root(/) volume. Please consider expanding your disk size."
  else
      bold "Root volume space available: ${disk_size}"
  fi
}

run_k0s_daemon() {
  bold "Writing k0s cluster configuration to $K0S_CONFIG_PATH"
  sudo mkdir -p "$K0S_CONFIG_PATH"
  if [ "$K0S_ROLE" == "controller" ]; then
    run_k0s_controller_daemon
  elif [ "$K0S_ROLE" == "worker" ]; then
    run_k0s_worker_daemon
  else
    abort "ERROR: k0s role must be either 'controller' or 'worker'."
  fi

  check_node_disk_size
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

ensure_k0s_nvidia_container_runtime_containerd() {
  local config_file="/etc/k0s/containerd.toml"

  if [ ! -f "$config_file" ]; then
    bold "k0s containerd config file not found; skipping changing containerd runtime to nvidia-container-runtime."
    return
  fi

  if ! _command_exists nvidia-container-runtime; then
    bold "nvidia-container-runtime not found; skipping changing containerd runtime to nvidia-container-runtime."
    return
  fi

  cat <<EOT > "$config_file"
# This is a placeholder configuration for k0s managed containerD.
# If you wish to customize the config replace this file with your custom configuration.
# For reference see https://github.com/containerd/containerd/blob/main/docs/man/containerd-config.toml.5.md
version = 2
[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "nvidia"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
    privileged_without_host_devices = false
    runtime_engine = ""
    runtime_root = ""
    runtime_type = "io.containerd.runc.v2"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
      BinaryName = "/usr/bin/nvidia-container-runtime"
EOT
}

ensure_k0s_nvidia_container_runtime_docker() {
  local docker_config_file="/etc/docker/daemon.json"

  if ! _command_exists nvidia-container-runtime; then
    bold "nvidia-container-runtime not found; skipping changing docker runtime to nvidia-container-runtime."
    return
  fi

  if [ -f "$docker_config_file" ]; then
    bold "Found existing $docker_config_file, backing up to $docker_config_file.bak"
    sudo mv -v "$docker_config_file" "$docker_config_file.bak"
  fi

  cat <<-EOT | sudo tee "$docker_config_file"
{
    "exec-opts": [
        "native.cgroupdriver=systemd"
    ],
    "default-runtime": "nvidia",
    "live-restore": true,
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOT
  sudo systemctl restart docker
}

ensure_k0s_nvidia_container_runtime() {
  if [ "$K0S_CONTAINER_RUNTIME" = "containerd" ]; then
    ensure_k0s_nvidia_container_runtime_containerd
  elif [ "$K0S_CONTAINER_RUNTIME" = "docker" ]; then
    ensure_k0s_nvidia_container_runtime_docker
  fi
}

print_bootstrap_complete_instruction() {
  bold "-------------------\nBootstrap complete!\n-------------------\n"
  if [ "$K0S_ROLE" == "controller" ]; then
    k0s_token=$(sudo "$K0S_EXECUTABLE" token create --role=worker)
    bold "Node is configured as a control plane node."
    bold "To join other nodes to the cluster, run the following command on the worker node:"
    bold ""
    bold "  curl -sSLf https://install.vessl.ai/bootstrap-cluster/bootstrap-cluster.sh | sudo bash -s -- --role=worker --token='$k0s_token'"
    bold ""
    bold "To get Kubernetes admin's kubeconfig file, run the following command on the control plane node:"
    bold "  $K0S_EXECUTABLE kubeconfig admin"
    unset k0s_token
  elif [ "$K0S_ROLE" == "worker" ]; then
    bold "Node is configured as a worker node and joined the cluster.\n"
  fi
}

ensure_longhorn_dependencies() {
  bold "Checking longhorn dependencies..."
  if ! _command_exists iscsiadm; then
    _install_dependency "iscsi client" open-iscsi iscsi-initiator-utils
  fi
}

ensure_utilities() {
  bold "Checking for utilities..."
  # install sudo without sudo
  if ! _command_exists sudo; then
    bold "Installing sudo"
    if [ "$(_detect_os)" = "ubuntu" ]; then
      apt-get install -y sudo
    elif [ "$(_detect_os)" = "centos" ]; then
      yum install -y sudo
    fi
  fi
  if ! _command_exists curl; then
    _install_dependency "curl"
  fi
}

# -----------
# Main script
# -----------

ensure_utilities
ensure_lshw_command
ensure_hostname_lowercase
ensure_nvidia_gpu_dependencies
ensure_nvidia_device_volume_mounts
ensure_longhorn_dependencies
install_k0s
ensure_no_existing_k0s_running
run_k0s_daemon
wait_for_k0s_daemon
ensure_k0s_nvidia_container_runtime
# TODO: Verify containerd in k0s can run GPU container using `k0s ctr` command
print_bootstrap_complete_instruction
