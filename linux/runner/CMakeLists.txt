cmake_minimum_required(VERSION 3.13)
# C as well: the Wayland protocol code under wayland/ is generated C.
project(runner LANGUAGES CXX C)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "pointer_capture.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Relative mouse under Wayland (pointer_capture.cc): the runner binds two
# protocols itself, with the generated code under wayland/. Where the
# Wayland client library is not there to build against, the app builds
# without it and says "not available" under Wayland, as before.
pkg_check_modules(ZEST_WAYLAND_CLIENT IMPORTED_TARGET wayland-client)
if(ZEST_WAYLAND_CLIENT_FOUND)
  target_sources(${BINARY_NAME} PRIVATE
    "wayland/pointer-constraints-unstable-v1-protocol.c"
    "wayland/relative-pointer-unstable-v1-protocol.c"
  )
  target_compile_definitions(${BINARY_NAME} PRIVATE ZEST_WAYLAND_POINTER)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::ZEST_WAYLAND_CLIENT)
endif()
