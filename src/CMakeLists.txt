cmake_minimum_required(VERSION 3.10)
project(nitro_webgpu_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM 50141cdccf17ca6e
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_webgpu SHARED
  "nitro_webgpu.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_webgpu.bridge.g.cpp"
  "dart_api_dl.c"
)

target_sources(nitro_webgpu PRIVATE "HybridNitroWebgpu.cpp")
target_include_directories(nitro_webgpu PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(nitro_webgpu PUBLIC DART_SHARED_LIB)

if(ANDROID)
  # JNI shim for the surface-mode presenter (SurfaceProducer → WGPUSurface).
  target_sources(nitro_webgpu PRIVATE "present/nwp_android_jni.cpp")
  target_link_libraries(nitro_webgpu PRIVATE android log)
  target_link_options(nitro_webgpu PRIVATE "-Wl,-z,max-page-size=16384")
endif()

# --- backend selection -------------------------------------------------------
# Marker file (default "wgpu") switched by scripts/set_backend_*.sh; content
# changes trigger reconfiguration, so a stale CMake cache can never build
# the wrong backend (env vars would go stale).
set(NW_BACKEND_MARKER "${CMAKE_CURRENT_SOURCE_DIR}/third_party/BACKEND")
set(NW_BACKEND "wgpu")
if(EXISTS "${NW_BACKEND_MARKER}")
  file(READ "${NW_BACKEND_MARKER}" NW_BACKEND)
  string(STRIP "${NW_BACKEND}" NW_BACKEND)
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
               "${NW_BACKEND_MARKER}")
endif()
message(STATUS "nitro_webgpu backend: ${NW_BACKEND}")
get_directory_property(NW_HAS_PARENT PARENT_DIRECTORY)
if(NW_HAS_PARENT)
  set(NW_BACKEND "${NW_BACKEND}" PARENT_SCOPE)
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
  if(NW_BACKEND STREQUAL "dawn")
    # Dawn staged by scripts/stage_dawn_<platform>.sh: shared headers under
    # third_party/dawn/include, the monolithic library per target.
    set(DAWN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dawn")
    if(ANDROID)
      set(DAWN_LIB "${DAWN_ROOT}/${WGPU_TARGET}/lib/libwebgpu_dawn.so")
    elseif(WIN32)
      set(DAWN_LIB "${DAWN_ROOT}/windows-x86_64/lib/webgpu_dawn.lib")
    else()
      set(DAWN_LIB "${DAWN_ROOT}/${WGPU_TARGET}/lib/libwebgpu_dawn.so")
    endif()
    if(NOT EXISTS "${DAWN_LIB}")
      message(FATAL_ERROR "nitro_webgpu: Dawn not staged (missing ${DAWN_LIB}) — run the platform stage_dawn script or switch back with scripts/set_backend_android.sh wgpu")
    endif()
    target_compile_definitions(nitro_webgpu PRIVATE NITRO_WEBGPU_BACKEND_DAWN)
    target_include_directories(nitro_webgpu PRIVATE "${DAWN_ROOT}/include")
    target_link_libraries(nitro_webgpu PRIVATE "${DAWN_LIB}")
    # glslang (GLSL→SPIR-V front end) when staged for this target.
    set(GLSLANG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/glslang")
    if(ANDROID AND EXISTS "${GLSLANG_ROOT}/${WGPU_TARGET}/lib/libglslang.a")
      target_compile_definitions(nitro_webgpu PRIVATE NITRO_WEBGPU_HAS_GLSLANG)
      target_include_directories(nitro_webgpu PRIVATE "${GLSLANG_ROOT}/include")
      file(GLOB GLSLANG_LIBS "${GLSLANG_ROOT}/${WGPU_TARGET}/lib/*.a")
      target_link_libraries(nitro_webgpu PRIVATE
        -Wl,--start-group ${GLSLANG_LIBS} -Wl,--end-group)
    endif()
    # Runtime library the platform layer must bundle with the app
    # (Windows: the DLL next to the import lib; Linux/Android: the .so).
    if(WIN32)
      set(NW_DAWN_RUNTIME_LIB "${DAWN_ROOT}/windows-x86_64/lib/webgpu_dawn.dll"
          PARENT_SCOPE)
    elseif(NOT ANDROID)
      set(NW_DAWN_RUNTIME_LIB "${DAWN_LIB}" PARENT_SCOPE)
    endif()
  else()
    if(NOT EXISTS "${WGPU_LIB}")
      message(FATAL_ERROR "nitro_webgpu: wgpu-native not vendored (missing ${WGPU_LIB}) — run scripts/fetch_wgpu_native.sh")
    endif()
    target_include_directories(nitro_webgpu PRIVATE "${WGPU_ROOT}/include")
    target_link_libraries(nitro_webgpu PRIVATE "${WGPU_LIB}")
  endif()
  if(WIN32)
    target_link_libraries(nitro_webgpu PRIVATE
      d3dcompiler ws2_32 userenv bcrypt ntdll opengl32 Propsys RuntimeObject)
  elseif(UNIX AND NOT ANDROID)
    target_link_libraries(nitro_webgpu PRIVATE m dl pthread)
  endif()
endif()

add_library(nitro_webgpu_present SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_webgpu_present.bridge.g.cpp"
  "dart_api_dl.c"
)
if(NOT ANDROID)
  if(DEFINED NITRO_IMPL_SRC_nitro_webgpu_present)
    target_sources(nitro_webgpu_present PRIVATE "${NITRO_IMPL_SRC_nitro_webgpu_present}")
  else()
    target_sources(nitro_webgpu_present PRIVATE "HybridNitroWebgpuPresent.cpp")
  endif()
endif()
target_include_directories(nitro_webgpu_present PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
set_target_properties(nitro_webgpu_present PROPERTIES OUTPUT_NAME "nitro_webgpu_present")
target_compile_definitions(nitro_webgpu_present PUBLIC DART_SHARED_LIB)
# nwp_set_texture_ops is dllexport while building this library, dllimport
# for the platform plugin that consumes it (src/present/nwp_texture_ops.h).
target_compile_definitions(nitro_webgpu_present PRIVATE NWP_PRESENT_BUILD)
if(ANDROID)
  target_link_libraries(nitro_webgpu_present PRIVATE android log)
  target_link_options(nitro_webgpu_present PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  # The desktop presenter drives the nwp_* ring exported by the core library.
  target_link_libraries(nitro_webgpu_present PRIVATE dbghelp nitro_webgpu)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(nitro_webgpu_present PRIVATE dl pthread nitro_webgpu)
endif()
