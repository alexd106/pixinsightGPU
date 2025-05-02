#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === USAGE & DRY-RUN SETUP ===
usage() {
  cat <<EOF
Usage: $0 [-d|--dry-run] [-h|--help]
  -d, --dry-run     Show what would be done, but make no changes
  -h, --help        Display this help message
EOF
  exit 0
}

dry_run=false
orig_args=("$@")
# parse CLI options
TEMP_OPTS=$(getopt -o dh --long dry-run,help -n "$0" -- "$@") || usage
eval set -- "$TEMP_OPTS"
while true; do
  case "$1" in
    -d|--dry-run) dry_run=true; shift ;;  
    -h|--help)    usage       ;;  
    --) shift; break         ;;  
    *) usage                ;;  
  esac
done

# if not root, re-exec preserving flags
if [[ $EUID -ne 0 ]]; then
  exec sudo "$0" "${orig_args[@]}"
fi

# === COLOR SETUP ===
if tput colors &>/dev/null && [ "$(tput colors)" -ge 8 ]; then
  RED="\033[31m"; YELLOW="\033[33m"; GREEN="\033[32m"; NC="\033[0m"
else
  RED=""; YELLOW=""; GREEN=""; NC=""
fi

# === LOGGING ===
log_info()  { printf "${GREEN}[INFO] %s${NC}\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN] %s${NC}\n" "$*"; }
log_error() { printf "${RED}[ERROR] %s${NC}\n" "$*" >&2; }

# === SAFETY & CONFIRMATION ===
confirm() {
  local prompt="${1:-Are you sure?}" ans
  while true; do
    read -rp "$prompt [y/N]: " ans
    case "$ans" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;  
      [Nn]|"")           return 1 ;;  
      *) echo "Please enter y or N." ;;  
    esac
  done
}

run_cmd() {
  if $dry_run; then
    log_info "[DRY-RUN] $*"
  else
    log_info "Running: $*"
    "$@"
  fi
}

# === DRY-RUN INDICATOR ===
if $dry_run; then
  log_warn "=== DRY-RUN MODE: no changes will be made ==="
fi

# === CONFIGURATION ===
readonly CUDA_VERSION="11.8.0"
readonly CUDA_SHORT="11.8"
readonly CUDNN_VERSION="8.9.4.25"
readonly TENSORFLOW_VERSION="2.14.0"
readonly REQUIRED_DRIVER_VERSION="550"
readonly PIXINSIGHT_DIR="/opt/PixInsight"
readonly PIXINSIGHT_BIN="/usr/bin/PixInsight"
readonly USER_HOME=$(getent passwd "${SUDO_USER:-$(logname)}" | cut -d: -f6)
readonly DOWNLOAD_DIR="$USER_HOME/Downloads"

APT_OPTS=(purge -y)
$dry_run && APT_OPTS=(--simulate "${APT_OPTS[@]}")

# === CHECK & VERIFY FUNCTIONS ===

# Check for NVIDIA GPU presence
check_nvidia_gpu() {
  log_info "🔧 Checking for NVIDIA GPU..."
  GPU_INFO=$(lspci | grep -i nvidia || true)
  if [ -z "$GPU_INFO" ]; then
    log_error "No NVIDIA GPU detected."
    return 1
  fi
  log_info "NVIDIA GPU detected: $GPU_INFO"
  return 0
}

# Check for NVIDIA driver and prompt if mismatch
check_nvidia_driver() {
  log_info "🔧 Checking NVIDIA driver..."
  if lsmod | grep -i nouveau &>/dev/null; then
    log_error "Nouveau driver active—please blacklist it."
    return 1
  fi
  if ! command -v nvidia-smi &>/dev/null; then
    log_error "nvidia-smi not found; install driver >= $REQUIRED_DRIVER_VERSION"
    return 1
  fi
  INST_V=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)
  if [[ "$INST_V" != "$REQUIRED_DRIVER_VERSION"* ]]; then
    log_warn "Installed driver $INST_V; recommended >= $REQUIRED_DRIVER_VERSION"
    if ! confirm "Continue with driver $INST_V?"; then
      return 1
    fi
  else
    log_info "Compatible driver $INST_V"
  fi
  return 0
}

# Check for and install missing prerequisites
check_prerequisites() {
  log_info "🔧 Checking prerequisites..."
  missing=()
  for pkg in build-essential wget curl binutils; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok"; then
      missing+=("$pkg")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log_warn "Missing: ${missing[*]}"
    if confirm "Install missing packages?"; then
      run_cmd sudo apt update || { log_error "apt update failed"; return 1; }
      run_cmd sudo apt install -y "${missing[@]}" || { log_error "apt install failed"; return 1; }
      log_info "Prerequisite packages installed."
    else
      log_warn "Skipping prerequisite installation."
    fi
  else
    log_info "All prerequisites present"
  fi
  return 0
}

# Verify CUDA installation by checking nvcc and directory
verify_cuda_installation() {
  log_info "🔧 Verifying CUDA installation..."
  if [ -d "/usr/local/cuda-${CUDA_SHORT}" ] && [ -x "/usr/local/cuda-${CUDA_SHORT}/bin/nvcc" ]; then
    NVCC_VER=$(/usr/local/cuda-${CUDA_SHORT}/bin/nvcc --version | grep "release")
    log_info "CUDA found: $NVCC_VER"
    return 0
  else
    log_error "CUDA not properly installed or nvcc missing."
    return 1
  fi
}

# Verify cuDNN by checking header and shared library presence
verify_cudnn_installation() {
  log_info "🔧 Verifying cuDNN installation..."
  header="/usr/local/cuda-${CUDA_SHORT}/include/cudnn.h"
  lib="/usr/local/cuda-${CUDA_SHORT}/lib64/libcudnn.so"
  if [ -f "$header" ] && [ -f "$lib" ]; then
    log_info "cuDNN header and library present"
    return 0
  else
    log_error "cuDNN header or library missing"
    return 1
  fi
}

# Verify TensorFlow C API by checking shared libs
verify_tf_installation() {
  log_info "🔧 Verifying TensorFlow C API installation..."
  tf_lib="/usr/local/lib/libtensorflow.so.${TENSORFLOW_VERSION}"
  if compgen -G "/usr/local/lib/libtensorflow.so.*" >/dev/null; then
    log_info "TensorFlow C API libraries found: $(ls /usr/local/lib/libtensorflow.so.*)"
    return 0
  else
    log_error "TensorFlow C API libraries not found"
    return 1
  fi
}

# Verify PixInsight installation and its TensorFlow libs
verify_pixinsight() {
  log_info "🔧 Verifying PixInsight installation..."
  if [ ! -d "$PIXINSIGHT_DIR" ]; then
    log_error "PixInsight directory not found at $PIXINSIGHT_DIR"
    return 1
  fi
  if [ ! -x "$PIXINSIGHT_BIN" ]; then
    log_error "PixInsight executable missing or not executable at $PIXINSIGHT_BIN"
    return 1
  fi
  log_info "PixInsight install found"
  # check for bundled TensorFlow libs
  if ls "$PIXINSIGHT_DIR/bin/lib/libtensorflow"* &>/dev/null; then
    log_warn "PixInsight contains its own TensorFlow libs which may conflict"
  else
    log_info "No conflicting PixInsight TensorFlow libraries"
  fi
  return 0
}

# === INSTALL FUNCTIONS ===
install_cuda() {
  log_info "=== CUDA $CUDA_VERSION INSTALL START ==="
  confirm "Install CUDA $CUDA_VERSION?" || { log_warn "CUDA install aborted by user."; return; }
  run_cmd mkdir -p "$DOWNLOAD_DIR"
  echo "$DOWNLOAD_DIR"
  cd "$DOWNLOAD_DIR"
  local inst="cuda_${CUDA_VERSION}_520.61.05_linux.run"
  local wget_inst="https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/$inst"
  log_info "Downloading CUDA installer: $inst"
  run_cmd wget -nc -c "$wget_inst" || { log_error "Failed to download $inst"; return 1; }
  pwd
  [ ! -f "$inst" ] && { log_error "Installer missing after download: $inst"; return 1; }
  run_cmd chmod +x "$inst"
  log_info "Running CUDA installer silently"
  run_cmd ./$inst --silent --toolkit --no-driver --no-opengl-libs --samples=0 || { log_error "CUDA installer failed"; return 1; }
  log_info "Configuring CUDA library path"
  run_cmd tee /etc/ld.so.conf.d/cuda.conf <<< "/usr/local/cuda-${CUDA_SHORT}/lib64" || { log_error "Failed to write ld.so config"; return 1; }
  run_cmd ldconfig || { log_error "ldconfig failed"; return 1; }
  # === Bashrc updates for CUDA ===
  if ! grep -q "/usr/local/cuda-${CUDA_SHORT}/bin" "$USER_HOME/.bashrc"; then
    run_cmd bash -c "echo 'export PATH=/usr/local/cuda-${CUDA_SHORT}/bin:\$PATH' >> $USER_HOME/.bashrc"
    log_info "Added CUDA bin to PATH in .bashrc"
  fi
  if ! grep -q "/usr/local/cuda-${CUDA_SHORT}/lib64" "$USER_HOME/.bashrc"; then
    run_cmd bash -c "echo 'export LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_SHORT}/lib64:\$LD_LIBRARY_PATH' >> $USER_HOME/.bashrc"
    log_info "Added CUDA lib64 to LD_LIBRARY_PATH in .bashrc"
  fi
  log_info "=== CUDA INSTALL COMPLETE ==="
}

install_cudnn() {
  log_info "=== cuDNN $CUDNN_VERSION INSTALL START ==="
  confirm "Install cuDNN $CUDNN_VERSION?" || { log_warn "cuDNN install aborted by user."; return; }
  read -rp "Path to cuDNN .tar.xz: " tarfile
  [ ! -f "$tarfile" ] && { log_error "cuDNN archive not found at $tarfile"; return 1; }
  log_info "Extracting cuDNN archive to /usr/local"
  run_cmd tar -xvf "$tarfile" -C /usr/local || { log_error "Failed to extract cuDNN archive"; return 1; }
  run_cmd ldconfig || { log_error "ldconfig failed"; return 1; }
  # === Bashrc updates for cuDNN ===
  if ! grep -q "CUDA" "$USER_HOME/.bashrc"; then
    log_info "Adding CUDA and cuDNN environment variables to .bashrc"
    run_cmd bash -c "cat >> $USER_HOME/.bashrc <<'EOF'\n# CUDA and cuDNN paths\nexport PATH=/usr/local/cuda-${CUDA_SHORT}/bin:\$PATH\nexport LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_SHORT}/lib64:\$LD_LIBRARY_PATH\nEOF"
  else
    log_info "CUDA/cuDNN environment variables already present in .bashrc"
  fi
  log_info "=== cuDNN INSTALL COMPLETE ==="
}

install_tf() {
  log_info "=== TensorFlow C API $TENSORFLOW_VERSION INSTALL START ==="
  confirm "Install TensorFlow C API $TENSORFLOW_VERSION?" || { log_warn "TensorFlow install aborted by user."; return; }
  cd "$DOWNLOAD_DIR"
  local tf="libtensorflow-gpu-linux-x86_64-${TENSORFLOW_VERSION}.tar.gz"
  local extract_tf="${tf%.tar.gz}"
  echo $tf
  echo $extract_tf
  log_info "Downloading TensorFlow archive: $tf"
  run_cmd wget -nc -c "https://storage.googleapis.com/tensorflow/libtensorflow/$tf" || { log_error "Failed to download $tf"; return 1; }
  [ ! -f "$tf" ] && { log_error "TensorFlow archive missing after download"; return 1; }
  log_info "Extracting TensorFlow archive"
  run_cmd tar -xzf "$tf" || { log_error "Failed to extract TensorFlow archive"; return 1; }
  [ ! -d $extract_tf ] && { log_error "Extracted TensorFlow directory missing"; return 1; }
  log_info "Copying TensorFlow headers and libraries"
  run_cmd cp -r $extract_tf/include/* /usr/local/include/ || { log_error "Failed to copy headers"; return 1; }
  run_cmd cp -r $extract_tf/lib/* /usr/local/lib/ || { log_error "Failed to copy libraries"; return 1; }
  run_cmd ldconfig || { log_error "ldconfig failed"; return 1; }
  # === Bashrc updates for TensorFlow ===
  if ! grep -q "TF_FORCE_GPU_ALLOW_GROWTH" "$USER_HOME/.bashrc"; then
    run_cmd bash -c "echo 'export TF_FORCE_GPU_ALLOW_GROWTH=\"true\"' >> $USER_HOME/.bashrc"
    log_info "Added TF_FORCE_GPU_ALLOW_GROWTH to ~/.bashrc"
  fi
  log_info "=== TensorFlow INSTALL COMPLETE ==="
}

# === MENU DISPLAY FUNCTION ===
show_menu() {
  echo
  echo "GPU Installer Menu"
  echo "=================="
  echo "1) Check GPU & prerequisites"
  echo "2) Install CUDA"
  echo "3) Install cuDNN"
  echo "4) Install TensorFlow C API"
  echo "5) Verify installed components"
  echo "6) Install All"
  echo "7) Quit"
}

# Initial menu display
show_menu

# === MAIN LOOP ===
while true; do
  read -rp "Enter choice [1-7]: " choice
  case "$choice" in
    1)
      log_info "-- Selected: Check GPU & prerequisites --"
      check_nvidia_gpu; check_prerequisites; check_nvidia_driver; verify_pixinsight
      ;;
    2)
      log_info "-- Selected: Install CUDA --"
      install_cuda
      ;;
    3)
      log_info "-- Selected: Install cuDNN --"
      install_cudnn
      ;;
    4)
      log_info "-- Selected: Install TensorFlow C API --"
      install_tf
      ;;
    5)
      log_info "-- Selected: Verify installed components --"
      verify_cuda_installation; verify_cudnn_installation; verify_tf_installation; verify_pixinsight
      ;;
    6)
      log_info "-- Selected: Install All --"
      check_nvidia_gpu; check_prerequisites; check_nvidia_driver; verify_pixinsight
      install_cuda; install_cudnn; install_tf
      ;;
    7)
      log_info "Exiting."
      break
      ;;
    *)
      log_error "Invalid selection: $choice"
      ;;
  esac
  show_menu
done
