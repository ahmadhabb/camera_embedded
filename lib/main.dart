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
// 1. FFI BINDINGS
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
// 2. GSTREAMER CAMERA CONTROLLER (OPTIMIZED)
// ---------------------------------------------------------
class GstCameraController {
  final int captureWidth;
  final int captureHeight;

  ffi.Pointer<ffi.Uint8>? _framePtr;
  bool _opened = false;

  int      _frameCount   = 0;
  DateTime _fpsTimer     = DateTime.now();
  DateTime _lastFrameTime = DateTime.now();
  double   cameraFps     = 0.0;
  double   cameraFrameMs = 0.0;

  GstCameraController({this.captureWidth = 1920, this.captureHeight = 1080});

  Future<bool> open(String devicePath) async {
    _framePtr = malloc.allocate<ffi.Uint8>(captureWidth * captureHeight * 4);
    final devUtf8 = devicePath.toNativeUtf8();
    final ok = CameraBridge.instance.open(devUtf8, captureWidth, captureHeight);
    malloc.free(devUtf8);
    if (ok == 0) { malloc.free(_framePtr!); _framePtr = null; return false; }
    _opened = true;
    return true;
  }

  Future<ui.Image?> grabFrame() async {
    if (!_opened || _framePtr == null) return null;
    if (CameraBridge.instance.getFrame(_framePtr!) == 0) return null;

    // FPS tracking
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

    // ✅ OPT 1: asTypedList langsung — tidak ada double copy
    final bytes = _framePtr!.asTypedList(captureWidth * captureHeight * 4);
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, captureWidth, captureHeight,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  void close() {
    if (_opened) { CameraBridge.instance.close(); _opened = false; }
    if (_framePtr != null) { malloc.free(_framePtr!); _framePtr = null; }
  }

  bool get isRunning => _opened && CameraBridge.instance.isRunning() == 1;
}

// ---------------------------------------------------------
// 3. ENGINE DATA
// ---------------------------------------------------------
class EngineData extends ChangeNotifier {
  double fps = 0.0;
  double frameTimeMs = 0.0;
  String memoryMB = "0";
  Timer? _timer;

  EngineData() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      memoryMB = (ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1);
      notifyListeners();
    });
  }

  void updateFrame(double f, double ms) { fps = f; frameTimeMs = ms; notifyListeners(); }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
}

// ---------------------------------------------------------
// 4. MOIL CONFIG — tiap view punya parameter sendiri
// ---------------------------------------------------------
class MoilConfig extends ChangeNotifier {
  final List<double> alphas = [0.0,  0.0,   0.0,   0.0];
  final List<double> betas  = [0.0,  90.0,  180.0, 270.0];
  final List<double> zooms  = [4.0,  4.0,   4.0,   4.0];

  double mode     = 0.0;
  double alphaMax = 110.0;

  static const double _sensorWidth  = 2592.0;
  static const double _sensorHeight = 1944.0;
  static const double _sensorCx     = 1236.0;
  static const double _sensorCy     = 950.0;
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

  void updateView(int i, double a, double b, double z) {
    alphas[i] = a; betas[i] = b; zooms[i] = z;
    notifyListeners();
  }

  void resetView(int i) {
    alphas[i] = 0.0;
    betas[i]  = [0.0, 90.0, 180.0, 270.0][i];
    zooms[i]  = 4.0;
    notifyListeners();
  }

  void resetAll() { for (int i = 0; i < 4; i++) resetView(i); }
}

// ---------------------------------------------------------
// 5. ENUMS
// ---------------------------------------------------------
enum VideoSource { none, file, camera }
enum ViewMode { processed, original }

// ---------------------------------------------------------
// 6. SHADER HELPER
// ---------------------------------------------------------
void applyMoilShader(ui.FragmentShader shader, ui.Image image,
    Size size, Canvas canvas, MoilConfig cfg, int idx) {
  shader.setFloat(0,  cfg.mode);
  shader.setFloat(1,  size.width);
  shader.setFloat(2,  size.height);
  shader.setFloat(3,  cfg.alphas[idx]);
  shader.setFloat(4,  cfg.betas[idx]);
  shader.setFloat(5,  cfg.zooms[idx]);
  shader.setFloat(6,  cfg.alphaMax);
  shader.setFloat(7,  cfg.imageWidth);
  shader.setFloat(8,  cfg.imageHeight);
  shader.setFloat(9,  cfg.iCx);
  shader.setFloat(10, cfg.iCy);
  shader.setFloat(11, cfg.calibrationRatio);
  shader.setFloat(12, cfg.p0);
  shader.setFloat(13, cfg.p1);
  shader.setFloat(14, cfg.p2);
  shader.setFloat(15, cfg.p3);
  shader.setFloat(16, cfg.p4);
  shader.setFloat(17, cfg.p5);
  shader.setImageSampler(0, image);
  canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
}

// ---------------------------------------------------------
// 7. PAINTERS
// ---------------------------------------------------------
class _ImagePainter extends CustomPainter {
  final ui.Image image;
  _ImagePainter({required this.image});
  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawImageRect(image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Offset.zero & size, Paint());
  @override
  bool shouldRepaint(_ImagePainter old) => image != old.image;
}

class _MoilPainter extends CustomPainter {
  final ui.Image image;
  final ui.FragmentProgram program;
  final MoilConfig config;
  final int viewIndex;

  _MoilPainter({required this.image, required this.program,
      required this.config, required this.viewIndex});

  @override
  void paint(Canvas canvas, Size size) =>
      applyMoilShader(program.fragmentShader(), image, size, canvas, config, viewIndex);

  @override
  bool shouldRepaint(_MoilPainter o) =>
      image != o.image ||
      config.alphas[viewIndex] != o.config.alphas[viewIndex] ||
      config.betas[viewIndex]  != o.config.betas[viewIndex]  ||
      config.zooms[viewIndex]  != o.config.zooms[viewIndex];
}

// ---------------------------------------------------------
// 8. CAMERA SELECTION DIALOG
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
  void initState() { super.initState(); _detectCameras(); }

  Future<void> _detectCameras() async {
    try {
      final List<String> found = [];
      for (int i = 0; i <= 9; i++) {
        final devPath = '/dev/video$i';
        if (await File(devPath).exists()) {
          String label = 'Camera $i ($devPath)';
          try {
            final r = await Process.run('v4l2-ctl',
                ['--device=$devPath', '--info'], runInShell: true);
            final m = RegExp(r'Card type\s+:\s+(.+)').firstMatch(r.stdout.toString());
            if (m != null) label = '${m.group(1)!.trim()} ($devPath)';
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
        Text('SELECT CAMERA', style: TextStyle(color: Colors.cyanAccent,
            fontSize: 14, fontWeight: FontWeight.bold,
            fontFamily: 'monospace', letterSpacing: 2)),
      ]),
      content: SizedBox(
        width: 400,
        child: _loading
            ? const Center(child: Padding(padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(color: Colors.cyanAccent)))
            : _error != null
                ? Text('Error: $_error', style: const TextStyle(color: Colors.redAccent))
                : _devices.isEmpty
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.no_photography, color: Colors.white38, size: 48),
                        const SizedBox(height: 12),
                        const Text('Tidak ada kamera terdeteksi.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54, fontSize: 13)),
                        const SizedBox(height: 16),
                        _ManualInput(),
                      ])
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        ..._devices.asMap().entries.map((e) => ListTile(
                          leading: const Icon(Icons.camera_alt, color: Colors.cyanAccent),
                          title: Text(e.value,
                              style: const TextStyle(color: Colors.white, fontSize: 13)),
                          onTap: () => Navigator.of(context).pop('/dev/video${e.key}'),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          hoverColor: Colors.white10,
                        )),
                        const Divider(color: Colors.white12),
                        _ManualInput(),
                      ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(null),
            child: const Text('CANCEL', style: TextStyle(color: Colors.white38))),
      ],
    );
  }
}

class _ManualInput extends StatefulWidget {
  @override State<_ManualInput> createState() => _ManualInputState();
}

class _ManualInputState extends State<_ManualInput> {
  final _ctrl = TextEditingController(text: '/dev/video0');
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: TextField(
      controller: _ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
      decoration: InputDecoration(
        hintText: '/dev/video0', hintStyle: const TextStyle(color: Colors.white30),
        labelText: 'Path manual', labelStyle: const TextStyle(color: Colors.white38, fontSize: 11),
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
      style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent.withOpacity(0.2)),
      child: const Text('OPEN', style: TextStyle(fontSize: 11)),
    ),
  ]);
  @override void dispose() { _ctrl.dispose(); super.dispose(); }
}

// ---------------------------------------------------------
// 9. MAIN HOME
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
  int _activeView = 0;

  late final Player _player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
  late final VideoController _videoController = VideoController(_player);

  GstCameraController? _gstCamera;
  ui.Image? _cameraFrame;
  Ticker? _cameraTicker;
  bool _isProcessing = false; // ✅ OPT: guard overlap

  ui.FragmentProgram? _program;
  VideoSource _currentSource = VideoSource.none;
  String? _activeSourceLabel;
  String? _cameraResolution;

  static const _viewLabels = ['V1 · 0°', 'V2 · 90°', 'V3 · 180°', 'V4 · 270°'];

  @override
  void initState() { super.initState(); _loadShader(); }

  Future<void> _loadShader() async {
    final p = await ui.FragmentProgram.fromAsset('shaders/anypoint.frag');
    setState(() => _program = p);
  }

  void _toggleViewMode() => setState(() =>
      _viewMode = _viewMode == ViewMode.processed ? ViewMode.original : ViewMode.processed);

  Future<void> _pickVideo() async {
    await _stopCamera();
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null) {
      final path = result.files.single.path!;
      await _player.open(Media(path));
      await _player.setVolume(0);
      await _player.play();
      setState(() {
        _currentSource = VideoSource.file;
        _activeSourceLabel = path.split('/').last;
        _cameraResolution = null;
      });
    }
  }

  Future<void> _openCamera() async {
    final String? device = await showDialog<String>(
        context: context, builder: (_) => const CameraSelectDialog());
    if (device == null || device.isEmpty) return;
    await _player.stop();

    final cam = GstCameraController(captureWidth: 1920, captureHeight: 1080);
    if (!await cam.open(device)) {
      if (!mounted) return;
      cam.close();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('GStreamer gagal membuka "$device".',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    _gstCamera = cam;

    // ✅ OPT: _isProcessing guard mencegah tumpukan async
    _cameraTicker = createTicker((_) async {
      if (_isProcessing || _gstCamera == null) return;
      _isProcessing = true;
      try {
        final frame = await _gstCamera!.grabFrame();
        if (frame != null && mounted) {
          _cameraFrame?.dispose();
          _engineData.updateFrame(_gstCamera!.cameraFps, _gstCamera!.cameraFrameMs);
          setState(() => _cameraFrame = frame);
        }
      } finally {
        _isProcessing = false;
      }
    })..start();

    setState(() {
      _currentSource = VideoSource.camera;
      _activeSourceLabel = device;
      _cameraResolution = '1920×1080 MJPEG';
    });
  }

  Future<void> _stopCamera() async {
    _cameraTicker?.dispose(); _cameraTicker = null;
    _isProcessing = false;
    _gstCamera?.close(); _gstCamera = null;
    _cameraFrame?.dispose(); _cameraFrame = null;
    setState(() {
      _currentSource = VideoSource.none;
      _activeSourceLabel = null;
      _cameraResolution = null;
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

  void _handlePan(DragUpdateDetails d, int idx) {
    double a = (_moilConfig.alphas[idx] + d.delta.dy * 0.3).clamp(-110.0, 110.0);
    double b = _moilConfig.betas[idx] - d.delta.dx * 0.3;
    if (b >  180) b -= 360;
    if (b < -180) b += 360;
    _moilConfig.updateView(idx, a, b, _moilConfig.zooms[idx]);
  }

  void _handleScroll(PointerScrollEvent ev, int idx) {
    final z = (_moilConfig.zooms[idx] + (ev.scrollDelta.dy > 0 ? -0.2 : 0.2))
        .clamp(1.0, 12.0);
    _moilConfig.updateView(idx, _moilConfig.alphas[idx], _moilConfig.betas[idx], z);
  }

  // ── BUILD ────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080808),
      body: Column(children: [
        _buildTopBar(),
        Expanded(child: _buildGrid()),
        _buildBottomBar(),
      ]),
    );
  }

  // ── 4-VIEW GRID ──────────────────────────────────────
  Widget _buildGrid() {
    if (_program == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.cyanAccent));
    }
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 2,
      mainAxisSpacing: 2,
      padding: const EdgeInsets.all(2),
      childAspectRatio: 16 / 9,
      physics: const NeverScrollableScrollPhysics(),
      children: List.generate(4, _buildCell),
    );
  }

  Widget _buildCell(int idx) {
    final isActive = _activeView == idx;
    return GestureDetector(
      onTap: () => setState(() => _activeView = idx),
      onDoubleTap: () => _moilConfig.resetView(idx),
      onPanUpdate: (d) => _handlePan(d, idx),
      child: Listener(
        onPointerSignal: (ev) {
          if (ev is PointerScrollEvent) _handleScroll(ev, idx);
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: isActive ? Colors.cyanAccent : Colors.cyanAccent.withOpacity(0.15),
              width: isActive ? 1.5 : 0.5,
            ),
          ),
          child: Stack(children: [
            // ── Content ──
            _buildCellContent(idx),

            // ── Per-view stats (kiri atas) ──
            Positioned(
              top: 4, left: 4,
              child: ListenableBuilder(
                listenable: _moilConfig,
                builder: (_, __) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _miniLabel('α ${_moilConfig.alphas[idx].toStringAsFixed(1)}°'),
                    _miniLabel('β ${_moilConfig.betas[idx].toStringAsFixed(1)}°'),
                    _miniLabel('Z ${_moilConfig.zooms[idx].toStringAsFixed(1)}x'),
                  ],
                ),
              ),
            ),

            // ── View label (kanan atas) ──
            Positioned(
              top: 4, right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: isActive
                      ? Colors.cyanAccent.withOpacity(0.2)
                      : Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: isActive
                        ? Colors.cyanAccent.withOpacity(0.7)
                        : Colors.white12,
                  ),
                ),
                child: Text(_viewLabels[idx], style: TextStyle(
                  color: isActive ? Colors.cyanAccent : Colors.white38,
                  fontSize: 8, fontFamily: 'monospace', fontWeight: FontWeight.bold,
                )),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildCellContent(int idx) {
    // Loading
    if (_currentSource == VideoSource.camera && _cameraFrame == null) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: Colors.cyanAccent, strokeWidth: 2),
        SizedBox(height: 6),
        Text('Waiting for frame...', style: TextStyle(
            color: Colors.white30, fontSize: 9, fontFamily: 'monospace')),
      ]));
    }

    // Original view
    if (_viewMode == ViewMode.original) {
      if (_currentSource == VideoSource.camera && _cameraFrame != null) {
        return CustomPaint(painter: _ImagePainter(image: _cameraFrame!), size: Size.infinite);
      }
      if (_currentSource == VideoSource.file) {
        return IgnorePointer(child: Video(controller: _videoController));
      }
      return _noSource();
    }

    // Processed — kamera
    if (_currentSource == VideoSource.camera && _cameraFrame != null) {
      return AnimatedBuilder(
        animation: _moilConfig,
        builder: (_, __) => CustomPaint(
          painter: _MoilPainter(
            image: _cameraFrame!, program: _program!,
            config: _moilConfig, viewIndex: idx,
          ),
          size: Size.infinite,
        ),
      );
    }

    // Processed — video file
    // Catatan: 4 view pakai AnimatedSampler dari sumber yang sama,
    // masing-masing dengan parameter beta berbeda
    if (_currentSource == VideoSource.file) {
      return AnimatedSampler(
        (image, sz, canvas) => applyMoilShader(
            _program!.fragmentShader(), image, sz, canvas, _moilConfig, idx),
        child: IgnorePointer(child: Video(controller: _videoController)),
      );
    }

    return _noSource();
  }

  Widget _noSource() => const Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.videocam_off, color: Colors.white12, size: 28),
      SizedBox(height: 4),
      Text('No source', style: TextStyle(color: Colors.white24, fontSize: 9, fontFamily: 'monospace')),
    ]),
  );

  Widget _miniLabel(String text) => Container(
    margin: const EdgeInsets.only(bottom: 1),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(2),
    ),
    child: Text(text, style: const TextStyle(
        color: Colors.white60, fontSize: 8, fontFamily: 'monospace')),
  );

  // ── TOP BAR ──────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        border: Border(bottom: BorderSide(color: Colors.cyanAccent.withOpacity(0.2))),
      ),
      child: Row(children: [
        const Icon(Icons.grid_view, color: Colors.cyanAccent, size: 14),
        const SizedBox(width: 6),
        const Text('MOIL 4-VIEW', style: TextStyle(
          color: Colors.cyanAccent, fontSize: 12,
          fontWeight: FontWeight.bold, fontFamily: 'monospace', letterSpacing: 2,
        )),
        const SizedBox(width: 16),

        // FPS
        ListenableBuilder(
          listenable: _engineData,
          builder: (_, __) => _badge(Icons.speed,
              _currentSource == VideoSource.camera ? 'CAM FPS' : 'FPS',
              '${_engineData.fps.toStringAsFixed(1)}', Colors.greenAccent),
        ),
        const SizedBox(width: 6),

        // Frame time
        ListenableBuilder(
          listenable: _engineData,
          builder: (_, __) => _badge(Icons.timer, 'FRAME',
              '${_engineData.frameTimeMs.toStringAsFixed(1)}ms', Colors.tealAccent),
        ),
        const SizedBox(width: 6),

        // Memory
        ListenableBuilder(
          listenable: _engineData,
          builder: (_, __) => _badge(Icons.memory, 'MEM',
              '${_engineData.memoryMB}MB', Colors.orangeAccent),
        ),

        if (_cameraResolution != null) ...[
          const SizedBox(width: 6),
          _badge(Icons.hd, 'RES', _cameraResolution!, Colors.blueAccent),
        ],

        const Spacer(),

        // View selector buttons 1-4
        ...List.generate(4, (i) => Padding(
          padding: const EdgeInsets.only(left: 3),
          child: GestureDetector(
            onTap: () => setState(() => _activeView = i),
            child: Container(
              width: 26, height: 26,
              decoration: BoxDecoration(
                color: _activeView == i
                    ? Colors.cyanAccent.withOpacity(0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: _activeView == i ? Colors.cyanAccent : Colors.white24,
                ),
              ),
              child: Center(child: Text('${i + 1}', style: TextStyle(
                color: _activeView == i ? Colors.cyanAccent : Colors.white38,
                fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace',
              ))),
            ),
          ),
        )),

        const SizedBox(width: 10),

        // Shader / Original toggle
        _actionBtn(
          _viewMode == ViewMode.processed ? Icons.auto_awesome : Icons.image,
          _viewMode == ViewMode.processed ? 'SHADER' : 'ORIGINAL',
          _viewMode == ViewMode.processed ? Colors.cyanAccent : Colors.amber,
          _toggleViewMode,
        ),
        const SizedBox(width: 4),
        _actionBtn(Icons.refresh, 'RESET', Colors.white54,
            () => _moilConfig.resetView(_activeView)),
        const SizedBox(width: 4),
        _actionBtn(Icons.refresh_outlined, 'ALL', Colors.white38,
            _moilConfig.resetAll),

        // Source badge
        if (_activeSourceLabel != null) ...[
          const SizedBox(width: 10),
          _buildSourceBadge(),
        ],
      ]),
    );
  }

  Widget _badge(IconData icon, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 9, color: color),
        const SizedBox(width: 3),
        Text('$label: ', style: TextStyle(
            color: color.withOpacity(0.6), fontSize: 8, fontFamily: 'monospace')),
        Text(value, style: TextStyle(
            color: color, fontSize: 9,
            fontWeight: FontWeight.bold, fontFamily: 'monospace')),
      ]),
    );
  }

  Widget _actionBtn(IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.07),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(color: color, fontSize: 8,
              fontFamily: 'monospace', fontWeight: FontWeight.bold)),
        ]),
      ),
    );
  }

  Widget _buildSourceBadge() {
    final isCamera = _currentSource == VideoSource.camera;
    final color = isCamera ? Colors.greenAccent : Colors.blueAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (isCamera) ...[_LiveDot(), const SizedBox(width: 4)],
        Icon(isCamera ? Icons.videocam : Icons.movie, size: 10, color: color),
        const SizedBox(width: 4),
        Text(isCamera ? 'LIVE: $_activeSourceLabel' : _activeSourceLabel!,
            style: TextStyle(color: color, fontSize: 8,
                fontFamily: 'monospace', fontWeight: FontWeight.bold)),
        if (isCamera) ...[
          const SizedBox(width: 6),
          GestureDetector(onTap: _stopCamera,
              child: const Icon(Icons.close, size: 10, color: Colors.white38)),
        ],
      ]),
    );
  }

  // ── BOTTOM BAR ───────────────────────────────────────
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        border: Border(top: BorderSide(color: Colors.cyanAccent.withOpacity(0.2))),
      ),
      child: Row(children: [
        // Active view params display
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.cyanAccent.withOpacity(0.05),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.cyanAccent.withOpacity(0.2)),
          ),
          child: ListenableBuilder(
            listenable: _moilConfig,
            builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
              Text('V${_activeView + 1}  ',
                  style: const TextStyle(color: Colors.cyanAccent,
                      fontSize: 10, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              Text(
                'α=${_moilConfig.alphas[_activeView].toStringAsFixed(1)}°  '
                'β=${_moilConfig.betas[_activeView].toStringAsFixed(1)}°  '
                'Z=${_moilConfig.zooms[_activeView].toStringAsFixed(1)}x',
                style: const TextStyle(color: Colors.white60,
                    fontSize: 10, fontFamily: 'monospace'),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 10),

        Expanded(
          child: ElevatedButton.icon(
            onPressed: _pickVideo,
            icon: const Icon(Icons.folder, size: 15),
            label: const Text('LOAD VIDEO', style: TextStyle(fontSize: 11)),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white10,
                padding: const EdgeInsets.symmetric(vertical: 12)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _currentSource == VideoSource.camera ? _stopCamera : _openCamera,
            icon: Icon(_currentSource == VideoSource.camera
                ? Icons.videocam_off : Icons.videocam, size: 15),
            label: Text(_currentSource == VideoSource.camera
                ? 'DISCONNECT' : 'OPEN CAMERA',
                style: const TextStyle(fontSize: 11)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _currentSource == VideoSource.camera
                  ? Colors.redAccent.withOpacity(0.2)
                  : Colors.greenAccent.withOpacity(0.1),
              foregroundColor: _currentSource == VideoSource.camera
                  ? Colors.redAccent : Colors.greenAccent,
              side: BorderSide(
                color: _currentSource == VideoSource.camera
                    ? Colors.redAccent.withOpacity(0.4)
                    : Colors.greenAccent.withOpacity(0.3),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------
// 10. LIVE DOT
// ---------------------------------------------------------
class _LiveDot extends StatefulWidget {
  @override State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);
  late final Animation<double> _anim = Tween<double>(begin: 0.2, end: 1.0).animate(_ctrl);

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _anim,
    child: Container(width: 6, height: 6,
        decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)),
  );

  @override void dispose() { _ctrl.dispose(); super.dispose(); }
}