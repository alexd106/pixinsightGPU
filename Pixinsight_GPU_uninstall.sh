```bash
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
  apt-get --purge remove -y "*cuda*" "*cublas*" "*nvcc*"
  rm -rf "/usr/local/cuda-${CUDA_SHORT}"
  ldconfig
  success "CUDA removed."
}

uninstall_cudnn() {
  info "Removing cuDNN..."
  for pkg in $(dpkg -l | grep -i cudnn | awk '{print $2}'); do
    apt-get --purge remove -y "$pkg"
  done
  rm -f "/usr/local/cuda-${CUDA_SHORT}/include/cudnn.h" "/usr/local/cuda-${CUDA_SHORT}/lib64/libcudnn*"
  ldconfig
  success "cuDNN removed."
}

uninstall_tensorflow() {
  info "Removing TensorFlow C API..."
  rm -f /usr/local/lib/libtensorflow.so* 
  rm -rf /usr/local/include/tensorflow
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
  # Optionally remove backup directory if empty
  rmdir --ignore-fail-on-non-empty "$backup" 2>/dev/null || true
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
```

