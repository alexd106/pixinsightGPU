#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === COLOR SETUP ===
if tput colors &>/dev/null && [ "$(tput colors)" -ge 8 ]; then
  RED="\033[31m"; YELLOW="\033[33m"; GREEN="\033[32m"; NC="\033[0m"
else
  RED=""; YELLOW=""; GREEN=""; NC=""
fi

# === LOGGING FUNCTIONS ===
log_info()  { printf "${GREEN}[INFO] %s${NC}\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN] %s${NC}\n" "$*"; }
log_error() { printf "${RED}[ERROR] %s${NC}\n" "$*" >&2; }

# === USAGE ===
usage() {
  cat <<EOF
Usage: $0 [-d|--dry-run] [-h|--help]
  -d, --dry-run     Show what would be done, but make no changes
  -h, --help        Display this help message
EOF
  exit 0
}

# === PARSE ARGS ===
dry_run=false
TEMP_OPTS=$(getopt -o dh --long dry-run,help -n "$0" -- "$@") || usage
eval set -- "$TEMP_OPTS"
while true; do
  case "$1" in
    -d|--dry-run) dry_run=true; shift ;;
    -h|--help)    usage        ;;
    --) shift; break ;;
    *) usage ;;
  esac
done

# === DEPENDENCY CHECK ===
check_dependencies() {
  local cmd
  for cmd in apt sed grep ldconfig getent tput; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command '$cmd' not found."
      exit 2
    fi
  done
}
check_dependencies

# === SAFE PROMPTS & EXECUTION ===
confirm() {
  local prompt="${1:-Are you sure?}" ans
  while true; do
    read -rp "🗑️  $prompt [y/N]: " ans
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

# === CONFIGURATION ===
readonly CUDA_SHORT="11.8"
readonly CUDNN_VERSION="8.9.4.25"
readonly TENSORFLOW_VERSION="2.13.0"
readonly PIXINSIGHT_LAUNCHER="/opt/PixInsight/bin/PixInsight.sh"
USER_HOME=$(getent passwd "${SUDO_USER:-$(logname)}" | cut -d: -f6)

# require root
if [[ $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

# build apt options
declare -a APT_OPTS
$dry_run && APT_OPTS+=(--simulate)
APT_OPTS+=(purge -y)

# === CHECK FUNCTIONS ===
check_cuda_installed()   { [[ -d "/usr/local/cuda-${CUDA_SHORT}" ]]; }
check_cudnn_installed()  { [[ -f "/usr/local/cuda-${CUDA_SHORT}/include/cudnn.h" ]]; }
check_tf_installed()     { compgen -G "/usr/local/lib/libtensorflow.so.${TENSORFLOW_VERSION}*" >/dev/null; }
check_pixinsight_installed() { [[ -x "$PIXINSIGHT_LAUNCHER" ]]; }

# === UNINSTALL FUNCTIONS ===
uninstall_cuda() {
  local dir="/usr/local/cuda-${CUDA_SHORT}"
  if ! check_cuda_installed; then
    log_warn "No CUDA at $dir. Nothing to do!"
    return
  fi
  confirm "Uninstall CUDA?" || {
    log_info "CUDA uninstall aborted"
    return
  }
  [[ -x "$dir/bin/cuda-uninstaller" ]] && run_cmd sudo "$dir/bin/cuda-uninstaller" --silent
  run_cmd sudo apt "${APT_OPTS[@]}" cuda* cublas*
  run_cmd sudo apt "${APT_OPTS[@]}" autoremove
  run_cmd sudo apt "${APT_OPTS[@]}" autoclean
  if compgen -G "/usr/local/cuda*" >/dev/null; then
    run_cmd sudo rm -rf /usr/local/cuda*
  else
    log_info "No /usr/local/cuda* to remove."
  fi
  if grep -q '/usr/local/cuda' "$USER_HOME/.bashrc"; then
    run_cmd sed -i '\#/usr/local/cuda#d' "$USER_HOME/.bashrc"
  fi
  if compgen -G "/etc/ld.so.conf.d/cuda-*.conf" >/dev/null; then
    run_cmd sudo rm -f /etc/ld.so.conf.d/cuda-*.conf
  fi
  run_cmd sudo ldconfig
  log_info "CUDA removal complete"
}

uninstall_cudnn() {
  if ! check_cudnn_installed && ! ldconfig -p | grep -q libcudnn; then
    log_warn "No cuDNN detected."
    return
  fi
  confirm "Uninstall cuDNN?" || {
    log_info "cuDNN uninstall aborted"
    return
  }
  local inc="/usr/local/cuda-${CUDA_SHORT}/include" lib="/usr/local/cuda-${CUDA_SHORT}/lib64"
  if compgen -G "$inc"/cudnn*.h >/dev/null || compgen -G "$lib"/libcudnn* >/dev/null; then
    run_cmd sudo rm -f "$inc"/cudnn*.h "$lib"/libcudnn*
  else
    log_info "No cuDNN files to remove."
  fi
  run_cmd sudo apt "${APT_OPTS[@]}" cudnn*
  run_cmd sudo apt "${APT_OPTS[@]}" autoremove
  run_cmd sudo apt "${APT_OPTS[@]}" autoclean
  if grep -q cudnn "$USER_HOME/.bashrc"; then
    run_cmd sed -i '/cudnn/d' "$USER_HOME/.bashrc"
  fi
  if compgen -G "/etc/ld.so.conf.d/*cudnn*.conf" >/dev/null; then
    run_cmd sudo rm -f /etc/ld.so.conf.d/*cudnn*.conf
  fi
  run_cmd sudo ldconfig
  log_info "cuDNN removal complete"
}

uninstall_tensorflow() {
  if ! check_tf_installed; then
    log_warn "No TensorFlow C API detected."
    return
  fi
  confirm "Delete TensorFlow C API files?" || {
    log_info "TensorFlow uninstall skipped"
    return
  }
  if compgen -G "/usr/local/lib/libtensorflow.so*" >/dev/null; then
    run_cmd sudo rm -f /usr/local/lib/libtensorflow.so*
  else
    log_info "No TF libs to remove."
  fi
  [[ -d /usr/local/include/tensorflow ]] && run_cmd sudo rm -rf /usr/local/include/tensorflow
  run_cmd sudo ldconfig
  log_info "TensorFlow removal complete"
}

cleanup_pixinsight_tf() {
  if ! check_pixinsight_installed; then
    log_warn "PixInsight not found. Skipping restore."
    return
  fi
  confirm "Restore PixInsight TensorFlow libs?" || {
    log_info "PixInsight restore skipped"
    return
  }
  local libdir="/opt/PixInsight/bin/lib" backup="$libdir/backup_tf"
  if [[ -d $backup ]]; then
    run_cmd bash -c "shopt -s nullglob; for f in \"$backup\"/libtensorflow*.so*; do mv -f \"\$f\" \"$libdir/\"; done"
  else
    log_warn "Backup dir $backup not found."
  fi
  log_info "PixInsight restore complete"
}

# === MENU ===
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
    *) echo "Invalid selection." ;;
  esac
done