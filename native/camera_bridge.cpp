// camera_bridge.cpp
// GStreamer V4L2 camera bridge untuk Flutter via FFI.
// Pipeline: v4l2src → jpegdec → videoconvert → RGBA frame buffer
// Flutter membaca frame buffer via pointer, lalu upload ke GPU texture.
//
// Build:
//   cmake -B build -S . && cmake --build build
// Output: libcamera_bridge.so

#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <cstring>
#include <cstdlib>
#include <atomic>
#include <mutex>

// -------------------------------------------------------
// State global pipeline
// -------------------------------------------------------
static GstElement*  s_pipeline   = nullptr;
static GstElement*  s_appsink    = nullptr;
static uint8_t*     s_frameBuf   = nullptr; // RGBA frame buffer
static int          s_width      = 0;
static int          s_height     = 0;
static std::mutex   s_frameMutex;
static std::atomic<bool> s_newFrame{false};
static std::atomic<bool> s_running{false};

// -------------------------------------------------------
// Callback: dipanggil GStreamer setiap ada frame baru
// -------------------------------------------------------
static GstFlowReturn on_new_sample(GstAppSink* sink, gpointer) {
    GstSample* sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_ERROR;

    GstBuffer* buffer = gst_sample_get_buffer(sample);
    GstMapInfo  map;

    if (gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        std::lock_guard<std::mutex> lock(s_frameMutex);
        const size_t expected = (size_t)s_width * s_height * 4; // RGBA
        if (s_frameBuf && map.size == expected) {
            memcpy(s_frameBuf, map.data, expected);
            s_newFrame.store(true);
        }
        gst_buffer_unmap(buffer, &map);
    }

    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

// -------------------------------------------------------
// FFI EXPORTS
// -------------------------------------------------------
extern "C" {

// Inisialisasi GStreamer (panggil sekali di awal)
__attribute__((visibility("default")))
void camera_init() {
    if (!gst_is_initialized()) {
        gst_init(nullptr, nullptr);
    }
}

// Buka kamera dan mulai pipeline
// devicePath : "/dev/video0"
// width, height : resolusi capture (harus didukung kamera)
// Returns: 1 sukses, 0 gagal
__attribute__((visibility("default")))
int camera_open(const char* devicePath, int width, int height) {
    if (s_running.load()) return 0; // sudah berjalan

    s_width  = width;
    s_height = height;

    // Alokasi frame buffer RGBA
    s_frameBuf = (uint8_t*)malloc((size_t)width * height * 4);
    if (!s_frameBuf) return 0;

    // Pipeline GStreamer:
    // v4l2src → MJPEG caps filter → jpegdec → videoconvert → RGBA → appsink
    gchar* desc = g_strdup_printf(
        "v4l2src device=%s ! "
        "image/jpeg,width=640,height=480,framerate=30/1 ! "
        "jpegdec ! "
        "videoconvert ! "
        "video/x-raw,format=BGR! "
        "appsink name=sink emit-signals=true sync=false max-buffers=1 drop=true",
        devicePath
    );

    GError* err = nullptr;
    s_pipeline = gst_parse_launch(desc, &err);
    g_free(desc);

    if (!s_pipeline || err) {
        if (err) g_error_free(err);
        free(s_frameBuf);
        s_frameBuf = nullptr;
        return 0;
    }

    // Hubungkan callback appsink
    s_appsink = gst_bin_get_by_name(GST_BIN(s_pipeline), "sink");
    GstAppSinkCallbacks callbacks = {};
    callbacks.new_sample = on_new_sample;
    gst_app_sink_set_callbacks(GST_APP_SINK(s_appsink),
                               &callbacks, nullptr, nullptr);

    // Mulai pipeline
    GstStateChangeReturn ret = gst_element_set_state(s_pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        gst_object_unref(s_pipeline);
        s_pipeline = nullptr;
        free(s_frameBuf);
        s_frameBuf = nullptr;
        return 0;
    }

    s_running.store(true);
    return 1;
}

// Tutup kamera dan bebaskan resources
__attribute__((visibility("default")))
void camera_close() {
    if (!s_running.load()) return;
    s_running.store(false);

    if (s_pipeline) {
        gst_element_set_state(s_pipeline, GST_STATE_NULL);
        if (s_appsink) { gst_object_unref(s_appsink); s_appsink = nullptr; }
        gst_object_unref(s_pipeline);
        s_pipeline = nullptr;
    }

    std::lock_guard<std::mutex> lock(s_frameMutex);
    if (s_frameBuf) { free(s_frameBuf); s_frameBuf = nullptr; }
}

// Copy frame terbaru ke buffer dst (RGBA, width*height*4 bytes)
// Returns: 1 jika ada frame baru, 0 jika tidak ada update
__attribute__((visibility("default")))
int camera_get_frame(uint8_t* dst) {
    if (!s_newFrame.load() || !dst) return 0;

    std::lock_guard<std::mutex> lock(s_frameMutex);
    if (!s_frameBuf) return 0;

    memcpy(dst, s_frameBuf, (size_t)s_width * s_height * 4);
    s_newFrame.store(false);
    return 1;
}

// Cek apakah pipeline sedang berjalan
__attribute__((visibility("default")))
int camera_is_running() {
    return s_running.load() ? 1 : 0;
}

// Kembalikan lebar frame aktual
__attribute__((visibility("default")))
int camera_width()  { return s_width; }

// Kembalikan tinggi frame aktual
__attribute__((visibility("default")))
int camera_height() { return s_height; }

} // extern "C"