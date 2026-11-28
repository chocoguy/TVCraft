# TVCraft Installer: credits

## Frontline Rewritten

TVCraft Installer derives from the installer of [Frontline Rewritten](https://github.com/chocoguy/FrontlineRewritten) (`apps/installer/`, `tests/installertest/`), by the same author: its workspace layout, the GitHub releases track, the process runner, the setup checks, the Activity screen and the logic tests come from there, adapted for one Apple TV-only port built from an APK with XcodeGen.

## XcodeGen

The installer downloads [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT license) from its GitHub release into the player's workspace when the Mac has none; it isn't part of the installer.
