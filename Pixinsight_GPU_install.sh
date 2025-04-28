#!/bin/bash
set -e

# === CONFIG ===
CUDA_VERSION="11.8.0"
CUDA_SHORT="11.8"
CUDNN_VERSION="8.9.4.25"
TENSORFLOW_VERSION="2.13.0"
REQUIRED_DRIVER_VERSION="550"  # Update this based on compatibility with your CUDA version
PIXINSIGHT_DIR="/opt/PixInsight"
PIXINSIGHT_BIN="/usr/bin/PixInsight"
USER_HOME=$(getent passwd "${SUDO_USER:-$(logname)}" | cut -d: -f6)
DOWNLOAD_DIR="$USER_HOME/Downloads"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;33m⚠️  Not running as root. Attempting to re-run with sudo...\033[0m"
    sudo bash "$0" "$@"
    exit $?
fi

# === Functions ===

# Function to check if a valid NVIDIA GPU is present using lspci
check_nvidia_gpu() {
    echo "🔧 Checking for NVIDIA GPU..."
    # Check for NVIDIA GPU using lspci
    GPU_INFO=$(lspci | grep -i nvidia)
    if [ -z "$GPU_INFO" ]; then
        echo "❌ ERROR: No NVIDIA GPU detected. Please ensure that the GPU is installed and recognized by the system"
        exit 1
    else
        echo "✅ NVIDIA GPU detected: $GPU_INFO"
    fi
}

# Function to check if a valid NVIDIA driver is installed
check_nvidia_driver() {
    echo "🔧 Checking for a valid NVIDIA driver..."

    # Check if nouveau driver is active
    if lsmod | grep -i nouveau &> /dev/null; then
        echo "❌ ERROR: Nouveau driver is active. Please blacklist it and install an official NVIDIA driver"
        echo "ℹ️  Tip: Create a /etc/modprobe.d/blacklist-nouveau.conf file to blacklist nouveau"
        exit 1
    else
    	echo "✅ Nouveau driver not active"
    fi

    # Check if nvidia-smi is available
    if ! command -v nvidia-smi &> /dev/null; then
        echo "❌ ERROR: NVIDIA driver not found. Please install NVIDIA driver >= $REQUIRED_DRIVER_VERSION"
        exit 1
    fi

    # Check installed NVIDIA driver version
    INSTALLED_DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)

    if [[ "$INSTALLED_DRIVER_VERSION" == "$REQUIRED_DRIVER_VERSION"* ]]; then
        echo "✅ Compatible NVIDIA driver $INSTALLED_DRIVER_VERSION is installed"
    else
        echo "❌ ERROR: Incompatible or missing NVIDIA driver. Installed driver is $INSTALLED_DRIVER_VERSION, but you need at least version $REQUIRED_DRIVER_VERSION"
        echo "Please install a compatible driver"
        exit 1
    fi
}

# Function to check and install system prerequisites
check_prerequisites() {
    echo "🔧 Checking system pre-requisite system software..."

    missing_packages=()

    # Check for build-essential meta-package
    if ! dpkg-query -W -f='${Status}' build-essential 2>/dev/null | grep -q "install ok installed"; then
        missing_packages+=("build-essential")
    fi

    # Check for wget
    if ! command -v wget >/dev/null 2>&1; then
        missing_packages+=("wget")
    fi

    # Check for curl
    if ! command -v curl >/dev/null 2>&1; then
        missing_packages+=("curl")
    fi

    # Check for strings (part of binutils)
    if ! command -v strings >/dev/null 2>&1; then
        missing_packages+=("binutils")
    fi

    if [ ${#missing_packages[@]} -ne 0 ]; then
        echo -e "❌ Missing prerequisites: ${missing_packages[*]}"
        echo "🔧 Installing missing packages..."
        sudo apt update
        if ! sudo apt install -y "${missing_packages[@]}"; then
            echo -e "❌ Failed to install required packages: ${missing_packages[*]}"
            exit 1
        fi
    else
        echo -e "✅ All pre-requisite system software is installed"
    fi
}

verify_pixinsight_installation() {
    echo "🔧 Verifying PixInsight installation..."

    # Check install directory exists
    if [ ! -d "$PIXINSIGHT_DIR" ]; then
        echo "❌ ERROR: PixInsight directory not found at $PIXINSIGHT_DIR"
        return 1
    else
        echo "✅ PixInsight directory found at $PIXINSIGHT_DIR"
    fi

    # Check for main executable
    if [ ! -x "$PIXINSIGHT_BIN" ]; then
        echo "❌ ERROR: PixInsight executable not found or not executable at $PIXINSIGHT_BIN"
        echo "    Ensure that PixInsight is installed correctly and permissions are set"
        return 1
    else
        echo "✅ PixInsight executable found at $PIXINSIGHT_BIN"
    fi

    # Try to run a harmless command to confirm it starts
    if ! "$PIXINSIGHT_BIN" --help &>/dev/null; then
        echo "⚠️  WARNING: PixInsight executable ran but did not return help output"
        echo "    It may be corrupted or missing dependencies"
    else
        echo "✅ PixInsight executable responded"
    fi

    echo "✅ PixInsight installation appears valid"
    echo ""
    return 0
}

# Check if CUDA is installed
check_cuda_installed() {
    if [ -d "/usr/local/cuda-${CUDA_SHORT}" ]; then
        echo "✅ CUDA ${CUDA_SHORT} is already installed"
        return 0
    else
        echo "❌ CUDA ${CUDA_SHORT} is NOT installed"
        return 1
    fi
}

# Verify if CUDA is installed correctly
verify_cuda_installation() {
    echo "🔧 Verifying CUDA ${CUDA_SHORT} installation..."

    if check_cuda_installed; then
        if [ -f "/usr/local/cuda-${CUDA_SHORT}/bin/nvcc" ]; then
            echo "✅ CUDA nvcc compiler is present."
            /usr/local/cuda-${CUDA_SHORT}/bin/nvcc --version > /dev/null 2>&1
            echo "🎯 CUDA installation looks correct"
        else
            echo "❌ ERROR: nvcc compiler not found. CUDA installation might be incomplete!"
            return 1
        fi
    else
        return 1
    fi
}

# Check if cuDNN is installed
check_cudnn_installed() {
    if [ -f "/usr/local/cuda-${CUDA_SHORT}/include/cudnn.h" ]; then
        echo "✅ cuDNN ${CUDNN_VERSION} is already installed"
        return 0
    else
        echo "❌ cuDNN ${CUDNN_VERSION} is NOT installed"
        return 1
    fi
}

# Verify if cuDNN is installed correctly
verify_cudnn_installation() {
    echo "🔧 Verifying cuDNN ${CUDNN_VERSION} installation..."

    if check_cudnn_installed; then
        if [ -f "/usr/local/cuda-${CUDA_SHORT}/lib64/libcudnn.so" ]; then
            echo "✅ cuDNN library is present"
            echo "🎯 cuDNN installation looks correct"
        else
            echo "❌ ERROR: cuDNN library not found. cuDNN installation might be incomplete!"
            return 1
        fi
    else
        return 1
    fi
}

# Check if TensorFlow is installed
check_tensorflow_installed() {
    if [ -f "/usr/local/lib/libtensorflow.so.${TENSORFLOW_VERSION}" ]; then
        echo "✅ TensorFlow ${TENSORFLOW_VERSION} is already installed"
        return 0
    else
        echo "❌ TensorFlow ${TENSORFLOW_VERSION} is NOT installed"
        return 1
    fi
}

verify_tensorflow_installation() {
    echo "🔧 Verifying TensorFlow installation..."

	local all_ok=true
    if check_tensorflow_installed; then
    	# Check TensorFlow shared libraries
    	if [ -f "/usr/local/lib/libtensorflow_framework.so" ]; then
        	echo "✅ TensorFlow shared libraries are found in /usr/local/lib"
    	else
        	echo "❌ TensorFlow libraries are missing from /usr/local/lib"
        	all_ok=false
    	fi

    	# Check TensorFlow header files
    	if [ -d "/usr/local/include/tensorflow" ]; then
        	echo "✅ TensorFlow header files are found in /usr/local/include"
    	else
        	echo "⚠️ TensorFlow header files are missing in /usr/local/include"
        	all_ok=false
    	fi

    	# Check PixInsight’s bundled TensorFlow libs
    	if ls $PIXINSIGHT_DIR/bin/lib/libtensorflow* &> /dev/null; then
        	echo "⚠️ PixInsight TensorFlow libraries found in $PIXINSIGHT_DIR/bin/lib"
        	all_ok=false
    	else
     		echo "✅ PixInsight TensorFlow libraries not found in $PIXINSIGHT_DIR/bin/lib"  
    	fi

    	# Check TF_FORCE_GPU_ALLOW_GROWTH in ~/.bashrc
    	if grep -q '^export TF_FORCE_GPU_ALLOW_GROWTH="true"' $USER_HOME/.bashrc; then
        	echo "✅ TF_FORCE_GPU_ALLOW_GROWTH is set to 'true' in ~/.bashrc"  
    	else
        	echo "⚠️ TF_FORCE_GPU_ALLOW_GROWTH not found in ~/.bashrc"
        	echo "   → Add: export TF_FORCE_GPU_ALLOW_GROWTH=\"true\""
        	all_ok=false
    	fi
    	if $all_ok; then
	       	echo "🎯 Tensorflow appears to be installed correctly for PixInsight"
	       	echo ""
		fi
	fi
}

# Install CUDA Toolkit
install_cuda() {
    if check_cuda_installed; then
        echo "⚠️ CUDA is already installed. Skipping CUDA installation"
        return
    fi

    echo "🔧 Installing CUDA Toolkit $CUDA_VERSION..."

    cd "$DOWNLOAD_DIR"
    CUDA_INSTALLER="cuda_${CUDA_VERSION}_linux.run"

    if [ ! -f "$CUDA_INSTALLER" ]; then
        wget -nc -c https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/$CUDA_INSTALLER
    fi

    if [ ! -f "$CUDA_INSTALLER" ]; then
        echo "❌ ERROR: CUDA installer download failed!"
        exit 1
    fi

    chmod +x "$CUDA_INSTALLER"

    echo "🔧 Running CUDA installer (toolkit only)..."
    echo "[sudo needed] Running the CUDA installer. This will install CUDA system-wide"
    sudo ./"$CUDA_INSTALLER" --silent --toolkit --no-driver --no-opengl-libs --samples=0 --no-nouveau

    if [ ! -d "/usr/local/cuda-${CUDA_SHORT}" ]; then
        echo "❌ ERROR: CUDA directory not found!"
        exit 1
    fi

    echo "🔧 Configuring environment variables..."
    if ! grep -q "cuda-${CUDA_SHORT}" ~/.bashrc; then
        echo "export PATH=/usr/local/cuda-${CUDA_SHORT}/bin:\$PATH" >> ~/.bashrc
        echo "export LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_SHORT}/lib64:\$LD_LIBRARY_PATH" >> ~/.bashrc
    fi
    source ~/.bashrc

    echo "/usr/local/cuda-${CUDA_SHORT}/lib64" | sudo tee /etc/ld.so.conf.d/cuda-${CUDA_SHORT}.conf
    sudo ldconfig   
    echo "✅ CUDA installed successfully"
}

# Install cuDNN
install_cudnn() {
    if check_cudnn_installed; then
        echo "⚠️ cuDNN is already installed. Skipping cuDNN installation"
        return
    fi

    echo "🔧 Installing cuDNN ${CUDNN_VERSION} for CUDA ${CUDA_SHORT}..."

    # look for a downloaded cuDNN archive in DOWNLOAD_DIR
    local default_tar="${DOWNLOAD_DIR}/cudnn-linux-x86_64-${CUDNN_VERSION}_cuda${CUDA_SHORT/.8/}-archive.tar.xz"
    if [[ -f "$default_tar" ]]; then
        echo "📦 Found cuDNN archive tar file in ~/Downloads: $default_tar"
        cudnn_tar="$default_tar"
    else
        echo "⚠️ cuDNN archive tar file not found in ${DOWNLOAD_DIR}."
        echo "👉 Please download cuDNN ${CUDNN_VERSION} for CUDA ${CUDA_SHORT} from NVIDIA cuDNN Archive"
        read -rp "📦 Enter FULL PATH to downloaded cuDNN tar file: " cudnn_tar
    fi

    if [[ ! -f "$cudnn_tar" ]]; then
        echo "❌ ERROR: cuDNN archive tar file not found at $cudnn_tar!"
        exit 1
    fi

    tar -xvf "$cudnn_tar" -C "$DOWNLOAD_DIR/"
    # assume extraction creates a cuda directory
    cd "$DOWNLOAD_DIR/cuda" || exit 1

    if [[ ! -d "include" || ! -d "lib64" ]]; then
        echo "❌ ERROR: cuDNN archive did not extract correctly"
        exit 1
    fi

    echo "🔧 Copying cuDNN files..."
    echo "[sudo needed] Copying cuDNN files to CUDA directories"
    sudo cp include/cudnn*.h /usr/local/cuda-${CUDA_SHORT}/include/
    sudo cp lib64/libcudnn* /usr/local/cuda-${CUDA_SHORT}/lib64/
    sudo chmod a+r /usr/local/cuda-${CUDA_SHORT}/include/cudnn*.h /usr/local/cuda-${CUDA_SHORT}/lib64/libcudnn*

    echo "/usr/local/cuda-${CUDA_SHORT}/lib64" | sudo tee /etc/ld.so.conf.d/cuda-${CUDA_SHORT}.conf
    sudo ldconfig

    echo "✅ cuDNN installed successfully"
}

# Install TensorFlow C API
install_tensorflow() {
    if check_tensorflow_installed; then
        echo "⚠️ TensorFlow is already installed. Skipping TensorFlow installation"
        return
    fi

    echo "🔧 Installing TensorFlow C API version $TENSORFLOW_VERSION..."

    cd "$DOWNLOAD_DIR"
    TENSORFLOW_ARCHIVE="libtensorflow-gpu-linux-x86_64-${TENSORFLOW_VERSION}.tar.gz"

    if [ ! -f "$TENSORFLOW_ARCHIVE" ]; then
        wget -nc -c https://storage.googleapis.com/tensorflow/libtensorflow/$TENSORFLOW_ARCHIVE
    fi

    if [ ! -f "$TENSORFLOW_ARCHIVE" ]; then
        echo "❌ ERROR: TensorFlow C API download failed!"
        exit 1
    fi

    tar -xvzf "$TENSORFLOW_ARCHIVE"

    if [ ! -d "tensorflow" ]; then
        echo "❌ ERROR: TensorFlow archive did not extract correctly!"
        exit 1
    fi

    echo "🔧 Copying TensorFlow libraries..."
    echo "[sudo needed] Copying TensorFlow libraries to /usr/local"
    sudo cp -r tensorflow/include/* /usr/local/include/
    sudo cp -r tensorflow/lib/* /usr/local/lib/
    sudo ldconfig

    if [ ! -f "/usr/local/lib/libtensorflow.so" ]; then
        echo "❌ ERROR: TensorFlow library not copied correctly!"
        exit 1
    fi

    echo "✅ TensorFlow C API installed successfully"

    echo -e "🔧 Adding TensorFlow environment variables to ~/.bashrc..."
    # Add TF_FORCE_GPU_ALLOW_GROWTH if not present
    if ! grep -q "TF_FORCE_GPU_ALLOW_GROWTH" $USER_HOME/.bashrc; then
        echo 'export TF_FORCE_GPU_ALLOW_GROWTH="true"' >> $USER_HOME/.bashrc
    fi

    echo "🔧 Updating PixInsight TensorFlow libraries..."
    if verify_pixinsight_installation; then
        sudo mkdir -p $PIXINSIGHT_DIR/bin/lib/backup_tf
        sudo mv $PIXINSIGHT_DIR/bin/lib/libtensorflow* $PIXINSIGHT_DIR/bin/lib/backup_tf/ 2>/dev/null || true
        echo "✅ Old TensorFlow libraries backed up to $PIXINSIGHT_DIR/bin/lib/backup_tf"
    else
        echo "⚠️ WARNING: PixInsight may not be installed yet!"
    fi
    source $USER_HOME/.bashrc

    echo "✅ TensorFlow installed successfully"
}

# Update PixInsight’s TensorFlow libraries after PixInsight update
update_pxi_tf() {
    echo "🔧 Updating PixInsight TensorFlow libraries..."
    if verify_pixinsight_installation; then
        sudo mkdir -p $PIXINSIGHT_DIR/bin/lib/backup_tf
        sudo mv $PIXINSIGHT_DIR/bin/lib/libtensorflow* $PIXINSIGHT_DIR/bin/lib/backup_tf/ 2>/dev/null || true
        # sudo cp /usr/local/lib/libtensorflow* $PIXINSIGHT_DIR/bin/lib/
        echo "✅ PixInsight TensorFlow libraries updated"
    else
        echo "❌  PixInsight not found at $PIXINSIGHT_DIR. Cannot update"
        return 1
    fi
}

# === Main Menu ===
while true; do
	echo "PixInsight GPU software installer (Ubuntu 24.04 + RTX 2060)"
	echo "=============================================="
	echo "Choose what you want to install:"
	echo " 1) Check & install system pre-requisite software"
	echo " 2) Install CUDA only"
	echo " 3) Install cuDNN only"
	echo " 4) Install TensorFlow C API only"
	echo " 5) Install ALL GPU software components"
	echo " 6) Update TensorFlow after PixInsight re-installation only"
	echo " 7) Verify installed components"
	echo " 8) Quit"
	echo "=============================================="
	read -rp "Enter choice [1-8]: " choice

	case $choice in
		1)
			check_nvidia_gpu
			check_prerequisites
	       	check_nvidia_driver
	       	verify_pixinsight_installation
			;;
		2)
			check_nvidia_gpu
			check_prerequisites
			check_nvidia_driver
			install_cuda
     	   ;;
    	3)
        	check_nvidia_gpu
        	check_prerequisites
        	check_nvidia_driver
        	install_cudnn
        	;;
    	4)
        	check_nvidia_gpu
        	check_prerequisites
        	check_nvidia_driver
        	verify_pixinsight_installation
        	install_tensorflow
        	;;
    	5)
        	check_nvidia_gpu
        	check_prerequisites
        	check_nvidia_driver
        	verify_pixinsight_installation
        	install_cuda
        	install_cudnn
        	install_tensorflow
        	;;
    	6)
        	check_tensorflow_installed
        	verify_tensorflow_installation
        	verify_pixinsight_installation
        	update_pxi_tf	
        	;;
    	7)
        	verify_cuda_installation
        	verify_cudnn_installation
        	verify_tensorflow_installation
        	;;
    	8)
        	echo "❌ Exiting."
        	break
        	;;
    	*)
        	echo "❌ Invalid choice."
        exit 1
        	;;
	esac
done
