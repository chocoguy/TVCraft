# TVCraft
## A port of Minecraft PE for the Apple TV

![Logo](https://mangogravy.com/tvcraft-small.jpg)

It's a port of Minecraft: Pocket Edition 0.8.1 that runs natively on the apple tv

built from the [MCPE 0.8.1 decompilation](https://github.com/oldminecraftcommunity/MCPE-0.8.1) (My fork: [MCPE-0.8.1-fortv](https://github.com/chocoguy/MCPE-0.8.1-fortv)). The long-term goal is Minecraft PE 1.1.5 ([MCPE-1.1.5-decomp](https://github.com/chocoguy/MCPE-1.1.5-decomp)).

**No original game files or assets are in this repository.** 

## Requirements

- An Apple Silicon Mac
- macOS 27
- XCode 27
- An Apple TV 4K (3rd gen or newer) with tvOS 27, paired with Xcode (**Xcode → Window → Devices and Simulators**).
- An Apple ID signed in to Xcode (**Xcode → Settings → Accounts**). A free one works, but its installs open for 7 days; then reinstall to renew. A paid Apple Developer account lasts a year.
- Your own Minecraft PE **0.8.1** APK (armeabi-v7a, version code 500801011).
- A bluetooth gamepad for playing (Duh)

## Install

1. Download **TVCraft Installer** from the [latest release](https://github.com/chocoguy/TVCraft/releases/latest) Drag the .app package to the ***Applications Folder***
2. Is the .app package in the **Applications folder???***
3. **Setup** checks Xcode and fixes what's missing (it downloads XcodeGen itself).
4. **Game**: choose your APK, then **Install On** your Apple TV. It builds the game and installs it; open it from the Apple TV's Home screen.
5. **Updates**: when a new release is out, **Update All** rebuilds and reinstalls it. Your worlds are backed up to the Mac before every install. When a release needs a new installer, it says so and links to it; until you download it, game updates wait, but **Reinstall** still works (to renew a free Apple ID's 7 days).

Everything the installer downloads and builds stays in one folder, `~/Library/Application Support/TVCraft Installer/`, never inside the app, so replacing or redownloading the installer keeps it. **Setup → Storage** shows its size, opens it in Finder, frees up space (the Xcode build, made again on the next install) or removes everything (the game stays on your Apple TV).

## Controls

| In the game | |
|---|---|
| Left stick | Move |
| Right stick | Look |
| RT / LT | Mine and attack / use and place |
| A | Jump (hold it with D-pad up or down to fly up or down) |
| B or L3 | Sneak |
| X / Y | Inventory / crafting |
| LB / RB | Previous / next hotbar slot |
| Menu | Pause |

In menus, the left stick (or the remote's touch surface) moves a cursor and A clicks workaround for all the touchscreen tap stuff.

## For developers 

The Terminal path, the build engine and the simulator tools are in [tvos/README.md](tvos/README.md). Releases are made with `tools/release.sh` ([docs/release.md](docs/release.md)); the installer's status and test checklist are in [docs/installer-status.md](docs/installer-status.md).

## Credits

Original game © Mojang, Microsoft.

Shoutouts to [MCPE 0.8.1](https://github.com/oldminecraftcommunity/MCPE-0.8.1), [TVPort](https://github.com/68hctmzzjf-svg/TVPort) and Claude. [tvos/THIRD_PARTY.md](tvos/THIRD_PARTY.md) lists the third-party code.
