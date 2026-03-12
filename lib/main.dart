import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
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
// 1. FFI BINDINGS — libcamera_bridge.so
// ---------------------------------------------------------
typedef _CameraInitC      = ffi.Void Function();
typedef _CameraOpenC      = ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Int32, ffi.Int32);
typedef _CameraCloseC     = ffi.Void Function();
typedef _CameraGetFrameC  = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>);
typedef _CameraIsRunningC = ffi.Int32 Function();
typedef _CameraWidthC     = ffi.Int32 Function();
typedef _CameraHeightC    = ffi.Int32 Function();

typedef _CameraInitDart      = void Function();
typedef _CameraOpenDart      = int Function(ffi.Pointer<Utf8>, int, int);
typedef _CameraCloseDart     = void Function();
typedef _CameraGetFrameDart  = int Function(ffi.Pointer<ffi.Uint8>);
typedef _CameraIsRunningDart = int Function();
typedef _CameraSizeDart      = int Function();

class CameraBridge {
  static CameraBridge? _instance;
  static CameraBridge get instance => _instance ??= CameraBridge._load();

  late final ffi.DynamicLibrary _lib;
  late final _CameraInitDart      init;
  late final _CameraOpenDart      open;
  late final _CameraCloseDart     close;
  late final _CameraGetFrameDart  getFrame;
  late final _CameraIsRunningDart isRunning;
  late final _CameraSizeDart      width;
  late final _CameraSizeDart      height;

  CameraBridge._load() {
    _lib = ffi.DynamicLibrary.open('linux/libcamera_bridge.so');
    init      = _lib.lookupFunction<_CameraInitC,      _CameraInitDart>     ('camera_init');
    open      = _lib.lookupFunction<_CameraOpenC,      _CameraOpenDart>     ('camera_open');
    close     = _lib.lookupFunction<_CameraCloseC,     _CameraCloseDart>    ('camera_close');
    getFrame  = _lib.lookupFunction<_CameraGetFrameC,  _CameraGetFrameDart> ('camera_get_frame');
    isRunning = _lib.lookupFunction<_CameraIsRunningC, _CameraIsRunningDart>('camera_is_running');
    width     = _lib.lookupFunction<_CameraWidthC,     _CameraSizeDart>     ('camera_width');
    height    = _lib.lookupFunction<_CameraHeightC,    _CameraSizeDart>     ('camera_height');
    init();
  }
}

// ---------------------------------------------------------
// 2. GSTREAMER CAMERA CONTROLLER
// ---------------------------------------------------------
class GstCameraController {
  // ✅ FIX: Resolusi disesuaikan dengan pipeline yang terbukti bekerja (640x480)
  //         Kalau mau 1920x1080, pastikan pipeline C juga 1920x1080
  final int captureWidth;
  final int captureHeight;

  ffi.Pointer<ffi.Uint8>? _framePtr;
  bool _opened = false;

  // ✅ Camera FPS tracking (bukan UI FPS)
  int _frameCount = 0;
  DateTime _fpsTimer = DateTime.now();
  DateTime _lastFrameTime = DateTime.now();
  double cameraFps = 0.0;
  double cameraFrameMs = 0.0;

  GstCameraController({
    this.captureWidth  = 1920,   // ✅ FIX: default 1920x1080, cocok dengan pipeline
    this.captureHeight = 1080,
  });

  Future<bool> open(String devicePath) async {
    final bridge = CameraBridge.instance;
    final bufSize = captureWidth * captureHeight * 4; // RGBA
    _framePtr = malloc.allocate<ffi.Uint8>(bufSize);

    final devUtf8 = devicePath.toNativeUtf8();
    final ok = bridge.open(devUtf8, captureWidth, captureHeight);
    malloc.free(devUtf8);

    if (ok == 0) {
      malloc.free(_framePtr!);
      _framePtr = null;
      return false;
    }
    _opened = true;
    return true;
  }

  Future<ui.Image?> grabFrame() async {
    if (!_opened || _framePtr == null) return null;

    final bridge = CameraBridge.instance;
    final hasNew = bridge.getFrame(_framePtr!);
    if (hasNew == 0) return null;

    // ✅ Hitung FPS dari frame kamera aktual (bukan UI render)
    final now = DateTime.now();
    final dt = now.difference(_lastFrameTime).inMicroseconds / 1000000.0;
    if (dt > 0) cameraFrameMs = dt * 1000.0;
    _lastFrameTime = now;
    _frameCount++;
    final elapsed = now.difference(_fpsTimer).inMilliseconds;
    if (elapsed >= 500) {
      cameraFps = _frameCount * 1000.0 / elapsed;
      _frameCount = 0;
      _fpsTimer = now;
    }

    final bytes     = _framePtr!.asTypedList(captureWidth * captureHeight * 4);
    final bytesCopy = Uint8List.fromList(bytes);

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytesCopy,
      captureWidth,
      captureHeight,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  void close() {
    if (_opened) {
      CameraBridge.instance.close();
      _opened = false;
    }
    if (_framePtr != null) {
      malloc.free(_framePtr!);
      _framePtr = null;
    }
  }

  bool get isRunning => _opened && CameraBridge.instance.isRunning() == 1;
}

// ---------------------------------------------------------
// 3. ENGINE DATA (BENCHMARKING)
// ---------------------------------------------------------
class EngineData extends ChangeNotifier {
  double fps = 0.0;
  double frameTimeMs = 0.0;
  String memoryMB = "0";

  Timer? _timer;

  EngineData() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateSystemMetrics());
  }

  void updateFrame(double currentFps, double currentMs) {
    fps = currentFps;
    frameTimeMs = currentMs;
    notifyListeners();
  }

  void _updateSystemMetrics() {
    memoryMB = (ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------
// 4. MOIL CONFIGURATION
// ---------------------------------------------------------
class MoilConfig extends ChangeNotifier {
  double mode = 0.0;
  double alpha = 0.0;
  double beta = 0.0;
  double zoom = 4.0;
  double alphaMax = 110.0;

  static const double _sensorWidth  = 2592.0;
  static const double _sensorHeight = 1944.0;
  static const double _sensorCx     = 1236.0;
  static const double _sensorCy     = 950.0;

  // ✅ FIX: sesuaikan dengan resolusi capture aktual
  static const double _captureWidth  = 1920.0;
  static const double _captureHeight = 1080.0;

  static const double _scaleX = _captureWidth  / _sensorWidth;
  static const double _scaleY = _captureHeight / _sensorHeight;

  double get imageWidth       => _captureWidth;
  double get imageHeight      => _captureHeight;
  double get iCx              => _sensorCx * _scaleX;
  double get iCy              => _sensorCy * _scaleY;
  double get calibrationRatio => 0.9 * ((_scaleX + _scaleY) / 2.0);

  final double p0 = 0.0, p1 = 0.0, p2 = -34.367,
               p3 = 70.646, p4 = 41.608, p5 = 504.11;

  void updateControls(double a, double b, double z) {
    alpha = a; beta = b; zoom = z;
    notifyListeners();
  }

  void reset() {
    alpha = 0.0; beta = 0.0; zoom = 1.0;
    notifyListeners();
  }
}

// ---------------------------------------------------------
// 5. ENUMS
// ---------------------------------------------------------
enum VideoSource { none, file, camera }
enum ViewMode { processed, original }

// ---------------------------------------------------------
// 6. CAMERA SELECTION DIALOG
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

  Future<void> _detectCameras() async {
    try {
      final List<String> found = [];
      for (int i = 0; i <= 9; i++) {
        final devPath = '/dev/video$i';
        if (await File(devPath).exists()) {
          String label = 'Camera $i ($devPath)';
          try {
            final result = await Process.run(
                'v4l2-ctl', ['--device=$devPath', '--info'], runInShell: true);
            final match = RegExp(r'Card type\s+:\s+(.+)')
                .firstMatch(result.stdout.toString());
            if (match != null) label = '${match.group(1)!.trim()} ($devPath)';
          } catch (_) {}
          found.add(label);
        }
      }
      setState(() { _devices = found; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
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
      title: Row(children: const [
        Icon(Icons.videocam, color: Colors.cyanAccent, size: 20),
        SizedBox(width: 8),
        Text('SELECT CAMERA', style: TextStyle(
          color: Colors.cyanAccent, fontSize: 14,
          fontWeight: FontWeight.bold, fontFamily: 'monospace', letterSpacing: 2,
        )),
      ]),
      content: SizedBox(
        width: 400,
        child: _loading
            ? const Center(child: Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(color: Colors.cyanAccent)))
            : _error != null
                ? Text('Error: $_error',
                    style: const TextStyle(color: Colors.redAccent))
                : _devices.isEmpty
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.no_photography,
                            color: Colors.white38, size: 48),
                        const SizedBox(height: 12),
                        const Text(
                          'Tidak ada kamera terdeteksi.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        _ManualInput(),
                      ])
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        ..._devices.asMap().entries.map((e) => ListTile(
                          leading: const Icon(Icons.camera_alt,
                              color: Colors.cyanAccent),
                          title: Text(e.value,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13)),
                          onTap: () =>
                              Navigator.of(context).pop('/dev/video${e.key}'),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6)),
                          hoverColor: Colors.white10,
                        )),
                        const Divider(color: Colors.white12),
                        _ManualInput(),
                      ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('CANCEL',
              style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }
}

class _ManualInput extends StatefulWidget {
  @override
  State<_ManualInput> createState() => _ManualInputState();
}

class _ManualInputState extends State<_ManualInput> {
  final _ctrl = TextEditingController(text: '/dev/video0');
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: TextField(
      controller: _ctrl,
      style: const TextStyle(
          color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
      decoration: InputDecoration(
        hintText: '/dev/video0',
        hintStyle: const TextStyle(color: Colors.white30),
        labelText: 'Path manual',
        labelStyle: const TextStyle(color: Colors.white38, fontSize: 11),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Colors.white24)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Colors.white24)),
      ),
    )),
    const SizedBox(width: 8),
    ElevatedButton(
      onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
      style: ElevatedButton.styleFrom(
          backgroundColor: Colors.cyanAccent.withOpacity(0.2)),
      child: const Text('OPEN', style: TextStyle(fontSize: 11)),
    ),
  ]);
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
}

// ---------------------------------------------------------
// 7. ORIGINAL IMAGE PAINTER
// ---------------------------------------------------------
class _OriginalImagePainter extends CustomPainter {
  final ui.Image image;
  _OriginalImagePainter({required this.image});

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Offset.zero & size;
    canvas.drawImageRect(image, src, dst, Paint());
  }

  @override
  bool shouldRepaint(_OriginalImagePainter old) => image != old.image;
}

// ---------------------------------------------------------
// 8. MAIN UI
// ---------------------------------------------------------
class MoilShaderHome extends StatefulWidget {
  const MoilShaderHome({super.key});
  @override
  State<MoilShaderHome> createState() => _MoilShaderHomeState();
}

class _MoilShaderHomeState extends State<MoilShaderHome>
    with SingleTickerProviderStateMixin {
  final EngineData _engineData = EngineData();
  final MoilConfig _moilConfig = MoilConfig();
  ViewMode _viewMode = ViewMode.processed;

  late final Player _player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
  late final VideoController _videoController = VideoController(_player);

  GstCameraController? _gstCamera;
  ui.Image? _cameraFrame;
  Ticker? _cameraTicker;

  ui.FragmentProgram? _program;
  DateTime _lastTick = DateTime.now();

  VideoSource _currentSource = VideoSource.none;
  String? _activeSourceLabel;
  String? _cameraResolution;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  Future<void> _loadShader() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/anypoint.frag');
    setState(() => _program = program);
  }

  void _toggleViewMode() {
    setState(() {
      _viewMode = _viewMode == ViewMode.processed
          ? ViewMode.original
          : ViewMode.processed;
    });
  }

  Future<void> _pickVideo() async {
    await _stopCamera();
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null) {
      final path = result.files.single.path!;
      await _player.open(Media(path));
      await _player.setVolume(0);
      await _player.play();
      setState(() {
        _currentSource     = VideoSource.file;
        _activeSourceLabel = path.split('/').last;
        _cameraResolution  = null;
      });
    }
  }

  Future<void> _openCamera() async {
    final String? device = await showDialog<String>(
      context: context,
      builder: (_) => const CameraSelectDialog(),
    );
    if (device == null || device.isEmpty) return;

    await _player.stop();

    // ✅ FIX: Gunakan 640x480 — resolusi yang terbukti bekerja di pipeline
    //         Ganti ke 1920x1080 jika kamera dan pipeline sudah dikonfirmasi support
    final cam = GstCameraController(captureWidth: 1920, captureHeight: 1080);
    final ok = await cam.open(device);

    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'GStreamer gagal membuka "$device".\n'
          'Test manual: gst-launch-1.0 v4l2src device=$device '
          '! image/jpeg,width=1920,height=1080 ! jpegdec ! videoconvert '
          '! video/x-raw,format=RGBA ! fakesink',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
      ));
      cam.close();
      return;
    }

    _gstCamera = cam;

    // ✅ FIX: Update FPS dari kamera, bukan dari render loop
    _cameraTicker = createTicker((_) async {
      if (_gstCamera == null) return;
      final frame = await _gstCamera!.grabFrame();
      if (frame != null && mounted) {
        _cameraFrame?.dispose();
        _engineData.updateFrame(
          _gstCamera!.cameraFps,
          _gstCamera!.cameraFrameMs,
        );
        setState(() => _cameraFrame = frame);
      }
    })..start();

    setState(() {
      _currentSource     = VideoSource.camera;
      _activeSourceLabel = device;
      _cameraResolution  = '640×480 GStreamer MJPEG';
    });
  }

  Future<void> _stopCamera() async {
    _cameraTicker?.dispose();
    _cameraTicker = null;
    _gstCamera?.close();
    _gstCamera = null;
    _cameraFrame?.dispose();
    _cameraFrame = null;
    setState(() {
      _currentSource     = VideoSource.none;
      _activeSourceLabel = null;
      _cameraResolution  = null;
    });
  }

  @override
  void dispose() {
    _cameraTicker?.dispose();
    _gstCamera?.close();
    _cameraFrame?.dispose();
    _engineData.dispose();
    super.dispose();
  }

  void _handlePanUpdate(DragUpdateDetails d) {
    double a = (_moilConfig.alpha + d.delta.dy * 0.3).clamp(-110.0, 110.0);
    double b = _moilConfig.beta - d.delta.dx * 0.3;
    if (b >  180) b -= 360;
    if (b < -180) b += 360;
    _moilConfig.updateControls(a, b, _moilConfig.zoom);
  }

  void _paintOriginalImage(Canvas canvas, ui.Image image, Size size) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.drawImageRect(image, src, Offset.zero & size, Paint());
  }

  Widget _buildShaderView(Size size) {
    // ✅ FIX: Tampilkan loading state saat kamera terbuka tapi frame belum datang
    if (_currentSource == VideoSource.camera && _cameraFrame == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.cyanAccent),
            SizedBox(height: 12),
            Text('Waiting for camera frame...',
                style: TextStyle(color: Colors.white54, fontSize: 12,
                    fontFamily: 'monospace')),
          ],
        ),
      );
    }

    if (_viewMode == ViewMode.original) {
      if (_currentSource == VideoSource.camera && _cameraFrame != null) {
        return CustomPaint(
          painter: _OriginalImagePainter(image: _cameraFrame!),
          size: Size.infinite,
        );
      } else if (_currentSource == VideoSource.file) {
        return IgnorePointer(child: Video(controller: _videoController));
      }
    }

    if (_currentSource == VideoSource.camera && _cameraFrame != null) {
      return _GstShaderPainter(
        image:   _cameraFrame!,
        program: _program!,
        config:  _moilConfig,
        onFrame: (fps, ms) {}, // FPS sudah di-update dari ticker
      );
    }

    // Mode video file
    return UnconstrainedBox(
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: AnimatedSampler(
          (image, sz, canvas) {
            final now = DateTime.now();
            final dt  = now.difference(_lastTick).inMicroseconds / 1000000.0;
            if (dt > 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _engineData.updateFrame(1.0 / dt, dt * 1000.0);
              });
            }
            _lastTick = now;
            if (_viewMode == ViewMode.processed) {
              _applyShader(_program!.fragmentShader(), image, sz, canvas);
            } else {
              _paintOriginalImage(canvas, image, sz);
            }
          },
          child: IgnorePointer(child: Video(controller: _videoController)),
        ),
      ),
    );
  }

  void _applyShader(
      ui.FragmentShader shader, ui.Image image, Size size, Canvas canvas) {
    shader.setFloat(0,  _moilConfig.mode);
    shader.setFloat(1,  size.width);
    shader.setFloat(2,  size.height);
    shader.setFloat(3,  _moilConfig.alpha);
    shader.setFloat(4,  _moilConfig.beta);
    shader.setFloat(5,  _moilConfig.zoom);
    shader.setFloat(6,  _moilConfig.alphaMax);
    shader.setFloat(7,  _moilConfig.imageWidth);
    shader.setFloat(8,  _moilConfig.imageHeight);
    shader.setFloat(9,  _moilConfig.iCx);
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Column(children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _program != null
                    ? AnimatedBuilder(
                        animation: _moilConfig,
                        builder: (ctx, _) => Listener(
                          onPointerSignal: (ev) {
                            if (ev is PointerScrollEvent) {
                              final z = (_moilConfig.zoom +
                                  (ev.scrollDelta.dy > 0 ? -0.2 : 0.2))
                                  .clamp(1.0, 12.0);
                              _moilConfig.updateControls(
                                  _moilConfig.alpha, _moilConfig.beta, z);
                            }
                          },
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: _handlePanUpdate,
                            onDoubleTap: _moilConfig.reset,
                            child: LayoutBuilder(builder: (_, constraints) {
                              final availableSize = constraints.biggest;
                              if (_currentSource == VideoSource.camera) {
                                return _buildShaderView(availableSize);
                              }
                              return ClipRect(
                                child: OverflowBox(
                                  maxWidth: double.infinity,
                                  maxHeight: double.infinity,
                                  child: _buildShaderView(availableSize),
                                ),
                              );
                            }),
                          ),
                        ),
                      )
                    : const CircularProgressIndicator(),
              ),
            ),
          ),
          _buildBottomConsole(),
        ]),
        _buildPerformanceOverlay(),
        if (_activeSourceLabel != null) _buildSourceBadge(),
        _buildViewModeButton(),
      ]),
    );
  }

  Widget _buildViewModeButton() {
    return Positioned(
      top: 40,
      right: 220,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.75),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _viewMode == ViewMode.processed
                ? Colors.cyanAccent.withOpacity(0.5)
                : Colors.amber.withOpacity(0.5),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _toggleViewMode,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                  _viewMode == ViewMode.processed
                      ? Icons.auto_awesome : Icons.image,
                  size: 14,
                  color: _viewMode == ViewMode.processed
                      ? Colors.cyanAccent : Colors.amber,
                ),
                const SizedBox(width: 6),
                Text(
                  _viewMode == ViewMode.processed ? 'SHADER' : 'ORIGINAL',
                  style: TextStyle(
                    color: _viewMode == ViewMode.processed
                        ? Colors.cyanAccent : Colors.amber,
                    fontSize: 10, fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPerformanceOverlay() {
    return Positioned(
      top: 40, left: 20,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _viewMode == ViewMode.processed
                  ? Colors.cyanAccent.withOpacity(0.2)
                  : Colors.amber.withOpacity(0.2),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _viewMode == ViewMode.processed
                    ? Colors.cyanAccent.withOpacity(0.5)
                    : Colors.amber.withOpacity(0.5),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                _viewMode == ViewMode.processed
                    ? Icons.auto_awesome : Icons.image,
                size: 12,
                color: _viewMode == ViewMode.processed
                    ? Colors.cyanAccent : Colors.amber,
              ),
              const SizedBox(width: 4),
              Text(
                _viewMode == ViewMode.processed ? 'SHADER ACTIVE' : 'ORIGINAL VIEW',
                style: TextStyle(
                  color: _viewMode == ViewMode.processed
                      ? Colors.cyanAccent : Colors.amber,
                  fontSize: 9, fontWeight: FontWeight.bold,
                ),
              ),
            ]),
          ),
          ListenableBuilder(
            listenable: _engineData,
            builder: (_, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ✅ Label CAMERA FPS jika source kamera
                _perfRow(Icons.speed, 
                    _currentSource == VideoSource.camera ? "CAM FPS" : "FPS",
                    "${_engineData.fps.toStringAsFixed(1)}"),
                _perfRow(Icons.timer,  "FRAME",
                    "${_engineData.frameTimeMs.toStringAsFixed(2)} ms"),
                _perfRow(Icons.memory, "MEM",
                    "${_engineData.memoryMB} MB"),
              ],
            ),
          ),
          const Divider(color: Colors.white24, height: 15),
          ListenableBuilder(
            listenable: _moilConfig,
            builder: (_, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _perfRow(Icons.explore,     "ALPHA",
                    "${_moilConfig.alpha.toStringAsFixed(2)}°"),
                _perfRow(Icons.rotate_left, "BETA ",
                    "${_moilConfig.beta.toStringAsFixed(2)}°"),
                _perfRow(Icons.zoom_in,     "ZOOM ",
                    "${_moilConfig.zoom.toStringAsFixed(2)}x"),
              ],
            ),
          ),
          if (_cameraResolution != null) ...[
            const SizedBox(height: 4),
            _perfRow(Icons.hd, "RES  ", _cameraResolution!),
          ],
          const SizedBox(height: 6),
          const Text("GPU: SHADER ACTIVE", style: TextStyle(
              color: Colors.orangeAccent,
              fontSize: 9, fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }

  Widget _buildSourceBadge() {
    final isCamera = _currentSource == VideoSource.camera;
    return Positioned(
      top: 40, right: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.75),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isCamera
              ? Colors.greenAccent.withOpacity(0.5)
              : Colors.blueAccent.withOpacity(0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (isCamera)
            Padding(padding: const EdgeInsets.only(right: 6),
                child: _LiveDot()),
          Icon(isCamera ? Icons.videocam : Icons.movie,
              size: 14,
              color: isCamera ? Colors.greenAccent : Colors.blueAccent),
          const SizedBox(width: 6),
          Text(
            isCamera ? 'LIVE: $_activeSourceLabel' : _activeSourceLabel!,
            style: TextStyle(
              color: isCamera ? Colors.greenAccent : Colors.blueAccent,
              fontSize: 10, fontFamily: 'monospace',
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
        ]),
      ),
    );
  }

  Widget _perfRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: Colors.cyanAccent),
        const SizedBox(width: 8),
        Text("$label:", style: const TextStyle(
            color: Colors.white70, fontSize: 11, fontFamily: 'monospace')),
        const SizedBox(width: 5),
        Text(value, style: const TextStyle(
            color: Colors.white, fontSize: 12,
            fontWeight: FontWeight.bold, fontFamily: 'monospace')),
      ]),
    );
  }

  Widget _buildBottomConsole() {
    return Container(
      padding: const EdgeInsets.all(20),
      color: const Color(0xFF0D0D0D),
      child: Row(children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _pickVideo,
            icon: const Icon(Icons.folder),
            label: const Text("LOAD VIDEO SOURCE"),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white10,
                padding: const EdgeInsets.all(20)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _currentSource == VideoSource.camera
                ? _stopCamera : _openCamera,
            icon: Icon(_currentSource == VideoSource.camera
                ? Icons.videocam_off : Icons.videocam),
            label: Text(_currentSource == VideoSource.camera
                ? "DISCONNECT CAMERA" : "OPEN CAMERA"),
            style: ElevatedButton.styleFrom(
              backgroundColor: _currentSource == VideoSource.camera
                  ? Colors.redAccent.withOpacity(0.25)
                  : Colors.greenAccent.withOpacity(0.15),
              foregroundColor: _currentSource == VideoSource.camera
                  ? Colors.redAccent : Colors.greenAccent,
              side: BorderSide(color: _currentSource == VideoSource.camera
                  ? Colors.redAccent.withOpacity(0.5)
                  : Colors.greenAccent.withOpacity(0.4)),
              padding: const EdgeInsets.all(20),
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton(
          onPressed: _moilConfig.reset,
          icon: const Icon(Icons.refresh),
          color: Colors.cyanAccent,
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------
// 9. GST SHADER PAINTER
// ---------------------------------------------------------
class _GstShaderPainter extends StatefulWidget {
  final ui.Image image;
  final ui.FragmentProgram program;
  final MoilConfig config;
  final void Function(double fps, double ms) onFrame;

  const _GstShaderPainter({
    required this.image,
    required this.program,
    required this.config,
    required this.onFrame,
  });

  @override
  State<_GstShaderPainter> createState() => _GstShaderPainterState();
}

class _GstShaderPainterState extends State<_GstShaderPainter> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.config,
      builder: (_, __) => CustomPaint(
        painter: _MoilPainter(
          image:   widget.image,
          program: widget.program,
          config:  widget.config,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _MoilPainter extends CustomPainter {
  final ui.Image image;
  final ui.FragmentProgram program;
  final MoilConfig config;

  _MoilPainter({
    required this.image,
    required this.program,
    required this.config,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    shader.setFloat(0,  config.mode);
    shader.setFloat(1,  size.width);
    shader.setFloat(2,  size.height);
    shader.setFloat(3,  config.alpha);
    shader.setFloat(4,  config.beta);
    shader.setFloat(5,  config.zoom);
    shader.setFloat(6,  config.alphaMax);
    shader.setFloat(7,  config.imageWidth);
    shader.setFloat(8,  config.imageHeight);
    shader.setFloat(9,  config.iCx);
    shader.setFloat(10, config.iCy);
    shader.setFloat(11, config.calibrationRatio);
    shader.setFloat(12, config.p0);
    shader.setFloat(13, config.p1);
    shader.setFloat(14, config.p2);
    shader.setFloat(15, config.p3);
    shader.setFloat(16, config.p4);
    shader.setFloat(17, config.p5);
    shader.setImageSampler(0, image);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_MoilPainter old) => image != old.image || config != old.config;
}

// ---------------------------------------------------------
// 10. LIVE DOT INDICATOR
// ---------------------------------------------------------
class _LiveDot extends StatefulWidget {
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  late final Animation<double> _anim =
      Tween<double>(begin: 0.2, end: 1.0).animate(_ctrl);

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _anim,
        child: Container(
          width: 7, height: 7,
          decoration: const BoxDecoration(
              color: Colors.redAccent, shape: BoxShape.circle),
        ),
      );

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
}