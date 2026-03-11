cmake_minimum_required(VERSION 3.14)
project(camera_bridge CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_BUILD_TYPE Release)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GST     REQUIRED gstreamer-1.0)
pkg_check_modules(GST_APP REQUIRED gstreamer-app-1.0)

add_library(camera_bridge SHARED camera_bridge.cpp)

target_include_directories(camera_bridge PRIVATE
    ${GST_INCLUDE_DIRS}
    ${GST_APP_INCLUDE_DIRS}
)

target_link_libraries(camera_bridge
    ${GST_LIBRARIES}
    ${GST_APP_LIBRARIES}
)

target_compile_options(camera_bridge PRIVATE
    ${GST_CFLAGS_OTHER}
    -O2
    -fvisibility=hidden
)

set_target_properties(camera_bridge PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/../linux"
)
