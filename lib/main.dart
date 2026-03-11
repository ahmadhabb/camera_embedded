import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:file_picker/file_picker.dart';

// Video & Shader packages
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:flutter_shaders/flutter_shaders.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const MoilShaderApp());
}

class MoilShaderApp extends StatelessWidget {
  const MoilShaderApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: ThemeData.dark(),
        home: const MoilShaderHome(),
        debugShowCheckedModeBanner: false,
      );
}

// ---------------------------------------------------------
// 1. ENGINE DATA (BENCHMARKING)
// ---------------------------------------------------------
class EngineData extends ChangeNotifier {
  double fps = 0.0;
  double frameTimeMs = 0.0;
  String memoryMB = "0";

  Timer? _timer;

  EngineData() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateSystemMetrics();
    });
  }

  void updateFrame(double currentFps, double currentMs) {
    fps = currentFps;
    frameTimeMs = currentMs;
    notifyListeners();
  }

  void _updateSystemMetrics() {
    final usage = ProcessInfo.currentRss / 1024 / 1024;
    memoryMB = usage.toStringAsFixed(1);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------
// 2. MOIL CONFIGURATION
// ---------------------------------------------------------
class MoilConfig extends ChangeNotifier {
  double mode = 0.0;
  double alpha = 0.0;
  double beta = 0.0;
  double zoom = 4.0;
  double alphaMax = 110.0;

  final double imageWidth = 2592.0;
  final double imageHeight = 1944.0;
  final double iCx = 1236.0;
  final double iCy = 950.0;
  final double calibrationRatio = 0.9;

  final double p0 = 0.0, p1 = 0.0, p2 = -34.367, p3 = 70.646, p4 = 41.608, p5 = 504.11;

  void updateControls(double a, double b, double z) {
    alpha = a;
    beta = b;
    zoom = z;
    notifyListeners();
  }

  void reset() {
    alpha = 0.0;
    beta = 0.0;
    zoom = 1.0;
    notifyListeners();
  }
}

// ---------------------------------------------------------
// 3. CAMERA SOURCE STATE
// ---------------------------------------------------------
enum VideoSource { none, file, camera }

// ---------------------------------------------------------
// 4. CAMERA SELECTION DIALOG
// ---------------------------------------------------------
class CameraSelectDialog extends StatefulWidget {
  const CameraSelectDialog({super.key});

  @override
  State<CameraSelectDialog> createState() => _CameraSelectDialogState();
}

class _CameraSelectDialogState extends State<CameraSelectDialog> {
  List<String> _devices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _detectCameras();
  }

  /// Mendeteksi kamera yang tersedia di Linux melalui /dev/video*
  Future<void> _detectCameras() async {
    try {
      final List<String> found = [];

      // Scan /dev/video0 sampai /dev/video9
      for (int i = 0; i <= 9; i++) {
        final devPath = '/dev/video$i';
        if (await File(devPath).exists()) {
          // Coba dapatkan nama device menggunakan v4l2-ctl jika tersedia
          String label = 'Camera $i ($devPath)';
          try {
            final result = await Process.run(
              'v4l2-ctl',
              ['--device=$devPath', '--info'],
              runInShell: true,
            );
            final output = result.stdout.toString();
            final match = RegExp(r'Card type\s+:\s+(.+)').firstMatch(output);
            if (match != null) {
              label = '${match.group(1)!.trim()} ($devPath)';
            }
          } catch (_) {
            // v4l2-ctl tidak tersedia, gunakan label default
          }
          found.add(label);
        }
      }

      setState(() {
        _devices = found;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.cyanAccent.withOpacity(0.3)),
      ),
      title: Row(
        children: const [
          Icon(Icons.videocam, color: Colors.cyanAccent, size: 20),
          SizedBox(width: 8),
          Text(
            'SELECT CAMERA',
            style: TextStyle(
              color: Colors.cyanAccent,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              letterSpacing: 2,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: _loading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(color: Colors.cyanAccent),
                ),
              )
            : _error != null
                ? Text(
                    'Error: $_error',
                    style: const TextStyle(color: Colors.redAccent),
                  )
                : _devices.isEmpty
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.no_photography, color: Colors.white38, size: 48),
                          const SizedBox(height: 12),
                          const Text(
                            'Tidak ada kamera yang terdeteksi.\nPastikan kamera terhubung dan driver tersedia.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54, fontSize: 13),
                          ),
                          const SizedBox(height: 16),
                          // Manual input fallback
                          _ManualCameraInput(),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ..._devices.asMap().entries.map((entry) {
                            final index = entry.key;
                            final label = entry.value;
                            final devPath = '/dev/video$index';
                            return ListTile(
                              leading: const Icon(Icons.camera_alt, color: Colors.cyanAccent),
                              title: Text(
                                label,
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                              ),
                              onTap: () => Navigator.of(context).pop(devPath),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              hoverColor: Colors.white10,
                            );
                          }),
                          const Divider(color: Colors.white12),
                          // Manual input sebagai opsi tambahan
                          _ManualCameraInput(),
                        ],
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('CANCEL', style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }
}

/// Widget input manual untuk path kamera kustom
class _ManualCameraInput extends StatefulWidget {
  @override
  State<_ManualCameraInput> createState() => _ManualCameraInputState();
}

class _ManualCameraInputState extends State<_ManualCameraInput> {
  final _controller = TextEditingController(text: '/dev/video0');

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: '/dev/video0',
              hintStyle: const TextStyle(color: Colors.white30),
              labelText: 'Path manual',
              labelStyle: const TextStyle(color: Colors.white38, fontSize: 11),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.white24),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Colors.white24),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.cyanAccent.withOpacity(0.2),
          ),
          child: const Text('OPEN', style: TextStyle(fontSize: 11)),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------
// 5. MAIN UI
// ---------------------------------------------------------
class MoilShaderHome extends StatefulWidget {
  const MoilShaderHome({super.key});
  @override
  State<MoilShaderHome> createState() => _MoilShaderHomeState();
}

class _MoilShaderHomeState extends State<MoilShaderHome> {
  final EngineData _engineData = EngineData();
  final MoilConfig _moilConfig = MoilConfig();

  late final Player _player = Player(
    configuration: const PlayerConfiguration(
      logLevel: MPVLogLevel.warn,
    ),
  );
  late final VideoController _videoController = VideoController(_player);

  ui.FragmentProgram? _program;
  DateTime _lastTick = DateTime.now();

  VideoSource _currentSource = VideoSource.none;
  String? _activeSourceLabel;
  String? _cameraResolution;

  @override
  void initState() {
    super.initState();
    _loadShader();
    _configureMpv();
  }

  /// Konfigurasi MPV untuk mode low-latency (penting untuk live camera)
  Future<void> _configureMpv() async {
    try {
      await (_player.platform as dynamic).setProperty('cache', 'no');
      await (_player.platform as dynamic).setProperty('untimed', 'yes');
      await (_player.platform as dynamic).setProperty('profile', 'low-latency');
    } catch (_) {
      // setProperty mungkin tidak tersedia di semua versi, abaikan error
    }
  }

  Future<void> _loadShader() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/anypoint.frag');
    setState(() => _program = program);
  }

  // --- LOAD VIDEO FILE ---
  Future<void> _pickVideo() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null) {
      final path = result.files.single.path!;
      await _player.open(Media(path));
      await _player.setVolume(0);
      await _player.play();
      setState(() {
        _currentSource = VideoSource.file;
        _activeSourceLabel = path.split('/').last;
      });
    }
  }

  // --- OPEN CAMERA ---
  Future<void> _openCamera() async {
    final String? selectedDevice = await showDialog<String>(
      context: context,
      builder: (context) => const CameraSelectDialog(),
    );

    if (selectedDevice == null || selectedDevice.isEmpty) return;

    try {
      await _player.stop();

      // Kamera output: yuvj422p (JPEG YUV 4:2:2 full-range).
      // Flutter/AnimatedSampler mengharapkan RGB — tanpa konversi eksplisit,
      // channel Y/U/V diinterpretasi sebagai R/G/B sehingga warna kacau.
      // vf=format=rgb24 → paksa MPV konversi ke RGB sebelum dikirim ke texture.
      // Ekuivalen CLI:
      //   mpv --demuxer-lavf-format=video4linux2 \
      //       --demuxer-lavf-o=video_size=2592x1944,pixel_format=mjpeg \
      //       --vf=format=rgb24 \
      //       /dev/video0
      final media = Media(
        selectedDevice,
        extras: {
          'demuxer-lavf-format': 'video4linux2',
          'demuxer-lavf-o': 'video_size=2592x1944,pixel_format=mjpeg',
          // Konversi yuvj422p → rgb24 agar warna benar di Flutter texture
          'vf': 'format=rgb24',
          'cache': 'no',
          'untimed': '',
        },
      );

      await _player.open(media, play: true);
      await _player.setVolume(0);

      setState(() {
        _currentSource = VideoSource.camera;
        _activeSourceLabel = selectedDevice;
        _cameraResolution = '2592×1944 MJPEG @ 30fps';
      });
    } catch (e) {
      if (!mounted) return;
      await _tryOpenCameraWithYUYV(selectedDevice);
    }
  }

  /// Fallback: paksa yuyv422 + konversi RGB
  Future<void> _tryOpenCameraWithYUYV(String devicePath) async {
    try {
      await _player.stop();
      final media = Media(
        devicePath,
        extras: {
          'demuxer-lavf-format': 'video4linux2',
          'demuxer-lavf-o': 'video_size=2592x1944,pixel_format=yuyv422',
          'vf': 'format=rgb24',
          'cache': 'no',
          'untimed': '',
        },
      );
      await _player.open(media, play: true);
      await _player.setVolume(0);

      setState(() {
        _currentSource = VideoSource.camera;
        _activeSourceLabel = devicePath;
        _cameraResolution = '2592×1944 YUYV @ 30fps';
      });
    } catch (e) {
      if (!mounted) return;
      await _tryOpenCameraFallback(devicePath);
    }
  }

  /// Fallback: gunakan URI av://v4l2:/dev/videoX jika path langsung gagal
  Future<void> _tryOpenCameraFallback(String devicePath) async {
    try {
      final cameraUri = 'av://v4l2:$devicePath';
      await _player.open(Media(cameraUri), play: true);
      await _player.setVolume(0);

      setState(() {
        _currentSource = VideoSource.camera;
        _activeSourceLabel = devicePath;
        _cameraResolution = '2592×1944 MJPEG @ 30fps';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Gagal membuka kamera "$devicePath": $e\n'
            'Pastikan tidak ada aplikasi lain yang menggunakan kamera.',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // --- STOP / DISCONNECT CAMERA ---
  Future<void> _stopCamera() async {
    await _player.stop();
    setState(() {
      _currentSource = VideoSource.none;
      _activeSourceLabel = null;
      _cameraResolution = null;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    double newAlpha = (_moilConfig.alpha + (details.delta.dy * 0.3)).clamp(-110.0, 110.0);
    double newBeta = _moilConfig.beta - (details.delta.dx * 0.3);
    if (newBeta > 180) newBeta -= 360;
    if (newBeta < -180) newBeta += 360;
    _moilConfig.updateControls(newAlpha, newBeta, _moilConfig.zoom);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _program != null
                        ? AnimatedBuilder(
                            animation: _moilConfig,
                            builder: (context, _) {
                              return Listener(
                                onPointerSignal: (event) {
                                  if (event is PointerScrollEvent) {
                                    double z = (_moilConfig.zoom + (event.scrollDelta.dy > 0 ? -0.2 : 0.2)).clamp(1.0, 12.0);
                                    _moilConfig.updateControls(_moilConfig.alpha, _moilConfig.beta, z);
                                  }
                                },
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanUpdate: _handlePanUpdate,
                                  onDoubleTap: () => _moilConfig.reset(),
                                  child: AnimatedSampler(
                                    (image, size, canvas) {
                                      final now = DateTime.now();
                                      final dt = now.difference(_lastTick).inMicroseconds / 1000000.0;
                                      if (dt > 0) {
                                        WidgetsBinding.instance.addPostFrameCallback((_) {
                                          if (mounted) _engineData.updateFrame(1.0 / dt, dt * 1000.0);
                                        });
                                      }
                                      _lastTick = now;

                                      final shader = _program!.fragmentShader();
                                      shader.setFloat(0, _moilConfig.mode);
                                      shader.setFloat(1, size.width);
                                      shader.setFloat(2, size.height);
                                      shader.setFloat(3, _moilConfig.alpha);
                                      shader.setFloat(4, _moilConfig.beta);
                                      shader.setFloat(5, _moilConfig.zoom);
                                      shader.setFloat(6, _moilConfig.alphaMax);
                                      shader.setFloat(7, _moilConfig.imageWidth);
                                      shader.setFloat(8, _moilConfig.imageHeight);
                                      shader.setFloat(9, _moilConfig.iCx);
                                      shader.setFloat(10, _moilConfig.iCy);
                                      shader.setFloat(11, _moilConfig.calibrationRatio);
                                      shader.setFloat(12, _moilConfig.p0);
                                      shader.setFloat(13, _moilConfig.p1);
                                      shader.setFloat(14, _moilConfig.p2);
                                      shader.setFloat(15, _moilConfig.p3);
                                      shader.setFloat(16, _moilConfig.p4);
                                      shader.setFloat(17, _moilConfig.p5);
                                      shader.setImageSampler(0, image);
                                      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
                                    },
                                    child: IgnorePointer(child: Video(controller: _videoController)),
                                  ),
                                ),
                              );
                            },
                          )
                        : const CircularProgressIndicator(),
                  ),
                ),
              ),
              _buildBottomConsole(),
            ],
          ),
          _buildPerformanceOverlay(),
          // Badge sumber aktif (kamera/file)
          if (_activeSourceLabel != null) _buildSourceBadge(),
        ],
      ),
    );
  }

  // --- WIDGETS ---

  Widget _buildPerformanceOverlay() {
    return Positioned(
      top: 40,
      left: 20,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListenableBuilder(
              listenable: _engineData,
              builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _perfRow(Icons.speed, "FPS", "${_engineData.fps.toStringAsFixed(1)}"),
                    _perfRow(Icons.timer, "FRAME", "${_engineData.frameTimeMs.toStringAsFixed(2)} ms"),
                    _perfRow(Icons.memory, "MEM", "${_engineData.memoryMB} MB"),
                  ],
                );
              },
            ),
            const Divider(color: Colors.white24, height: 15),
            ListenableBuilder(
              listenable: _moilConfig,
              builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _perfRow(Icons.zoom_in, "ALPHA", "${_moilConfig.alpha.toStringAsFixed(2)}°"),
                    _perfRow(Icons.zoom_out, "BETA ", "${_moilConfig.beta.toStringAsFixed(2)}°"),
                    _perfRow(Icons.zoom_in, "ZOOM ", "${_moilConfig.zoom.toStringAsFixed(2)}x"),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
            if (_cameraResolution != null) ...[
              _perfRow(Icons.hd, "RES  ", _cameraResolution!),
              const SizedBox(height: 4),
            ],
            const Text(
              "GPU: SHADER ACTIVE",
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Badge kecil di pojok kanan atas menampilkan sumber input aktif
  Widget _buildSourceBadge() {
    final isCamera = _currentSource == VideoSource.camera;
    return Positioned(
      top: 40,
      right: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.75),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCamera
                ? Colors.greenAccent.withOpacity(0.5)
                : Colors.blueAccent.withOpacity(0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Indikator live (animasi dot merah) untuk kamera
            if (isCamera)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _LiveDot(),
              ),
            Icon(
              isCamera ? Icons.videocam : Icons.movie,
              size: 14,
              color: isCamera ? Colors.greenAccent : Colors.blueAccent,
            ),
            const SizedBox(width: 6),
            Text(
              isCamera ? 'LIVE: $_activeSourceLabel' : _activeSourceLabel!,
              style: TextStyle(
                color: isCamera ? Colors.greenAccent : Colors.blueAccent,
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
            if (isCamera) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _stopCamera,
                child: const Icon(Icons.close, size: 14, color: Colors.white38),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _perfRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.cyanAccent),
          const SizedBox(width: 8),
          Text(
            "$label:",
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 5),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomConsole() {
    return Container(
      padding: const EdgeInsets.all(20),
      color: const Color(0xFF0D0D0D),
      child: Row(
        children: [
          // Tombol Load Video
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _pickVideo,
              icon: const Icon(Icons.folder),
              label: const Text("LOAD VIDEO SOURCE"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white10,
                padding: const EdgeInsets.all(20),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Tombol Open Camera (BARU)
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _currentSource == VideoSource.camera ? _stopCamera : _openCamera,
              icon: Icon(
                _currentSource == VideoSource.camera ? Icons.videocam_off : Icons.videocam,
              ),
              label: Text(
                _currentSource == VideoSource.camera ? "DISCONNECT CAMERA" : "OPEN CAMERA",
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentSource == VideoSource.camera
                    ? Colors.redAccent.withOpacity(0.25)
                    : Colors.greenAccent.withOpacity(0.15),
                foregroundColor: _currentSource == VideoSource.camera
                    ? Colors.redAccent
                    : Colors.greenAccent,
                side: BorderSide(
                  color: _currentSource == VideoSource.camera
                      ? Colors.redAccent.withOpacity(0.5)
                      : Colors.greenAccent.withOpacity(0.4),
                ),
                padding: const EdgeInsets.all(20),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Tombol Reset
          IconButton(
            onPressed: () => _moilConfig.reset(),
            icon: const Icon(Icons.refresh),
            color: Colors.cyanAccent,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------
// 6. LIVE DOT INDICATOR (animasi berkedip untuk kamera live)
// ---------------------------------------------------------
class _LiveDot extends StatefulWidget {
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.2, end: 1.0).animate(_ctrl);
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
}