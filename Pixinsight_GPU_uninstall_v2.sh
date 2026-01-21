#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# Uninstall / rollback script aligned with the installer script
# - Uses the same CUDA_SHORT / ld.so.conf.d filename convention
# - Uses the same bashrc marker block for clean, idempotent removal
# - Detects correct CUDA libdir (targets/.../lib vs lib64)
# - Removes ONLY the items this workflow likely created
# - Supports --dry-run
# - Includes a SAFE "Uninstall All" option (TF -> cuDNN -> CUDA)
# ==============================================================================

# === COLOR SETUP ===
if tput colors &>/dev/null && [ "$(tput colors)" -ge 8 ]; then
  RED="\033[31m"; YELLOW="\033[33m"; GREEN="\033[32m"; NC="\033[0m"
else
  RED=""; YELLOW=""; GREEN=""; NC=""
fi

# === LOGGING FUNCTIONS ===
log_info()  { printf "%b[INFO] %s%b\n"  "${GREEN}" "$*" "${NC}"; }
log_warn()  { printf "%b[WARN] %s%b\n"  "${YELLOW}" "$*" "${NC}"; }
log_error() { printf "%b[ERROR] %s%b\n" "${RED}" "$*" "${NC}" >&2; }

# === USAGE ===
usage() {
  cat <<EOF
Usage: $0 [-d|--dry-run] [-h|--help]
  -d, --dry-run     Show what would be done, but make no changes
  -h, --help        Display this help message
EOF
  exit 0
}

# === PARSE ARGS (before privilege escalation so we preserve flags) ===
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

# require root, re-exec preserving original args
if [[ ${EUID:-0} -ne 0 ]]; then
  exec sudo "$0" "${orig_args[@]}"
fi

# === SAFE PROMPTS & EXECUTION ===
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

# === CONFIGURATION (aligned with the UPDATED installer) ===
readonly CUDA_SHORT="11.8"
readonly CUDNN_VERSION="8.9.4.25"
readonly TENSORFLOW_VERSION="2.14.0"
readonly PIXINSIGHT_DIR="/opt/PixInsight"
readonly PIXINSIGHT_LAUNCHER="/opt/PixInsight/bin/PixInsight.sh"

readonly USER_HOME="$(getent passwd "${SUDO_USER:-$(logname)}" | cut -d: -f6)"
readonly CUDA_LDSO_CONF="/etc/ld.so.conf.d/cuda-${CUDA_SHORT/./-}.conf"

# Same bashrc markers as the updated installer
readonly BASHRC_MARK_BEGIN="# >>> PIXINSIGHT_GPU_SETUP BEGIN >>>"
readonly BASHRC_MARK_END="# <<< PIXINSIGHT_GPU_SETUP END <<<"

# === APT OPTIONS ===
declare -a APT_OPTS
$dry_run && APT_OPTS+=(--simulate)
APT_OPTS+=(purge -y)

# === PATH DETECTION HELPERS (same logic as installer) ===
cuda_root() {
  printf "/usr/local/cuda-%s" "$CUDA_SHORT"
}

cuda_libdir() {
  local root; root="$(cuda_root)"
  if [[ -d "$root/targets/x86_64-linux/lib" ]]; then
    printf "%s\n" "$root/targets/x86_64-linux/lib"
  elif [[ -d "$root/lib64" ]]; then
    printf "%s\n" "$root/lib64"
  elif [[ -d "$root/lib" ]]; then
    printf "%s\n" "$root/lib"
  else
    printf "%s\n" "$root/targets/x86_64-linux/lib"
  fi
}

# === CHECK FUNCTIONS ===
check_cuda_installed() {
  [[ -d "$(cuda_root)" ]]
}

check_cudnn_installed() {
  local root; root="$(cuda_root)"
  local libdir; libdir="$(cuda_libdir)"
  [[ -f "$root/include/cudnn.h" ]] || [[ -e "$libdir/libcudnn.so" ]] || [[ -e "$libdir/libcudnn.so.8" ]]
}

check_tf_installed() {
  compgen -G "/usr/local/lib/libtensorflow.so*" >/dev/null
}

check_pixinsight_installed() {
  [[ -x "$PIXINSIGHT_LAUNCHER" ]]
}

# === BASHRC CLEANUP (aligned with marker-based installer) ===
remove_bashrc_block() {
  local bashrc="$USER_HOME/.bashrc"
  if [[ ! -f "$bashrc" ]]; then
    log_warn "No $bashrc found; skipping bashrc cleanup."
    return 0
  fi

  if grep -Fq "$BASHRC_MARK_BEGIN" "$bashrc"; then
    log_info "Removing GPU environment block from $bashrc"
    run_cmd sed -i "\#${BASHRC_MARK_BEGIN}#,\#${BASHRC_MARK_END}#d" "$bashrc"
  else
    log_info "No marker-based GPU block found in $bashrc"
  fi
}

# === UNINSTALL FUNCTIONS ===
uninstall_cuda() {
  local root; root="$(cuda_root)"
  if ! check_cuda_installed; then
    log_warn "No CUDA found at $root. Nothing to do."
    return 0
  fi

  confirm "Uninstall CUDA toolkit at $root and remove $CUDA_LDSO_CONF?" || {
    log_info "CUDA uninstall aborted"
    return 0
  }

  if [[ -x "$root/bin/cuda-uninstaller" ]]; then
    run_cmd "$root/bin/cuda-uninstaller" --silent || true
  fi

  if [[ -f "$CUDA_LDSO_CONF" ]]; then
    run_cmd rm -f "$CUDA_LDSO_CONF"
  else
    log_info "No $CUDA_LDSO_CONF found; skipping."
  fi

  if [[ -L /usr/local/cuda ]]; then
    local tgt
    tgt="$(readlink -f /usr/local/cuda || true)"
    if [[ "$tgt" == "$root" ]]; then
      run_cmd rm -f /usr/local/cuda
    else
      log_info "/usr/local/cuda points elsewhere ($tgt); leaving intact."
    fi
  fi

  run_cmd rm -rf "$root"

  run_cmd apt "${APT_OPTS[@]}" 'cuda*' 'libcublas*' 'libnpp*' 'libnvrtc*' || true
  run_cmd apt "${APT_OPTS[@]}" autoremove || true
  run_cmd apt "${APT_OPTS[@]}" autoclean || true

  remove_bashrc_block

  run_cmd ldconfig
  log_info "CUDA removal complete."
}

uninstall_cudnn() {
  if ! check_cudnn_installed && ! ldconfig -p | grep -q libcudnn; then
    log_warn "No cuDNN detected."
    return 0
  fi

  local root; root="$(cuda_root)"
  local libdir; libdir="$(cuda_libdir)"
  local inc="$root/include"

  confirm "Uninstall cuDNN from $inc and $libdir?" || {
    log_info "cuDNN uninstall aborted"
    return 0
  }

  if compgen -G "$inc"/cudnn*.h >/dev/null; then
    run_cmd rm -f "$inc"/cudnn*.h
  else
    log_info "No cuDNN headers found under $inc"
  fi

  if compgen -G "$libdir"/libcudnn* >/dev/null; then
    run_cmd rm -f "$libdir"/libcudnn*
  else
    log_info "No cuDNN libraries found under $libdir"
  fi

  if compgen -G "$libdir"/backup-so8-* >/dev/null; then
    if confirm "Remove cuDNN backup directories (backup-so8-*) under $libdir?"; then
      run_cmd rm -rf "$libdir"/backup-so8-*
    else
      log_info "Leaving backup-so8-* directories in place."
    fi
  fi

  run_cmd apt "${APT_OPTS[@]}" 'cudnn*' 'libcudnn*' || true
  run_cmd apt "${APT_OPTS[@]}" autoremove || true
  run_cmd apt "${APT_OPTS[@]}" autoclean || true

  run_cmd ldconfig
  log_info "cuDNN removal complete."
}

uninstall_tensorflow() {
  if ! check_tf_installed; then
    log_warn "No TensorFlow C API detected in /usr/local/lib."
    return 0
  fi

  confirm "Delete TensorFlow C API files from /usr/local (include + libtensorflow.so*)?" || {
    log_info "TensorFlow uninstall skipped"
    return 0
  }

  if compgen -G "/usr/local/lib/libtensorflow.so*" >/dev/null; then
    run_cmd rm -f /usr/local/lib/libtensorflow.so*
  else
    log_info "No TensorFlow shared libs to remove."
  fi

  if [[ -d /usr/local/include/tensorflow ]]; then
    run_cmd rm -rf /usr/local/include/tensorflow
  else
    log_info "No /usr/local/include/tensorflow directory found."
  fi

  run_cmd ldconfig
  log_info "TensorFlow removal complete."
}

restore_pixinsight_tf_libs() {
  if ! check_pixinsight_installed; then
    log_warn "PixInsight not found. Skipping restore."
    return 0
  fi

  local libdir="$PIXINSIGHT_DIR/bin/lib"
  local backup="$libdir/backup_tf"

  if [[ ! -d "$backup" ]]; then
    log_warn "Backup dir $backup not found; nothing to restore."
    return 0
  fi

  confirm "Restore PixInsight TensorFlow libs from $backup back into $libdir?" || {
    log_info "PixInsight restore skipped"
    return 0
  }

  run_cmd bash -c "shopt -s nullglob; for f in \"$backup\"/libtensorflow*.so*; do mv -f \"\$f\" \"$libdir/\"; done"
  log_info "PixInsight TensorFlow restore complete."
}

uninstall_all() {
  log_warn "This will remove the full GPU stack managed by this workflow:"
  log_warn "  1) TensorFlow C API (/usr/local/lib/libtensorflow.so*)"
  log_warn "  2) cuDNN (under CUDA include + CUDA libdir)"
  log_warn "  3) CUDA toolkit (/usr/local/cuda-${CUDA_SHORT})"
  log_warn "Order: TensorFlow -> cuDNN -> CUDA"

  confirm "Proceed with Uninstall All?" || {
    log_info "Uninstall All aborted"
    return 0
  }

  uninstall_tensorflow
  uninstall_cudnn
  uninstall_cuda

  log_info "Uninstall All complete."
}

# === MENU (installer-style) ===
show_menu() {
  echo
  echo "GPU Uninstaller Menu"
  echo "===================="
  echo "NOTE: For a safe preview, re-run this program with --dry-run or -d to see what it would do without making changes."
  echo
  echo "1) Uninstall CUDA"
  echo "2) Uninstall cuDNN"
  echo "3) Uninstall TensorFlow C API"
  echo "4) Uninstall All (TF + cuDNN + CUDA)"
  echo "5) Remove bashrc GPU block only"
  echo "6) Restore PixInsight TF libs (if backup exists)"
  echo "7) Quit"
}

show_menu

# === MAIN LOOP ===
while true; do
  read -rp "Enter choice [1-7]: " choice
  case "${choice:-}" in
    1) log_info "-- Selected: Uninstall CUDA --"; uninstall_cuda ;;
    2) log_info "-- Selected: Uninstall cuDNN --"; uninstall_cudnn ;;
    3) log_info "-- Selected: Uninstall TensorFlow C API --"; uninstall_tensorflow ;;
    4) log_info "-- Selected: Uninstall All --"; uninstall_all ;;
    5) log_info "-- Selected: Remove bashrc GPU block only --"; remove_bashrc_block ;;
    6) log_info "-- Selected: Restore PixInsight TF libs --"; restore_pixinsight_tf_libs ;;
    7) echo "Exiting."; break ;;
    *) log_error "Invalid selection: ${choice:-}";;
  esac
  show_menu
done
