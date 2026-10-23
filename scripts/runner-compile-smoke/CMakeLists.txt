cmake_minimum_required(VERSION 3.14)
project(runner_compile_smoke LANGUAGES CXX)

# Compile the real bridge translation unit, including Windows COM/RPC macros
# and Flutter's actual generic MethodChannel callback types. No app is linked,
# launched, or queried, and this target never runs Flutter or fetches headers.
get_filename_component(APP "${CMAKE_CURRENT_LIST_DIR}/../../flutter_app" ABSOLUTE)
set(EPHEMERAL "${APP}/windows/flutter/ephemeral")
if(NOT EXISTS "${EPHEMERAL}/cpp_client_wrapper/include/flutter/method_channel.h")
  message(FATAL_ERROR "Existing generated Flutter Windows headers required; configure the application first.")
endif()
add_library(runner_compile_smoke OBJECT "${APP}/windows/runner/flutter_window.cpp")
target_include_directories(runner_compile_smoke PRIVATE
  "${APP}/windows" "${EPHEMERAL}" "${EPHEMERAL}/cpp_client_wrapper/include")
target_compile_features(runner_compile_smoke PRIVATE cxx_std_17)
target_compile_options(runner_compile_smoke PRIVATE /W4 /WX /wd4100 /utf-8 /EHsc)
target_compile_definitions(runner_compile_smoke PRIVATE NOMINMAX UNICODE _UNICODE _HAS_EXCEPTIONS=0)
