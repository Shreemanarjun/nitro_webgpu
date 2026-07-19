set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")

# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "nitro_webgpu")
project(${PROJECT_NAME} LANGUAGES CXX)

# Invoke the build for native code shared with the other target platforms.
# This can be changed to accommodate different builds.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# ── Presentation plugin (M2.5) ───────────────────────────────────────────
# Registered via pubspec pluginClass; owns the Flutter texture objects and
# installs NwpTextureOps into libnitro_webgpu_present.so
# (nwp_set_texture_ops).
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

set(PLUGIN_NAME "nitro_webgpu_plugin")

add_library(${PLUGIN_NAME} SHARED
  "nitro_webgpu_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE nitro_webgpu_present)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(nitro_webgpu_bundled_libraries
  # Defined in ../src/CMakeLists.txt.
  # This can be changed to accommodate different builds.
  $<TARGET_FILE:nitro_webgpu>
  $<TARGET_FILE:nitro_webgpu_present>
)
if(NW_BACKEND STREQUAL "dawn" AND DEFINED NW_DAWN_RUNTIME_LIB)
  list(APPEND nitro_webgpu_bundled_libraries "${NW_DAWN_RUNTIME_LIB}")
endif()
set(nitro_webgpu_bundled_libraries ${nitro_webgpu_bundled_libraries} PARENT_SCOPE)
