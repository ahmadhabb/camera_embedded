# camera_embedded

Aplikasi Flutter Linux untuk menampilkan feed kamera fisheye dengan koreksi proyeksi **MOIL (Mapping of Omni-directional Image with Less distortion)** secara real-time menggunakan GLSL fragment shader.

---

## Fitur

- 🎥 **Live Camera** via GStreamer (V4L2, MJPEG, 1920×1080 @ 30fps)
- 🎬 **Video File** playback via media_kit (MP4, MKV, dll)
- 🌐 **Shader MOIL** — Anypoint M1, Anypoint M2, Panorama Car, Panorama Tube
- 🖱️ Kontrol interaktif: drag pan (alpha/beta), scroll zoom, double-tap reset
- 📊 Performance overlay: FPS, frame time, memory, resolusi

---

## Prasyarat Sistem

| Kebutuhan | Versi minimal |
|---|---|
| OS | Ubuntu 22.04 / 24.04 (Linux x86_64) |
| Flutter | 3.19+ |
| Dart | 3.3+ |
| CMake | 3.14+ |
| GCC / G++ | 11+ |
| GStreamer | 1.20+ |

---

## 1. Install Flutter

```bash
# Install dependensi sistem Flutter
sudo apt update
sudo apt install -y curl git unzip xz-utils zip libglu1-mesa

# Download Flutter SDK
cd ~
git clone https://github.com/flutter/flutter.git -b stable

# Tambahkan ke PATH (tambahkan ke ~/.bashrc atau ~/.zshrc)
echo 'export PATH="$PATH:$HOME/flutter/bin"' >> ~/.bashrc
source ~/.bashrc

# Verifikasi
flutter doctor
```

> Pastikan `flutter doctor` tidak menampilkan error untuk Linux toolchain.

---

## 2. Install Dependensi Sistem

```bash
sudo apt install -y \
  cmake \
  ninja-build \
  pkg-config \
  libgtk-3-dev \
  libblkid-dev \
  liblzma-dev \
  # GStreamer core & plugins
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-libav \
  # V4L2 tools (opsional, untuk debug kamera)
  v4l-utils
```

---

## 3. Clone / Setup Project

```bash
git clone <url-repo-anda> camera_embedded
cd camera_embedded
```

Struktur folder yang diharapkan:

```
camera_embedded/
├── lib/
│   └── main.dart
├── shaders/
│   └── anypoint.frag
├── native/
│   ├── camera_bridge.cpp
│   └── CMakeLists.txt
├── linux/               ← libcamera_bridge.so akan di-generate di sini
├── pubspec.yaml
└── README.md
```

---

## 4. Build Native Library (GStreamer Bridge)

Library C++ ini menghubungkan GStreamer dengan Flutter via FFI.

```bash
# Dari root project
cmake -B native/build -S native

cmake --build native/build

# Verifikasi — harus muncul file .so
ls -lh linux/libcamera_bridge.so
```

Output yang diharapkan:
```
-rwxrwxr-x 1 user user 18K ... linux/libcamera_bridge.so
```

> **Rebuild diperlukan** setiap kali `camera_bridge.cpp` diubah.

---

## 5. Install Flutter Packages

```bash
flutter pub get
```

Pastikan `pubspec.yaml` memiliki dependencies berikut:

```yaml
dependencies:
  flutter:
    sdk: flutter
  ffi: ^2.1.0
  file_picker: ^8.0.0
  media_kit: ^1.1.11
  media_kit_video: ^1.2.4
  flutter_shaders: ^0.1.3

flutter:
  shaders:
    - shaders/anypoint.frag
```

---

## 6. Jalankan Aplikasi

```bash
# Development mode
flutter run -d linux

# Release mode (performa lebih baik)
flutter run -d linux --release
```

Jika GStreamer tidak menemukan plugin saat runtime:

```bash
GST_PLUGIN_PATH=/usr/lib/x86_64-linux-gnu/gstreamer-1.0 flutter run -d linux --release
```

---

## 7. Verifikasi Kamera

Sebelum membuka kamera di app, pastikan kamera terbaca oleh sistem:

```bash
# Cek device yang tersedia
ls /dev/video*

# Cek format yang didukung kamera
v4l2-ctl --list-formats-ext -d /dev/video0

# Test langsung dengan GStreamer (harus tampil video)
gst-launch-1.0 v4l2src device=/dev/video0 \
  ! image/jpeg,width=1920,height=1080,framerate=30/1 \
  ! jpegdec ! videoconvert ! autovideosink
```

Jika test GStreamer berhasil tapi app gagal, pastikan user ada di group `video`:

```bash
groups $USER        # cek group aktif
sudo usermod -aG video $USER
# logout dan login kembali agar group aktif
```

---

## Kontrol Aplikasi

| Aksi | Kontrol |
|---|---|
| Pan / ubah sudut pandang | Klik + drag |
| Zoom in / out | Scroll mouse |
| Reset ke posisi awal | Double-tap |
| Buka video file | Tombol **LOAD VIDEO SOURCE** |
| Buka kamera live | Tombol **OPEN CAMERA** |
| Disconnect kamera | Tombol **DISCONNECT CAMERA** |

---

## Troubleshooting

### `libcamera_bridge.so` tidak ditemukan
```bash
# Pastikan file ada
ls linux/libcamera_bridge.so

# Jika belum ada, build ulang
cmake -B native/build -S native && cmake --build native/build
```

### Kamera hanya menampilkan loading
```bash
# Test pipeline GStreamer manual
gst-launch-1.0 v4l2src device=/dev/video0 \
  ! image/jpeg,width=1920,height=1080,framerate=30/1 \
  ! jpegdec ! videoconvert ! autovideosink
```

### Warna tidak sesuai (kulit biru)
Sudah ditangani di shader (`anypoint.frag`) dengan swap channel R↔B karena format output kamera adalah `yuvj422p` (BGRA bukan RGBA).

### FPS rendah
- Pastikan menggunakan **release mode**: `flutter run -d linux --release`
- Pastikan kamera support **MJPEG** (bukan YUYV) di resolusi target
- Cek dengan: `v4l2-ctl --list-formats-ext -d /dev/video0`

### Error `gst_init` saat runtime
```bash
# Install plugin tambahan
sudo apt install gstreamer1.0-plugins-ugly gstreamer1.0-tools
```

---

## Konfigurasi Kamera

Parameter kalibrasi MOIL ada di `MoilConfig` (`lib/main.dart`).  
Sesuaikan dengan spesifikasi kamera fisheye Anda:

```dart
static const double _sensorWidth  = 2592.0;  // resolusi asli sensor
static const double _sensorHeight = 1944.0;
static const double _sensorCx     = 1236.0;  // titik pusat lensa (pixels)
static const double _sensorCy     = 950.0;

// Koefisien polinomial fisheye (dari kalibrasi kamera)
final double p2 = -34.367;
final double p3 =  70.646;
final double p4 =  41.608;
final double p5 = 504.11;
```

---

## Tech Stack

| Komponen | Teknologi |
|---|---|
| UI Framework | Flutter (Linux desktop) |
| Camera capture | GStreamer 1.0 (V4L2 → MJPEG → RGBA) |
| Native bridge | C++17 via Dart FFI |
| Video playback | media_kit (libmpv) |
| Image processing | GLSL Fragment Shader (flutter_shaders) |
| Fisheye projection | MOIL polynomial mapping |