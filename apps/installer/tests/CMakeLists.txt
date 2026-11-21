# Checks the installer's logic without its UI: versions, the releases list, its saved state, the
# engine's events and port.json. Run with the "tests" presets (Ninja), or ctest.
add_executable(tvcraft_installertest main.swift ${TVCRAFT_INSTALLER_LOGIC_SOURCES})
set_target_properties(tvcraft_installertest PROPERTIES Swift_LANGUAGE_VERSION 5)
add_test(NAME installer_logic COMMAND tvcraft_installertest)
