# GPU Software Installer for PixInsight (Ubuntu 24.04 + GeoForce RTX 2060 GPU)

This script automates the installation and verification of NVIDIA CUDA Toolkit, cuDNN, and TensorFlow C API on Ubuntu 24.04, with support for NVIDIA GeForce RTX 2060 GPU. It helps set up these GPU-accelerated libraries to work with NoiseXTerminator, BlurXTerminator, and StarXTerminator in PixInsight. This script also provides options for checking and installing missing prerequisites, verifying installations, and ensuring compatibility. Please be aware that I have only tested this on Ubuntu 24.04, with a NVIDIA GeForce RTX 2060 GPU and NVIDIA driver version 550.120. If you would like to use this script with other NVIDIA GPU's and NVIDIA drivers you will need to determine which version of CUDA, cuDNN, TensorFlow and NVIDIA driver will work with your GPU and modify the script accordingly (see [this](https://www.tensorflow.org/install/source#gpu) table). You can modify these software versions by changing the following variables in the script:

```bash
CUDA_VERSION="11.8.0"
CUDA_SHORT="11.8"
CUDNN_VERSION="8.9.4.25"
TENSORFLOW_VERSION="2.13.0"
REQUIRED_DRIVER_VERSION="550"
```

Please be aware that this approach is what worked for me and I decided to 'automate' this setup with a script to save the future me some time. This approach may not neccessarily be the 'best' or only way to do this but for my setup it works for me. There is not a great deal of information for setting this up on linux (or at least I couldn't find much), but these resources may help if this script doen't work for you (YMMV):

- [twivel guide](https://pixinsight.com/forum/index.php?threads/procedure-to-enable-gpu-acceleration-for-bxt-starnet-etc-within-linux-mint-with-a-supported-nvidia-graphics-card.23356/)
- [lblock guide](https://pixinsight.com/forum/index.php?threads/gpu-acceleration-for-pixinsight-with-linux-kubuntu-or-ubuntu-using-rc-astro-tools-eg-starxterminator-or-starnet.22163/)
- [steve D guide](https://pixinsight.com/forum/index.php?threads/how-to-gpu-accelerate-starxterminator-and-starnet2-on-linux.19773/)
- [Ajay guide](https://pixinsight.com/forum/index.php?threads/gpu-accelerated-starnet-v2-working-with-cuda-and-libtensorflow-gpu-under-linux.18180/)

## Key Features
Installs the following software components:
- CUDA 11.8
- cuDNN 8.9.4.25
- TensorFlow 2.13.0 C API

## **Pre-requisites**

Before running the script, ensure the following:
1. **Ubuntu 24.04** installed on the system (may work with other versions/flavours of Ubuntu but untested)
2. **Root privileges** (to install system-wide software)
3. **NVIDIA GeForce RTX 2060 GPU** (might work with other Nvidia GPU's but untested)
4. **Internet connection** for downloading the required software
5. **PixInsight** installed on the system with no existing CUDA, CuDNN or TensorFlow modifications

## **Instructions**

Before running the script, ensure pre-requisites above are met.

### Step 1: Run the Script
1. **Download the Script**  
Save the script to a file, for example, `Pixinsight_GPU_install.sh` in a location of your choice (i.e. `~/PixInsight/`).

2. **Make it executable**
```bash
cd ~/PixInsight/
chmod +x Pixinsight_GPU_install.sh
```

3. **Run the script**
```bash
sudo ./Pixinsight_GPU_install.sh
```

The script will check if it is run as root and attempt to re-run itself using sudo if needed.

### Step 3: Choose Installation Options

Upon running, you will be presented with the following options in an interactive menu:

1) Check & install system pre-requisite software
2) Install CUDA only
3) Install cuDNN only
4) Install TensorFlow C API only
5) Install ALL GPU software components
6) Update TensorFlow after PixInsight re-installation only" 
7) Verify installed components
8) Quit

**Option 1:** Installs missing system packages like `build-essential`, `wget`, `curl`, etc. Also checks if a compatible NVIDIA GPU is present on the system and if the correct NVIDIA driver is installed. It will also check if the Nouveau driver is currently being used. If the nouveau driver is active, the script will stop and prompt the user to disable it. Checks whether a working installation of PixInsight is present on the system. This Option is useful as a quick check prior to installing other (or all) components.

**Option 2:** Installs only the CUDA Toolkit.

**Option 3:** Installs only cuDNN (see **Note 1** below).

**Option 4:** Installs only TensorFlow C API.

**Option 5:** Installs all components: CUDA, cuDNN and TensorFlow (see **Note 1** below).

**Option 6** Updates TensorFlow file locations following re-installation of PixInsight (see **Note 2** below).

**Option 7:** Verifies the installation of CUDA, cuDNN and TensorFlow.

**Option 8:** Exits the script without making changes.

### Step 4: After Installation

Reboot your system or re-source the `~/.bashrc` file to ensure that the environment variables for CUDA and TensorFlow are properly set:

```bash
source ~/.bashrc
```

## Notes

1. To install cuDNN, you must first manually download cuDNN from [NVIDIA's cuDNN archive](https://developer.nvidia.com/rdp/cudnn-archive).  Select '**Download cuDNN v8.9.4 (August 8th, 2023), for CUDA 11.x**' and then '**Local Installer for Linux x86_64 (Tar)**'. Download this file to `~/Downloads` but do not extract the tar file. When using the script you’ll be prompted to enter the **FULL** file path (e.g., `/home/myusername/Downloads/cudnn-linux-x86_64-8.9.4.25_cuda11-archive.tar.xz`) during installation (Option 3 or Option 5 above). A free NVIDIA Developer Program account is required for the download, which is why manual download is necessary. Unlike cuDNN, both CUDA and TensorFlow are automatically downloaded to `~/Downloads` without the need for an account.

2. Use Option 6 if you need to re-install PixInsight but already have CUDA, cuDNN and TensorFlow installed. For example , installing a new version of PixInsight. 

3. After installing CUDA, cuDNN, and TensorFlow, make sure to either reboot your system or re-source your `~/.bashrc` file to ensure the environment variables are properly set:

```bash
    source ~/.bashrc
```

## Error Handling and Troubleshooting

Missing NVIDIA GPU: If the system does not detect an NVIDIA GPU, ensure that your GPU is properly installed and recognised by the system.

Incompatible NVIDIA Driver: The script checks for the required driver version (currently 550). If an incompatible or missing driver is found, the script will exit with an error.

Missing cuDNN Files: If cuDNN is not extracted properly, verify that you downloaded the correct version of cuDNN and extracted it correctly.

TensorFlow Installation Errors: Ensure that the TensorFlow libraries are properly copied to `/usr/local/include/` and `/usr/local/lib/`.

## Additional Information

CUDA Version: 11.8.0
cuDNN Version: 8.9.4.25
TensorFlow Version: 2.13.0
Required NVIDIA driver version: 550

This script is specifically designed for Ubuntu 24.04, an NVIDIA GeForce RTX 2060 GPU and NVIDIA driver version 550.120. Tested on PixInsight version 1.9.3 but will probably work on recent earlier versions.

## **Disclaimer**

Use this software at your own risk. No guarantees are made about its performance or compatibility, and it's your responsibility to back up data and ensure your system is compatible. The software is provided "as-is," with no warranties, and the creator isn't liable for any issues that may arise.




