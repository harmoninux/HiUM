# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(qemuohos)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

# 父进程（ArkUI）：napi + QMP(loopback TCP) + NCP IPC 客户端 + qemu-img 工具
add_library(entry SHARED
    napi_init.cpp
    qmp.cpp
    ncp_client.cpp
    imgtool.cpp
    swtpm.cpp
    swtpm_client.cpp)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_window.so
    libchild_process.so
    libipc_capi.so
    libdl.so)

# qemu 子进程（NCP）：一进程一轮 VM，DCL 帧经 GL letterbox 直接上屏
add_library(qemu_child SHARED
    qemu_child.cpp
    vm.cpp
    fb.cpp
    renderer.cpp
    input.cpp)

target_link_libraries(qemu_child PUBLIC
    libhilog_ndk.z.so
    libEGL.so
    libGLESv3.so
    libnative_window.so
    libipc_capi.so
    libdl.so)

# swtpm 子进程（NCP）：dlopen libswtpm.so 前台跑 swtpm_entry（与 qemu_child 对称）
add_library(swtpm_child SHARED
    swtpm_child.cpp)
target_link_libraries(swtpm_child PUBLIC
    libhilog_ndk.z.so
    libchild_process.so
    libipc_capi.so
    libdl.so)
