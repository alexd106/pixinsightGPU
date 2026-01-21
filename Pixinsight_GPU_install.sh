#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# GPU stack installer for PixInsight / StarXTerminator (CUDA + cuDNN + TF C API)
# - Adds robust handling for cuDNN SONAME symlinks (fixes ldconfig warnings)
# - Uses CUDA libdir autodetection (targets/.../lib vs lib64)
# - Makes ld.so.conf.d entry consistent with the CUDA layout
# - Fixes cuDNN verification paths to match CUDA layouts
# ==============================================================================

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

TEMP_OPTS=$(getopt -o dh --long dry-run,help -n "$0" -- "$@") || usage
eval set -- "$TEMP_OPTS"
while true; do
  case "${1:-}" in
    -d|--dry-run) dry_run=true; shift ;;
    -h|--help)    usage ;;
    --) shift; break ;;
    *) usage ;;
  esac
done

# if not root, re-exec preserving flags
if [[ ${EUID:-0} -ne 0 ]]; then
  exec sudo "$0" "${orig_args[@]}"
fi

# === COLOR SETUP ===
if tput colors &>/dev/null && [ "$(tput colors)" -ge 8 ]; then
  RED="\033[31m"; YELLOW="\033[33m"; GREEN="\033[32m"; NC="\033[0m"
else
  RED=""; YELLOW=""; GREEN=""; NC=""
fi

# === LOGGING ===
log_info()  { printf "%b[INFO] %s%b\n"  "${GREEN}" "$*" "${NC}"; }
log_warn()  { printf "%b[WARN] %s%b\n"  "${YELLOW}" "$*" "${NC}"; }
log_error() { printf "%b[ERROR] %s%b\n" "${RED}" "$*" "${NC}" >&2; }

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

readonly USER_HOME="$(getent passwd "${SUDO_USER:-$(logname)}" | cut -d: -f6)"
readonly DOWNLOAD_DIR="$USER_HOME/Downloads"

# Use a versioned ld.so.conf.d entry to avoid clobbering other CUDA installs
readonly CUDA_LDSO_CONF="/etc/ld.so.conf.d/cuda-${CUDA_SHORT/./-}.conf"

# Markers for bashrc additions (so we can idempotently manage)
readonly BASHRC_MARK_BEGIN="# >>> PIXINSIGHT_GPU_SETUP BEGIN >>>"
readonly BASHRC_MARK_END="# <<< PIXINSIGHT_GPU_SETUP END <<<"

# === HELPERS FOR PATH DETECTION / CONFIG ===

cuda_root() {
  printf "/usr/local/cuda-%s" "$CUDA_SHORT"
}

# Prefer the "targets" libdir if present; fallback to lib64 if not.
cuda_libdir() {
  local root; root="$(cuda_root)"
  if [[ -d "$root/targets/x86_64-linux/lib" ]]; then
    printf "%s\n" "$root/targets/x86_64-linux/lib"
  elif [[ -d "$root/lib64" ]]; then
    printf "%s\n" "$root/lib64"
  else
    # last resort: some installs may have lib
    if [[ -d "$root/lib" ]]; then
      printf "%s\n" "$root/lib"
    else
      printf "%s\n" "$root/targets/x86_64-linux/lib"
    fi
  fi
}

ensure_ldso_conf_for_cuda() {
  local libdir; libdir="$(cuda_libdir)"
  log_info "Ensuring dynamic linker config for CUDA points to: $libdir"
  if [[ -f "$CUDA_LDSO_CONF" ]]; then
    # If file exists but differs, back it up and replace.
    if ! grep -Fxq "$libdir" "$CUDA_LDSO_CONF"; then
      local backup="${CUDA_LDSO_CONF}.$(date +%F-%H%M%S).bak"
      log_warn "Existing $CUDA_LDSO_CONF does not match detected libdir; backing up to $backup"
      run_cmd cp -a "$CUDA_LDSO_CONF" "$backup"
      run_cmd bash -c "printf '%s\n' '$libdir' > '$CUDA_LDSO_CONF'"
    else
      log_info "$CUDA_LDSO_CONF already contains the correct path."
    fi
  else
    run_cmd bash -c "printf '%s\n' '$libdir' > '$CUDA_LDSO_CONF'"
  fi
}

ensure_bashrc_block() {
  local root; root="$(cuda_root)"
  local libdir; libdir="$(cuda_libdir)"
  local bashrc="$USER_HOME/.bashrc"

  # Build the block using detected paths
  local block
  block="$BASHRC_MARK_BEGIN
# CUDA toolkit (for nvcc etc.)
export PATH=$root/bin:\$PATH
# CUDA/cuDNN runtime libs
export LD_LIBRARY_PATH=$libdir:\$LD_LIBRARY_PATH
# TensorFlow GPU memory growth (optional)
export TF_FORCE_GPU_ALLOW_GROWTH=\"true\"
$BASHRC_MARK_END"

  # If block exists, do nothing; otherwise append.
  if [[ -f "$bashrc" ]] && grep -Fq "$BASHRC_MARK_BEGIN" "$bashrc"; then
    log_info "GPU environment block already present in $bashrc"
  else
    log_info "Appending GPU environment block to $bashrc"
    run_cmd bash -c "printf '\n%s\n' \"$block\" >> '$bashrc'"
  fi
}

# === cuDNN SYMLINK NORMALIZATION (fixes ldconfig WARNINGS) ===
normalize_cudnn_symlinks() {
  local libdir; libdir="$(cuda_libdir)"
  log_info "Normalizing cuDNN SONAME symlinks in: $libdir"

  if [[ ! -d "$libdir" ]]; then
    log_error "CUDA library directory not found: $libdir"
    return 1
  fi

  # Identify versioned cuDNN libs matching the installed cuDNN in this directory.
  # target libcudnn*.so.8.* (e.g., .so.8.9.4). For each, ensure libcudnn*.so.8 is a symlink to it.
  shopt -s nullglob
  local versioned=( "$libdir"/libcudnn*.so.8.* )
  shopt -u nullglob

  if [[ ${#versioned[@]} -eq 0 ]]; then
    log_warn "No versioned cuDNN libraries found as libcudnn*.so.8.* in $libdir"
    log_warn "Skipping cuDNN symlink normalization."
    return 0
  fi

  local backup_dir="$libdir/backup-so8-$(date +%F)"
  local did_backup=false

  for target in "${versioned[@]}"; do
    local base
    base="$(basename "$target")"              # e.g. libcudnn_ops_infer.so.8.9.4
    local soname="${base%%.8.*}.so.8"         # -> libcudnn_ops_infer.so.8
    local soname_path="$libdir/$soname"

    # If soname exists and is a regular file, back it up and replace with symlink.
    if [[ -e "$soname_path" && ! -L "$soname_path" ]]; then
      if ! $did_backup; then
        run_cmd mkdir -p "$backup_dir"
        did_backup=true
      fi
      log_warn "Found non-symlink SONAME file: $soname_path; moving to $backup_dir"
      run_cmd mv -v "$soname_path" "$backup_dir/"
    fi

    # If symlink exists but points elsewhere, replace it.
    if [[ -L "$soname_path" ]]; then
      local link_target
      link_target="$(readlink "$soname_path" || true)"
      if [[ "$link_target" != "$base" ]]; then
        log_warn "SONAME symlink $soname_path points to $link_target; updating to $base"
        run_cmd rm -f "$soname_path"
        run_cmd ln -sv "$base" "$soname_path"
      fi
    else
      # Create the symlink if missing.
      if [[ ! -e "$soname_path" ]]; then
        run_cmd ln -sv "$base" "$soname_path"
      fi
    fi
  done

  # Also ensure libcudnn.so.8 chain is sane if libcudnn.so.8.<x> exists.
  if [[ -f "$libdir/libcudnn.so.8.9.4" ]]; then
    if [[ -e "$libdir/libcudnn.so.8" && ! -L "$libdir/libcudnn.so.8" ]]; then
      if ! $did_backup; then
        run_cmd mkdir -p "$backup_dir"
        did_backup=true
      fi
      log_warn "Found non-symlink libcudnn.so.8; backing up"
      run_cmd mv -v "$libdir/libcudnn.so.8" "$backup_dir/"
      run_cmd ln -sv "libcudnn.so.8.9.4" "$libdir/libcudnn.so.8"
    elif [[ ! -e "$libdir/libcudnn.so.8" ]]; then
      run_cmd ln -sv "libcudnn.so.8.9.4" "$libdir/libcudnn.so.8"
    fi
    if [[ ! -e "$libdir/libcudnn.so" ]]; then
      run_cmd ln -sv "libcudnn.so.8" "$libdir/libcudnn.so"
    fi
  fi

  log_info "cuDNN symlink normalization complete."
  return 0
}

# === CHECK & VERIFY FUNCTIONS ===

check_nvidia_gpu() {
  log_info "Checking for NVIDIA GPU..."
  local gpu_info
  gpu_info="$(lspci | grep -i nvidia || true)"
  if [[ -z "$gpu_info" ]]; then
    log_error "No NVIDIA GPU detected."
    return 1
  fi
  log_info "NVIDIA GPU detected: $gpu_info"
}

check_nvidia_driver() {
  log_info "Checking NVIDIA driver..."
  if lsmod | grep -i nouveau &>/dev/null; then
    log_error "Nouveau driver active—please blacklist it."
    return 1
  fi
  if ! command -v nvidia-smi &>/dev/null; then
    log_error "nvidia-smi not found; install driver >= $REQUIRED_DRIVER_VERSION"
    return 1
  fi
  local inst_v
  inst_v="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
  if [[ "$inst_v" != "$REQUIRED_DRIVER_VERSION"* ]]; then
    log_warn "Installed driver $inst_v; recommended >= $REQUIRED_DRIVER_VERSION"
    confirm "Continue with driver $inst_v?" || return 1
  else
    log_info "Compatible driver $inst_v"
  fi
}

check_prerequisites() {
  log_info "Checking prerequisites..."
  local missing=()
  for pkg in build-essential wget curl binutils; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok"; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Missing: ${missing[*]}"
    if confirm "Install missing packages?"; then
      run_cmd apt update
      run_cmd apt install -y "${missing[@]}"
      log_info "Prerequisite packages installed."
    else
      log_warn "Skipping prerequisite installation."
    fi
  else
    log_info "All prerequisites present"
  fi
}

verify_cuda_installation() {
  log_info "Verifying CUDA installation..."
  local root; root="$(cuda_root)"
  if [[ -d "$root" && -x "$root/bin/nvcc" ]]; then
    local nvcc_ver
    nvcc_ver="$("$root/bin/nvcc" --version | grep "release" || true)"
    log_info "CUDA found: ${nvcc_ver:-"(nvcc present)"}"
  else
    log_error "CUDA not properly installed or nvcc missing at $root/bin/nvcc"
    return 1
  fi
}

verify_cudnn_installation() {
  log_info "Verifying cuDNN installation..."
  local root; root="$(cuda_root)"
  local libdir; libdir="$(cuda_libdir)"
  local header="$root/include/cudnn.h"

  # libcudnn.so might be in libdir; check both libcudnn.so and libcudnn.so.8
  if [[ -f "$header" ]] && ([[ -e "$libdir/libcudnn.so" ]] || [[ -e "$libdir/libcudnn.so.8" ]]); then
    log_info "cuDNN header and library present (header: $header, libdir: $libdir)"
  else
    log_error "cuDNN header or library missing (expected header: $header, libdir: $libdir)"
    return 1
  fi
}

verify_tf_installation() {
  log_info "Verifying TensorFlow C API installation..."
  if compgen -G "/usr/local/lib/libtensorflow.so.*" >/dev/null; then
    log_info "TensorFlow C API libraries found:"
    ls -l /usr/local/lib/libtensorflow.so.* | sed 's/^/  /'
  else
    log_error "TensorFlow C API libraries not found in /usr/local/lib"
    return 1
  fi
}

verify_pixinsight() {
  log_info "Verifying PixInsight installation..."
  if [[ ! -d "$PIXINSIGHT_DIR" ]]; then
    log_error "PixInsight directory not found at $PIXINSIGHT_DIR"
    return 1
  fi
  if [[ ! -x "$PIXINSIGHT_BIN" ]]; then
    log_error "PixInsight executable missing or not executable at $PIXINSIGHT_BIN"
    return 1
  fi
  log_info "PixInsight install found"

  if ls "$PIXINSIGHT_DIR/bin/lib/libtensorflow"* &>/dev/null; then
    log_warn "PixInsight contains its own TensorFlow libs which may conflict with system TF C API"
  else
    log_info "No conflicting PixInsight TensorFlow libraries detected"
  fi
}

# === INSTALL FUNCTIONS ===

install_cuda() {
  log_info "=== CUDA $CUDA_VERSION INSTALL START ==="
  confirm "Install CUDA $CUDA_VERSION?" || { log_warn "CUDA install aborted by user."; return 0; }

  run_cmd mkdir -p "$DOWNLOAD_DIR"
  cd "$DOWNLOAD_DIR"

  local inst="cuda_${CUDA_VERSION}_520.61.05_linux.run"
  local url="https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/$inst"

  log_info "Downloading CUDA installer: $inst"
  run_cmd wget -nc -c "$url"
  [[ -f "$inst" ]] || { log_error "Installer missing after download: $inst"; return 1; }

  run_cmd chmod +x "$inst"
  log_info "Running CUDA installer silently (toolkit only, no driver)"
  run_cmd "./$inst" --silent --toolkit --no-driver --no-opengl-libs --samples=0

  # Dynamic linker configuration: point to the actual CUDA libdir
  ensure_ldso_conf_for_cuda
  run_cmd ldconfig

  # .bashrc additions (idempotent)
  ensure_bashrc_block

  log_info "=== CUDA INSTALL COMPLETE ==="
}

install_cudnn() {
  log_info "=== cuDNN $CUDNN_VERSION INSTALL START ==="
  confirm "Install cuDNN $CUDNN_VERSION?" || { log_warn "cuDNN install aborted by user."; return 0; }

  local tarfile
  read -rp "Path to cuDNN .tar.xz: " tarfile
  [[ -f "$tarfile" ]] || { log_error "cuDNN archive not found at: $tarfile"; return 1; }

  log_info "Extracting cuDNN archive to /usr/local"
  run_cmd tar -xvf "$tarfile" -C /usr/local

  # Ensure linker config points to the actual CUDA libdir and rebuild cache
  ensure_ldso_conf_for_cuda

  # Normalize cuDNN SONAME symlinks to avoid ldconfig warnings
  normalize_cudnn_symlinks

  run_cmd ldconfig

  # .bashrc additions (idempotent)
  ensure_bashrc_block

  log_info "=== cuDNN INSTALL COMPLETE ==="
}

install_tf() {
  log_info "=== TensorFlow C API $TENSORFLOW_VERSION INSTALL START ==="
  confirm "Install TensorFlow C API $TENSORFLOW_VERSION?" || { log_warn "TensorFlow install aborted by user."; return 0; }

  run_cmd mkdir -p "$DOWNLOAD_DIR"
  cd "$DOWNLOAD_DIR"

  local tf="libtensorflow-gpu-linux-x86_64-${TENSORFLOW_VERSION}.tar.gz"
  local url="https://storage.googleapis.com/tensorflow/libtensorflow/$tf"

  log_info "Downloading TensorFlow archive: $tf"
  run_cmd wget -nc -c "$url"
  [[ -f "$tf" ]] || { log_error "TensorFlow archive missing after download: $tf"; return 1; }

  log_info "Extracting TensorFlow archive"
  run_cmd tar -xzf "$tf"

  # The TF C API tarball extracts into the current directory (include/ and lib/)
  [[ -d "include" && -d "lib" ]] || { log_error "Unexpected TensorFlow archive layout after extraction."; return 1; }

  log_info "Copying TensorFlow headers and libraries to /usr/local"
  run_cmd cp -r include/* /usr/local/include/
  run_cmd cp -r lib/* /usr/local/lib/

  run_cmd ldconfig

  # Keep bashrc block consistent
  ensure_bashrc_block

  log_info "=== TensorFlow INSTALL COMPLETE ==="
}

show_menu() {
  echo
  echo "GPU Installer Menu"
  echo "=================="
  echo "1) Check GPU & prerequisites"
  echo "2) Install CUDA"
  echo "3) Install cuDNN"
  echo "4) Install TensorFlow C API"
  echo "5) Normalize cuDNN symlinks (fix ldconfig warnings)"
  echo "6) Install All"
  echo "7) Verify installed components"
  echo "8) Quit"
}
show_menu

# === MAIN LOOP ===
while true; do
  read -rp "Enter choice [1-8]: " choice
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
      log_info "-- Selected: Normalize cuDNN symlinks --"
      ensure_ldso_conf_for_cuda
      normalize_cudnn_symlinks
      run_cmd ldconfig
      ;;
    6)
      log_info "-- Selected: Install All --"
      check_nvidia_gpu; check_prerequisites; check_nvidia_driver; verify_pixinsight
      install_cuda; install_cudnn; install_tf
      ;;
    7)
      log_info "-- Selected: Verify installed components --"
      verify_cuda_installation; verify_cudnn_installation; verify_tf_installation; verify_pixinsight
      ;;
    8)
      log_info "Exiting."
      break
      ;;
    *)
      log_error "Invalid selection: $choice"
      ;;
  esac
  show_menu
done