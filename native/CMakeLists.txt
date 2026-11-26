cmake_minimum_required(VERSION 3.22)
project(android16_build_tools LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(native-sources.cmake)
include(legacy-sources.cmake)
include(dexdump-sources.cmake)

find_package(Threads REQUIRED)
set(ZLIB_USE_STATIC_LIBS ON)
set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
find_package(ZLIB REQUIRED)
find_package(PNG REQUIRED)
find_package(EXPAT REQUIRED)
unset(CMAKE_FIND_LIBRARY_SUFFIXES)

set(system ${SOURCE_DIR}/system)
set(framework ${SOURCE_DIR}/frameworks/base)
set(incfs "${system}/incremental_delivery/incfs")
set(aapt2_src "${framework}/tools/aapt2")
set(build_version ${SOURCE_DIR}/build/soong/cc/libbuildversion)

add_library(host_headers INTERFACE)
target_include_directories(host_headers INTERFACE
    "${system}/libbase/include"
    "${system}/logging/liblog/include"
    "${system}/core/libutils/include"
    "${system}/core/libutils/binder/include"
    "${system}/core/libcutils/include"
    "${system}/core/libprocessgroup/include"
    "${system}/core/libsystem/include"
    "${system}/libziparchive/include"
    "${system}/libziparchive/incfs_support/include"
    "${incfs}/util/include"
    "${framework}/libs/androidfw/include"
    "${framework}/libs/androidfw/include_pathutils"
    "${framework}/cmds/idmap2/libidmap2_policies/include"
    "${build_version}/include"
    ${SOURCE_DIR}/frameworks/native/include
    ${SOURCE_DIR}/external/fmtlib/include
    ${SOURCE_DIR}/external/googletest/googletest/include
    ${JDK_DIR}/include ${JDK_DIR}/include/linux
)
target_compile_definitions(host_headers INTERFACE
    _FILE_OFFSET_BITS=64 _GNU_SOURCE FMT_HEADER_ONLY STATIC_ANDROIDFW_FOR_TOOLS
    INCFS_SUPPORT_DISABLED=1 ZLIB_CONST LIBLOG_LOG_TAG=1006 SNET_EVENT_LOG_TAG=1397638484
    ANDROID_DEBUGGABLE=0
)
target_compile_options(host_headers INTERFACE -ffunction-sections -fdata-sections)

add_library(android_host_support STATIC
    ${ANDROID_BASE} ${ANDROID_LOG} ${ANDROID_UTILS} ${ANDROID_UTILS_BINDER}
    ${ANDROID_CUTILS} ${ANDROID_ZIP}
    "${incfs}/util/map_ptr.cpp"
    "${build_version}/libbuildversion.cpp"
)
target_link_libraries(android_host_support PUBLIC host_headers Threads::Threads ZLIB::ZLIB)

add_library(androidfw STATIC ${ANDROIDFW})
target_link_libraries(androidfw PUBLIC android_host_support PNG::PNG EXPAT::EXPAT)

add_library(aapt_legacy STATIC ${AAPT_LEGACY})
target_include_directories(aapt_legacy PUBLIC "${framework}/tools")
target_link_libraries(aapt_legacy PUBLIC androidfw)

add_executable(aapt "${framework}/tools/aapt/Main.cpp")
target_link_libraries(aapt PRIVATE aapt_legacy)

add_executable(split-select "${framework}/tools/split-select/Main.cpp" ${SPLIT_SELECT})
target_link_libraries(split-select PRIVATE aapt_legacy)

set(protobuf_BUILD_TESTS OFF CACHE BOOL "")
set(protobuf_BUILD_EXAMPLES OFF CACHE BOOL "")
set(protobuf_BUILD_PROTOC_BINARIES ON CACHE BOOL "")
set(protobuf_BUILD_SHARED_LIBS OFF CACHE BOOL "")
set(protobuf_INSTALL OFF CACHE BOOL "")
add_subdirectory(${SOURCE_DIR}/external/protobuf protobuf-build EXCLUDE_FROM_ALL)
target_include_directories(libprotobuf PRIVATE ${SOURCE_DIR}/external/protobuf/android)
target_include_directories(libprotoc PRIVATE ${SOURCE_DIR}/external/protobuf/android)

set(protos ${AAPT2})
list(FILTER protos INCLUDE REGEX "[.]proto$")
list(FILTER AAPT2 EXCLUDE REGEX "[.]proto$")
set(proto_output "${CMAKE_CURRENT_BINARY_DIR}/aapt2-protos")
set(proto_sources "")
foreach(proto IN LISTS protos)
    file(RELATIVE_PATH relative ${SOURCE_DIR} "${proto}")
    string(REGEX REPLACE "[.]proto$" ".pb" stem "${relative}")
    list(APPEND proto_sources "${proto_output}/${stem}.cc")
endforeach()
add_custom_command(
    OUTPUT ${proto_sources}
    COMMAND ${CMAKE_COMMAND} -E make_directory "${proto_output}"
    COMMAND protobuf::protoc --proto_path=${SOURCE_DIR} "--cpp_out=${proto_output}" ${protos}
    DEPENDS protobuf::protoc ${protos}
    VERBATIM
)
add_library(aapt2_protos STATIC ${proto_sources})
target_include_directories(aapt2_protos PUBLIC "${proto_output}" "${proto_output}/frameworks/base/tools/aapt2")
target_link_libraries(aapt2_protos PUBLIC protobuf::libprotobuf)

add_executable(aapt2 ${AAPT2})
target_include_directories(aapt2 PRIVATE "${aapt2_src}")
target_compile_options(aapt2 PRIVATE -fno-exceptions -fno-rtti -Wno-deprecated-declarations)
target_link_libraries(aapt2 PRIVATE androidfw aapt2_protos)

add_executable(dexdump ${ART_DUMPER} ${ART_DEX} ${ART_BASE}
    ${GENERATED_DIR}/artbase-operators.cc ${GENERATED_DIR}/dexfile-operators.cc
    ${SOURCE_DIR}/art/libartpalette/system/palette_fake.cc
    ${SOURCE_DIR}/external/tinyxml2/tinyxml2.cpp
)
target_include_directories(dexdump PRIVATE
    ${SOURCE_DIR}/art/libartbase
    ${SOURCE_DIR}/art/libdexfile
    ${SOURCE_DIR}/art/libdexfile/external/include
    ${SOURCE_DIR}/art/libartpalette/include
    ${SOURCE_DIR}/art/dexdump
    ${SOURCE_DIR}/external/tinyxml2
)
target_compile_definitions(dexdump PRIVATE STATIC_LIB ART_STATIC_LIBARTBASE ART_PAGE_SIZE_AGNOSTIC=1
    ART_STACK_OVERFLOW_GAP_arm=8192 ART_STACK_OVERFLOW_GAP_arm64=8192
    ART_STACK_OVERFLOW_GAP_riscv64=8192 ART_STACK_OVERFLOW_GAP_x86=8192
    ART_STACK_OVERFLOW_GAP_x86_64=8192 ART_BASE_ADDRESS=0x70000000 ART_FRAME_SIZE_LIMIT=1744
)
target_link_libraries(dexdump PRIVATE android_host_support dl)
foreach(program IN ITEMS aapt aapt2 split-select dexdump)
    target_link_options("${program}" PRIVATE -Wl,--gc-sections)
endforeach()

include(sdk-utilities-sources.cmake)
find_package(BISON REQUIRED)
find_package(FLEX REQUIRED)
set(aidl_source "${system}/tools/aidl")
set(aidl_generated "${CMAKE_CURRENT_BINARY_DIR}/aidl-generated")
set(gtest_source "${SOURCE_DIR}/external/googletest/googletest")
file(MAKE_DIRECTORY "${aidl_generated}")
bison_target(AidlParser "${aidl_source}/aidl_language_y.yy"
    "${aidl_generated}/aidl_language_y.cpp"
    DEFINES_FILE "${aidl_generated}/aidl_language_y.h"
)
flex_target(AidlLexer "${aidl_source}/aidl_language_l.ll"
    "${aidl_generated}/aidl_language_l.cpp"
)
add_flex_bison_dependency(AidlLexer AidlParser)
add_executable(aidl ${AIDL_SOURCES}
    ${BISON_AidlParser_OUTPUTS} ${FLEX_AidlLexer_OUTPUTS}
    "${gtest_source}/src/gtest-all.cc"
)
set_target_properties(aidl PROPERTIES CXX_STANDARD 20)
target_include_directories(aidl PRIVATE
    "${aidl_source}" "${aidl_source}/include" "${aidl_generated}" "${gtest_source}"
)
target_compile_definitions(aidl PRIVATE PLATFORM_SDK_VERSION=36)
target_link_options(aidl PRIVATE -Wl,--gc-sections)
target_link_libraries(aidl PRIVATE android_host_support)

add_executable(zipalign ${ZIPALIGN_SOURCES} ${ZOPFLI_SOURCES})
target_include_directories(zipalign PRIVATE
    "${SOURCE_DIR}/build/tools/zipalign/include" "${SOURCE_DIR}/external/zopfli/src"
)
target_link_options(zipalign PRIVATE -Wl,--gc-sections)
target_link_libraries(zipalign PRIVATE android_host_support)
