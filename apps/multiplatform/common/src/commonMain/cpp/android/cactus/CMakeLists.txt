# Standalone build for the copilot's native seam.
#
# NOT included from ../CMakeLists.txt, on purpose. Two reasons, both measured on this checkout:
#
# 1. `android/build.gradle.kts` sets `splits.abi { include("arm64-v8a", "armeabi-v7a") }`, and the
#    published cactus runtime ships one archive per ABI:
#    `../../cactus/android-arm64/libcactus.a` exists, and there is no
#    `../../cactus/android-armv7/libcactus.a` in the tree. Adding this directory to the app's
#    CMakeLists would fail the armeabi-v7a native build, which fails `assembleFossDebug` outright.
# 2. The engine is dormant by default (`NEEDLE_CACTUS_ENABLED = false` in
#    common/src/androidMain/.../NeedleCactusEngine.android.kt), so a packaged copy would be 2.4 MB of
#    code that no shipped build path ever calls.
#
# To arm it: `libcactus-jni.so` is already copied next to the app's own prebuilt libraries
# (`../libs/arm64-v8a/`, measured 2372776 bytes, exporting the six
# `Java_chat_popopx_common_copilot_PopopxCactusJni_*` names the Kotlin object declares). That
# directory is gitignored (`apps/multiplatform/.gitignore:13`), so on a fresh clone the build line
# below is what produces it. The packaging step is one guarded line in ../CMakeLists.txt — which is
# NOT a gradle file, so it is the only edit arming the engine requires:
#
#   if(ANDROID_ABI STREQUAL "arm64-v8a" AND EXISTS ${CMAKE_SOURCE_DIR}/libs/${ANDROID_ABI}/libcactus-jni.so)
#     add_subdirectory(cactus)
#   endif()
#
# The guard matters twice over: the armeabi-v7a split has no archive to link, and a tree without the
# hand-built .so stays buildable. Flip the Kotlin const in a separate change.
#
# One-line build without CMake, run from this directory, verified with the NDK the app pins
# (`android/build.gradle.kts`: ndkVersion 23.1.7779620):
#
#   NDK=~/Library/Android/sdk/ndk/23.1.7779620
#   TOOL=$NDK/toolchains/llvm/prebuilt/darwin-x86_64
#   $TOOL/bin/clang   --target=aarch64-linux-android26 -fPIC -O2 -Wall -Wextra -std=c11 \
#       -I../../cactus/android-arm64 -c cactus_jni.c -o cactus_jni.o
#   $TOOL/bin/clang++ --target=aarch64-linux-android26 -shared -o libcactus-jni.so cactus_jni.o \
#       ../../cactus/android-arm64/libcactus.a -static-libstdc++ -llog \
#       -Wl,-z,max-page-size=16384 -Wl,--build-id=none -Wl,--gc-sections -s
#
# The two steps are not stylistic: `jni.h` exposes the C++ interface when compiled as C++, so the
# shim is compiled as C and only the link uses the C++ driver, which is what resolves the libc++
# references inside cactus.cpp.o while keeping the runtime off the apk (`-static-libstdc++`).
# The 16 KiB page size matches what the app's own CMakeLists passes for the page-size requirement.

cmake_minimum_required(VERSION 3.18.1)
project(cactus_jni C CXX)

if(NOT ANDROID_ABI STREQUAL "arm64-v8a")
  message(STATUS "cactus-jni: skipped for ${ANDROID_ABI} (no published libcactus.a for this ABI)")
  return()
endif()

set(CACTUS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../cactus/android-arm64)

add_library(cactus-jni SHARED cactus_jni.c)

target_include_directories(cactus-jni PRIVATE ${CACTUS_DIR})

target_compile_options(cactus-jni PRIVATE -fPIC -O2 -Wall -Wextra -std=c11)

# The archive is a C++ translation unit; linking with the C++ driver resolves libc++, and statically
# so the apk gains no second C++ runtime beside the one the app already carries.
set_target_properties(cactus-jni PROPERTIES
  LINKER_LANGUAGE CXX
  LINK_OPTIONS "-static-libstdc++"
)

target_link_libraries(cactus-jni PRIVATE
  ${CACTUS_DIR}/libcactus.a
  log
)

# Same flags the app's own native target uses, so the artifact matches how its siblings are built.
target_link_options(cactus-jni PRIVATE
  "-Wl,-z,max-page-size=16384"
  "-Wl,--build-id=none"
  "-Wl,--gc-sections"
)

add_custom_command(TARGET cactus-jni POST_BUILD
  COMMAND ${CMAKE_STRIP} --remove-section=.comment $<TARGET_FILE:cactus-jni>
  COMMENT "Stripping .comment section from libcactus-jni.so"
)
