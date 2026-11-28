# TVCraft Installer: the Mac app players download (signed with a Developer ID and notarized by
# tools/release.sh). It builds TVCraft from their own Minecraft PE 0.8.1 APK at a GitHub release tag
# and installs it on their Apple TVs, through scripts/tvcraft.py. It doesn't update itself: a new
# major version (N.0.0) is a new installer, and it builds only N.x.y releases. Derived from Frontline
# Rewritten's installer (CREDITS.md).
#
# The app needs the Xcode generator (its asset catalog); its logic (no UI) is tested with any
# generator: CMakePresets.json has both.
cmake_minimum_required(VERSION 3.28)

# Apple silicon only, like the game's build. These have to be set before project().
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET 26.0 CACHE STRING "Minimum macOS version")

# The release the installer is built for: tools/release.sh passes the N.0.0 version (or N.0.0-rc1) and
# its commit. The bundle's short version is the numeric part, its build number
# major*10000+minor*100+patch, and TVCraftVersion (the full version) gives the major version of the
# releases it builds.
set(TVCRAFT_VERSION "0.0.1" CACHE STRING "The installer's version (the tag without its v)")
set(TVCRAFT_COMMIT "" CACHE STRING "The commit built (short hash)")
if(NOT TVCRAFT_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)(-[0-9A-Za-z.]+)?$")
    message(FATAL_ERROR "TVCRAFT_VERSION ${TVCRAFT_VERSION} isn't a version like 1.0.0 or 1.0.0-rc1")
endif()
set(_numeric "${CMAKE_MATCH_1}.${CMAKE_MATCH_2}.${CMAKE_MATCH_3}")
math(EXPR TVCRAFT_BUILD_NUMBER "${CMAKE_MATCH_1} * 10000 + ${CMAKE_MATCH_2} * 100 + ${CMAKE_MATCH_3}")

project(TVCraftInstaller VERSION ${_numeric} LANGUAGES Swift)

# The files without UI, which the logic tests compile too.
set(TVCRAFT_INSTALLER_LOGIC_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/PortEvent.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/PortManifest.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Releases.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/SemVer.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/Sources/Workspace.swift")

enable_testing()
add_subdirectory(tests)

if(NOT CMAKE_GENERATOR STREQUAL "Xcode")
    return()
endif()

set(TVCRAFT_INSTALLER_BUNDLE_ID "com.vanillacoffeesoft.TVCraftInstaller"
    CACHE STRING "Bundle identifier for TVCraft Installer")
# Ad hoc for local builds; tools/release.sh signs with "Developer ID Application".
set(TVCRAFT_INSTALLER_SIGN_IDENTITY "-" CACHE STRING "Code signing identity for TVCraft Installer")
set(TVCRAFT_DEVELOPMENT_TEAM "" CACHE STRING "The Developer ID's team (tools/release.sh passes it)")

set(_sources
    Sources/AppModel.swift
    Sources/Doctor.swift
    Sources/InstallerApp.swift
    Sources/PortEvent.swift
    Sources/PortManifest.swift
    Sources/Releases.swift
    Sources/SemVer.swift
    Sources/Shell.swift
    Sources/Source.swift
    Sources/Views.swift
    Sources/Workspace.swift)
# Assets.xcassets has AccentColor (#C6E9AF light, #2D5DA4 dark).
add_executable(TVCraftInstaller MACOSX_BUNDLE ${_sources} AppIcon.icns Assets.xcassets)
set_source_files_properties(AppIcon.icns Assets.xcassets PROPERTIES MACOSX_PACKAGE_LOCATION Resources)

set_target_properties(TVCraftInstaller PROPERTIES
    OUTPUT_NAME "TVCraft Installer"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${TVCRAFT_INSTALLER_BUNDLE_ID}"
    MACOSX_BUNDLE_BUNDLE_NAME "TVCraft Installer"
    MACOSX_BUNDLE_BUNDLE_VERSION "${TVCRAFT_BUILD_NUMBER}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_ICON_FILE AppIcon
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${TVCRAFT_INSTALLER_BUNDLE_ID}"
    XCODE_ATTRIBUTE_SWIFT_VERSION 5.0
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE Manual
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "${TVCRAFT_INSTALLER_SIGN_IDENTITY}"
    XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${TVCRAFT_DEVELOPMENT_TEAM}"
    XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME YES
    XCODE_ATTRIBUTE_OTHER_CODE_SIGN_FLAGS "--timestamp"
    XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME AccentColor
    XCODE_GENERATE_SCHEME ON)
if(TVCRAFT_INSTALLER_SIGN_IDENTITY STREQUAL "-")
    # No timestamp server for ad hoc signatures.
    set_target_properties(TVCraftInstaller PROPERTIES XCODE_ATTRIBUTE_OTHER_CODE_SIGN_FLAGS "")
endif()

target_link_libraries(TVCraftInstaller PRIVATE
    "-framework AppKit"
    "-framework SwiftUI")
