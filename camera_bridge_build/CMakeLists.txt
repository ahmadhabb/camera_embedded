cmake_minimum_required(VERSION 3.14)
project(camera_bridge)
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED gstreamer-1.0 gstreamer-app-1.0)
add_library(camera_bridge SHARED ../camera_bridge.cpp)
target_include_directories(camera_bridge PRIVATE ${GST_INCLUDE_DIRS})
target_link_libraries(camera_bridge ${GST_LIBRARIES})
set_target_properties(camera_bridge PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "camera_bridge"
)
