cmake_minimum_required(VERSION 3.10)
project(nitro_webgpu_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM 401ef0a9607973eb
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_webgpu SHARED
  "nitro_webgpu.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_webgpu.bridge.g.cpp"
  "dart_api_dl.c"
)

if(NOT ANDROID)
  target_sources(nitro_webgpu PRIVATE "HybridNitroWebgpu.cpp")
endif()
target_include_directories(nitro_webgpu PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(nitro_webgpu PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(nitro_webgpu PRIVATE android log)
  target_link_options(nitro_webgpu PRIVATE "-Wl,-z,max-page-size=16384")
endif()

# --- wgpu-native (vendored by scripts/fetch_wgpu_native.sh) ------------------
# Apple platforms link wgpu via the podspec/SwiftPM xcframework instead.
set(WGPU_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/wgpu_native")
if(ANDROID)
  if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(WGPU_TARGET "android-aarch64")
  elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    set(WGPU_TARGET "android-armv7")
  elseif(ANDROID_ABI STREQUAL "x86_64")
    set(WGPU_TARGET "android-x86_64")
  else()
    message(FATAL_ERROR "nitro_webgpu: unsupported Android ABI ${ANDROID_ABI} — restrict abiFilters to arm64-v8a/armeabi-v7a/x86_64")
  endif()
  set(WGPU_LIB "${WGPU_ROOT}/${WGPU_TARGET}/lib/libwgpu_native.a")
elseif(WIN32)
  set(WGPU_LIB "${WGPU_ROOT}/windows-x86_64-msvc/lib/wgpu_native.lib")
elseif(UNIX AND NOT APPLE)
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(WGPU_TARGET "linux-aarch64")
  else()
    set(WGPU_TARGET "linux-x86_64")
  endif()
  set(WGPU_LIB "${WGPU_ROOT}/${WGPU_TARGET}/lib/libwgpu_native.a")
endif()

if(NOT APPLE)
  if(NOT EXISTS "${WGPU_LIB}")
    message(FATAL_ERROR "nitro_webgpu: wgpu-native not vendored (missing ${WGPU_LIB}) — run scripts/fetch_wgpu_native.sh")
  endif()
  target_include_directories(nitro_webgpu PRIVATE "${WGPU_ROOT}/include")
  target_link_libraries(nitro_webgpu PRIVATE "${WGPU_LIB}")
  if(WIN32)
    target_link_libraries(nitro_webgpu PRIVATE
      d3dcompiler ws2_32 userenv bcrypt ntdll opengl32 Propsys RuntimeObject)
  elseif(UNIX AND NOT ANDROID)
    target_link_libraries(nitro_webgpu PRIVATE m dl pthread)
  endif()
endif()
