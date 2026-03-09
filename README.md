# Embedded Camera App with Flutter + C++ + OpenCV

An embedded camera controller application built with Flutter for the UI and C++ with OpenCV for the camera backend processing. This app provides real-time camera control (open, pause, resume, stop) with FPS display and status indicators.

## 📱 Features

- **Live Camera Preview** - Real-time camera stream display
- **Open Camera** - Open and activate the camera
- **Pause/Resume Camera** - Pause and resume the video stream
- **Stop Camera** - Completely stop the camera
- **FPS Counter** - Real-time frame rate display
- **Status Indicator** - Camera status (LIVE/PAUSED/STOPPED)
- **Resolution Info** - Display current video resolution

## 🛠️ Prerequisites

Before starting, ensure your system has:

- **Ubuntu 20.04+** or Debian-based Linux distribution
- **Flutter SDK** (≥ 3.0.0)
- **CMake** (≥ 3.28.3) - Install via snap
- **OpenCV** (≥ 4.6.0)
- **Camera** (built-in or external USB)

## 🚀 Complete Installation from Scratch

### 1. Install Flutter SDK

```bash
# Install dependencies
sudo apt update && sudo apt upgrade -y
# Dependencies lengkap untuk Flutter Linux
sudo apt install -y curl git unzip xz-utils zip \
    clang cmake ninja-build pkg-config \
    libgtk-3-0 libgtk-3-dev \
    libmpv-dev libepoxy-dev libasound2-dev \
    llvm-18 lld-18 binutils

# Buat symbolic link jika diperlukan
sudo ln -s /usr/bin/ld /usr/lib/llvm-18/bin/ld 2>/dev/null || true
sudo ln -s /usr/bin/lld-18 /usr/lib/llvm-18/bin/lld.lld 2>/dev/null || true

# Download Flutter SDK
cd ~
git clone https://github.com/flutter/flutter.git -b stable
echo 'export PATH="$PATH:$HOME/flutter/bin"' >> ~/.bashrc
source ~/.bashrc

# Verify installation
flutter doctor
```

### 2. Install Latest CMake

```bash
# Remove old CMake if exists
sudo apt remove --purge cmake cmake-data

# Install via snap
sudo snap install cmake --classic

# Create symlink
sudo ln -sf /snap/bin/cmake /usr/local/bin/cmake

# Update PATH
export PATH=/usr/local/bin:$PATH
echo 'export PATH=/usr/local/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# Verify
cmake --version  # Should be ≥ 3.28.x
```

### 3. Install OpenCV

```bash
# Install OpenCV and dependencies
sudo apt update
sudo apt install -y libopencv-dev libopencv-core-dev libopencv-videoio-dev \
libopencv-imgproc-dev libopencv-highgui-dev build-essential

# Verify
pkg-config --modversion opencv4  # Should be 4.6.0 or higher
```

### 4. Clone Repository

```bash
# Clone your repo (replace URL with your repository)
git clone https://github.com/username/camera_embedded.git
cd camera_embedded
```

### 5. Build and Run the Application

```bash
# Make the run script executable
chmod +x run_clean.sh

# Run the application
./run_clean.sh
```

## 📁 Project Structure

```
camera_embedded/
├── lib/
│   └── main.dart                 # Flutter UI and FFI bindings
├── linux/
│   ├── CMakeLists.txt            # Main build configuration
│   ├── cpp/
│   │   ├── CMakeLists.txt        # C++/OpenCV build configuration
│   │   ├── camera_driver.h       # C++ header
│   │   └── camera_driver.cpp     # OpenCV implementation
│   └── runner/
│       └── CMakeLists.txt        # Runner build configuration
├── pubspec.yaml                   # Flutter dependencies
└── run_clean.sh                   # Script to run the app
```

## 🎯 How to Use

1. **Run the application**:
   ```bash
   ./run_clean.sh
   ```

2. **Camera controls**:
   - **Open** - Open camera and start streaming
   - **Pause** - Pause the stream (last frame remains)
   - **Resume** - Resume paused stream
   - **Stop** - Completely stop the camera

3. **Status indicators**:
   - **Green (LIVE)** - Camera active and streaming
   - **Orange (PAUSED)** - Camera paused
   - **Red (STOPPED)** - Camera inactive

4. **Additional information**:
   - **FPS counter** - Real-time frame rate in top-right corner
   - **Resolution** - Video resolution in bottom-left corner

## 🔧 Troubleshooting

### Camera not detected
```bash
# Check camera devices
ls -la /dev/video*
v4l2-ctl --list-devices

# Add user to video group
sudo usermod -a -G video $USER
# Logout/login or run: newgrp video
```

### OpenCV library not found
```bash
# Check OpenCV installation
pkg-config --libs --cflags opencv4

# Reinstall if necessary
sudo apt install --reinstall libopencv-dev
```

### Error "CMake 3.28.3 or higher is required"
```bash
# Install CMake via snap
sudo snap install cmake --classic
sudo ln -sf /snap/bin/cmake /usr/local/bin/cmake
export PATH=/usr/local/bin:$PATH
source ~/.bashrc
```

### Library loading error
```bash
# Check library and dependencies
ldd libcamera_driver.so
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$(pwd)
flutter run -d linux
```

## 📦 Dependencies

- **Flutter SDK** - UI framework
- **OpenCV** - Camera processing and capture
- **CMake** - Build system
- **dart:ffi** - Foreign Function Interface for Flutter-C++ communication

## 🤝 Contributing

Feel free to fork this repository and submit pull requests. For bugs or feature requests, please create an issue.

## 📄 License

[MIT License](LICENSE)

## 🙏 Credits

Built with ❤️ using Flutter and OpenCV.

## 📞 Contact

If you have any questions, please create an issue in this repository.
