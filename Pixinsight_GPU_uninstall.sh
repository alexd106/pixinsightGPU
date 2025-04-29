#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
CUDA_SHORT="11.8"
CUDNN_VERSION="8.9.4.25"
TENSORFLOW_VERSION="2.13.0"
PIXINSIGHT_DIR="/opt/PixInsight"

# === Helpers ===
info()    { echo -e "[INFO]    $*"; }
success() { echo -e "[SUCCESS] $*"; }
warn()    { echo -e "[WARN]    $*"; }
error()   { echo -e "[ERROR]   $*"; exit 1; }

# Ensure root
if [[ $EUID -ne 0 ]]; then
  info "Re-running with sudo..."
  exec sudo "$0" "$@"
fi

# === Uninstall Functions ===
uninstall_cuda() {
  info "Purging CUDA..."
  apt purge -y "*cuda*" "*cublas*" "*nvcc*"

  CUDA_DIR="/usr/local/cuda-${CUDA_SHORT}"
  if [ -d "$CUDA_DIR" ]; then
    read -p "Do you really want to delete the directory '$CUDA_DIR'? [y/N]: " confirm
    case "$confirm" in
      [yY][eE][sS]|[yY])
        rm -rf "$CUDA_DIR"
        info "Deleted directory $CUDA_DIR"
        ;;
      *)
        info "Skipped deletion of $CUDA_DIR"
        ;;
    esac
  else
    info "Directory $CUDA_DIR does not exist."
  fi

  ldconfig
  success "CUDA removed."
}

uninstall_cudnn() {
  info "Removing cuDNN..."
  
  # Remove cuDNN packages
  for pkg in $(dpkg -l | grep -i cudnn | awk '{print $2}'); do
    apt-get --purge remove -y "$pkg"
  done

  # Paths to cuDNN files
  CUDNN_HEADER="/usr/local/cuda-${CUDA_SHORT}/include/cudnn.h"
  CUDNN_LIBS="/usr/local/cuda-${CUDA_SHORT}/lib64/libcudnn*"

  # Confirm deletion
  echo "The following cuDNN files will be deleted:"
  echo "  $CUDNN_HEADER"
  echo "  $CUDNN_LIBS"
  read -p "Do you really want to delete these files? [y/N]: " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY])
      rm -f $CUDNN_HEADER $CUDNN_LIBS
      info "cuDNN files deleted."
      ;;
    *)
      info "Skipped deletion of cuDNN files."
      ;;
  esac

  ldconfig
  success "cuDNN removed."
}

uninstall_tensorflow() {
  info "Removing TensorFlow C API..."

  TENSORFLOW_LIB="/usr/local/lib/libtensorflow.so*"
  TENSORFLOW_INCLUDE_DIR="/usr/local/include/tensorflow"

  echo "The following TensorFlow files/directories will be deleted:"
  echo "  $TENSORFLOW_LIB"
  echo "  $TENSORFLOW_INCLUDE_DIR"
  read -p "Do you really want to delete these files? [y/N]: " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY])
      rm -f $TENSORFLOW_LIB
      rm -rf $TENSORFLOW_INCLUDE_DIR
      info "TensorFlow files deleted."
      ;;
    *)
      info "Skipped deletion of TensorFlow files."
      ;;
  esac

  ldconfig
  success "TensorFlow removed."
}

# === PixInsight TF cleanup/restore ===
cleanup_pixinsight_tf() {
  local libdir="$PIXINSIGHT_DIR/bin/lib"
  local backup="$libdir/backup_tf"
  info "Restoring PixInsight TensorFlow libraries from backup..."
  if [[ ! -d "$backup" ]]; then
    error "Backup directory not found: $backup"
  fi
  if [[ ! -d "$libdir" ]]; then
    error "PixInsight lib directory not found: $libdir"
  fi
  # Move backed-up files back
  shopt -s nullglob
  local files=("$backup"/libtensorflow*.so*)
  if (( ${#files[@]} == 0 )); then
    warn "No files to restore in $backup"
  else
    for f in "${files[@]}"; do
      mv -f "$f" "$libdir/"
    done
    success "Restored ${#files[@]} TensorFlow library files to $libdir"
  fi
}

# === Menu ===
PS3="Select action: "
options=(
  "Uninstall CUDA"
  "Uninstall cuDNN"
  "Uninstall TensorFlow"
  "Uninstall All"
  "Restore PixInsight TF libs"
  "Quit"
)
select opt in "${options[@]}"; do
  case $REPLY in
    1) uninstall_cuda ;; 
    2) uninstall_cudnn ;; 
    3) uninstall_tensorflow ;; 
    4) uninstall_cuda; uninstall_cudnn; uninstall_tensorflow ;; 
    5) cleanup_pixinsight_tf ;; 
    6) break ;; 
    *) warn "Invalid selection." ;; 
  esac
done

