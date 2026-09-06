cmake_minimum_required(VERSION 3.14)
project(hongda_starlink LANGUAGES CXX)

set(BINARY_NAME "HongdaStarlink")
cmake_policy(SET CMP0063 NEW)

get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release" CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug" "Profile" "Release")
  endif()
endif()

set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

add_definitions(-DUNICODE -D_UNICODE)

function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Build HongdaService automatically as part of a normal `flutter build windows`.
# The previous source package required a separate PowerShell step; that allowed
# the UI to compile without runtime/service/HongdaService.exe and then fail only
# when the user clicked "启动服务". Make the service a real native build
# dependency instead.
set(HONGDA_SERVICE_EXE "${CMAKE_CURRENT_SOURCE_DIR}/../runtime/service/HongdaService.exe")
set(HONGDA_SERVICE_BUILD_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/../tools/build-service.ps1")
add_custom_command(
  OUTPUT "${HONGDA_SERVICE_EXE}"
  COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${HONGDA_SERVICE_BUILD_SCRIPT}"
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
  DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/../service/main.go"
    "${CMAKE_CURRENT_SOURCE_DIR}/../service/job_windows.go"
    "${CMAKE_CURRENT_SOURCE_DIR}/../service/job_other.go"
    "${CMAKE_CURRENT_SOURCE_DIR}/../service/go.mod"
    "${CMAKE_CURRENT_SOURCE_DIR}/../service/embedded/HongdaCore.exe"
    "${CMAKE_CURRENT_SOURCE_DIR}/../tools/build-core.ps1"
    "${HONGDA_SERVICE_BUILD_SCRIPT}"
  COMMENT "Building self-contained HongdaService.exe with HongdaCore 1.10.0"
  VERBATIM
)
add_custom_target(hongda_service_runtime DEPENDS "${HONGDA_SERVICE_EXE}")

add_subdirectory("runner")
add_dependencies(${BINARY_NAME} hongda_service_runtime)
include(flutter/generated_plugins.cmake)

set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
set(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)
install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
endif()

set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime OPTIONAL)

set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")" COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" CONFIGURATIONS Profile;Release COMPONENT Runtime)

# HongdaService runtime. The service executable embeds the locally built
# HongdaCore Windows amd64 runtime; no unused Cronet payload is shipped.
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../runtime/" DESTINATION "${CMAKE_INSTALL_PREFIX}/runtime" COMPONENT Runtime OPTIONAL)
