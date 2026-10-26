cmake_minimum_required(VERSION 3.21)
project(CodexRuntimeOwner LANGUAGES CXX)
add_subdirectory(../desktop_runtime_bridge desktop_runtime_bridge)
add_subdirectory(../desktop_runtime_observer desktop_runtime_observer)
install(TARGETS codex_runtime_bridge codex_runtime_metadata codex_desktop_observer
  RUNTIME DESTINATION . LIBRARY DESTINATION .)
