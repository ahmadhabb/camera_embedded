#!/bin/bash
set -e  # stop jika ada error

echo "================================================"
echo "   MOIL Camera App — Build & Run"
echo "================================================"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$PROJECT_DIR/native"
BUILD_DIR="$NATIVE_DIR/build"
SO_TARGET="$PROJECT_DIR/linux/libcamera_bridge.so"

# ─── 1. CEK DEPENDENCIES ────────────────────────────────
echo ""
echo "[1/4] Checking dependencies..."

if ! command -v cmake &> /dev/null; then
  echo "❌ cmake not found. Install: sudo apt install cmake"
  exit 1
fi

if ! pkg-config --exists gstreamer-1.0 gstreamer-app-1.0; then
  echo "❌ GStreamer not found. Install:"
  echo "   sudo apt install libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev"
  exit 1
fi

echo "✅ Dependencies OK"

# ─── 2. BUILD libcamera_bridge.so ───────────────────────
echo ""
echo "[2/4] Building libcamera_bridge.so..."

# Buat CMakeLists.txt di native/ kalau belum ada yang benar
cat > "$NATIVE_DIR/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.14)
project(camera_bridge CXX)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED gstreamer-1.0 gstreamer-app-1.0)

add_library(camera_bridge SHARED camera_bridge.cpp)
target_include_directories(camera_bridge PRIVATE ${GST_INCLUDE_DIRS})
target_link_libraries(camera_bridge PRIVATE ${GST_LIBRARIES})

set_target_properties(camera_bridge PROPERTIES
    CXX_STANDARD 17
    PREFIX "lib"
    OUTPUT_NAME "camera_bridge"
)
EOF

mkdir -p "$BUILD_DIR"
cmake -B "$BUILD_DIR" -S "$NATIVE_DIR" -DCMAKE_BUILD_TYPE=Release -Wno-dev > /dev/null 2>&1
cmake --build "$BUILD_DIR" --config Release -j$(nproc)

# Copy hasil build ke linux/
if [ -f "$BUILD_DIR/libcamera_bridge.so" ]; then
  cp "$BUILD_DIR/libcamera_bridge.so" "$SO_TARGET"
  echo "✅ libcamera_bridge.so built → linux/libcamera_bridge.so"
else
  echo "❌ Build failed — libcamera_bridge.so not found"
  exit 1
fi

# ─── 3. VERIFIKASI FORMAT ───────────────────────────────
echo ""
echo "[3/4] Verifying .so..."

if strings "$SO_TARGET" | grep -q "format=RGBA"; then
  echo "✅ Format: RGBA ✓"
else
  echo "⚠️  Warning: format=RGBA not found in .so"
fi

# Tampilkan resolusi yang akan dipakai
echo "ℹ️  Pipeline: v4l2src → MJPEG → jpegdec → RGBA → appsink"

# ─── 4. RUN FLUTTER ─────────────────────────────────────
echo ""
echo "[4/4] Running Flutter app..."
echo "------------------------------------------------"

export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$PROJECT_DIR:$PROJECT_DIR/linux"

cd "$PROJECT_DIR"
flutter run -d linux --release