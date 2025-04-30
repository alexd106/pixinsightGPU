#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
CUDA_SHORT="11.8"
CUDNN_VERSION="8.9.4.25"
TENSORFLOW_VERSION="2.13.0"
PIXINSIGHT_DIR="/opt/PixInsight"
USER_HOME=$(getent passwd "${SUDO_USER:-$(logname)}" | cut -d: -f6)

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

# === Check Installation Functions ===
# Check if CUDA is installed
check_cuda_installed() {
    if [ -d "/usr/local/cuda-${CUDA_SHORT}" ]; then
        return 0
    else
        return 1
    fi
}

# Check if cuDNN is installed
check_cudnn_installed() {
    if [ -f "/usr/local/cuda-${CUDA_SHORT}/include/cudnn.h" ]; then
        return 0
    else
        return 1
    fi
}
# === Uninstall Functions ===
uninstall_cuda() {
    # Detect CUDA
    if ! check_cuda_installed; then
        echo "⚠️  No CUDA installation detected. Nothing to do."
        return 0
    fi

    # Prompt for confirmation
    read -rp "🗑️  Are you sure you want to uninstall CUDA? [y/N] " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted by user."; return 1 ;;
    esac

    # If a runfile uninstaller exists, use it
    if [ -x "/usr/local/cuda/bin/cuda-uninstaller" ]; then
        echo "🔧 Running CUDA uninstaller..."
        sudo /usr/local/cuda/bin/cuda-uninstaller --silent || {
            echo "❌ CUDA uninstaller failed"; exit 1; }
        echo "✅ Runfile-based CUDA uninstalled." 
    else
        # fallback to version-specific Perl uninstaller
        for d in /usr/local/cuda-*; do
            if [ -x "$d/bin/uninstall_cuda_${d##*/cuda-}.pl" ]; then
                echo "🔧 Running uninstall_cuda_${d##*/cuda-}.pl..."
                sudo "$d/bin/uninstall_cuda_${d##*/cuda-}.pl" || {
                    echo "❌ Uninstaller script failed for $d"; }
            fi
        done
    fi

    # Purge packages if installed via package manager
    if command -v apt &>/dev/null; then
        echo "🔧 Purging apt CUDA packages..."
        sudo apt purge -y "cuda*" "cublas*" || true
        sudo apt autoremove -y || true
        sudo apt autoclean -y || true
        echo "✅ Apt packages purged."
    elif command -v dnf &>/dev/null; then
        echo "🔧 Removing dnf CUDA packages..."
        sudo dnf remove -y cuda* || true
        echo "✅ DNF packages removed."
    fi

    # Remove leftover directories
    echo "🧹 Removing /usr/local/cuda* directories..."
    sudo rm -rf /usr/local/cuda* || true

    # Clean up environment hooks
    echo "🛠️  Cleaning up environment variables in ~/.bashrc..."
    sed -i '/\/usr\/local\/cuda/d' $USER_HOME/.bashrc || true

    echo "🛠️  Removing CUDA ld.so.conf entries..."
    sudo rm -f /etc/ld.so.conf.d/cuda-*.conf || true
    sudo ldconfig

    echo "✅ CUDA has been completely uninstalled."
}

uninstall_cudnn() {
    # Detect cuDNN: header or library presence, or package listing
    if ! check_cudnn_installed && \
       ! ldconfig -p | grep -q libcudnn; then
        echo "⚠️  No cuDNN installation detected. Nothing to do."
        return 0
    fi

    # Prompt for confirmation
    read -rp "🗑️  Are you sure you want to uninstall cuDNN? [y/N] " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted by user."; return 1 ;;
    esac

    # Remove runfile-copied cuDNN files under CUDA
    if [[ -d "/usr/local/cuda-${CUDA_SHORT}" ]]; then
        echo "🔧 Removing cuDNN files from /usr/local/cuda-${CUDA_SHORT}..."
        sudo rm -f /usr/local/cuda-"${CUDA_SHORT}"/include/cudnn*.h \
                     /usr/local/cuda-"${CUDA_SHORT}"/lib64/libcudnn*
        echo "✅ Removed cuDNN headers and libs." 
    fi

    # Purge package-manager cuDNN packages
    if command -v apt &>/dev/null; then
        echo "🔧 Purging apt cuDNN packages..."
        sudo apt purge -y "cudnn*" || true
        sudo apt autoremove -y || true
        sudo apt autoclean -y || true
        echo "✅ Apt packages purged."
    elif command -v dnf &>/dev/null; then
        echo "🔧 Removing dnf cuDNN packages..."
        sudo dnf remove -y cudnn* || true
        echo "✅ DNF packages removed."
    fi

    # Clean up environment variable hooks
    echo "🛠️  Cleaning up ~/.bashrc..."
    sed -i '/cudnn/d' $USER_HOME/.bashrc || true

    echo "🛠️  Removing cuDNN ld.so.conf entries..."
    sudo rm -f /etc/ld.so.conf.d/*cudnn*.conf || true

    # Refresh linker cache
    sudo ldconfig

    echo "✅ cuDNN has been completely uninstalled."
}

uninstall_tensorflow() {
  echo "Removing TensorFlow C API..."

  TENSORFLOW_LIB="/usr/local/lib/libtensorflow.so*"
  TENSORFLOW_INCLUDE_DIR="/usr/local/include/tensorflow"

  echo "The following TensorFlow files/directories will be deleted:"
  echo "  $TENSORFLOW_LIB"
  echo "  $TENSORFLOW_INCLUDE_DIR"
  read -p "🗑️ Do you really want to delete these files? [y/N]: " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY])
      rm -f $TENSORFLOW_LIB
      rm -rf $TENSORFLOW_INCLUDE_DIR
      echo "✅ TensorFlow files deleted."
      ;;
    *)
      echo "⚠️ Skipped deletion of TensorFlow files."
      ;;
  esac

  sudo ldconfig
  echo "✅ TensorFlow has been uninstalled."
}

# === PixInsight TF cleanup/restore ===
cleanup_pixinsight_tf() {
  echo "Restoring PixInsight TensorFlow libraries from backup..."

  local libdir="$PIXINSIGHT_DIR/bin/lib"
  local backup="$libdir/backup_tf"

  if [[ ! -d "$backup" ]]; then
    echo "⚠️ Backup directory not found: $backup"
  fi
  if [[ ! -d "$libdir" ]]; then
    echo "⚠️ PixInsight lib directory not found: $libdir"
  fi
  
  # Move backed-up files back
  shopt -s nullglob
  local files=("$backup"/libtensorflow*.so*)
  if (( ${#files[@]} == 0 )); then
    echo "⚠️ No files to restore in $backup"
  else
    for f in "${files[@]}"; do
      mv -f "$f" "$libdir/"
    done
    
    echo "✅ Restored ${#files[@]} TensorFlow library files to $libdir"
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

