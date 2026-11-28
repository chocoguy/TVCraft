# TVCraft for Apple TV

Minecraft PE 0.8.1 (the `MCPE-0.8.1-fortv` decompilation) as a tvOS app. You need a Mac with Xcode and its tvOS platform, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and your own Minecraft PE 0.8.1 APK in `apksource/`.

```bash
git submodule update --init --recursive MCPE-0.8.1-fortv
```

```bash
python3 scripts/tvcraft.py prepare
```

```bash
python3 scripts/tvcraft.py build --sim
```

```bash
python3 scripts/tvcraft.py sim
```

`prepare` copies the game's assets and sounds out of your APK into `tvos/staging`, which git ignores. The app icon, Top Shelf images and accent color are in `tvos/Assets.xcassets`. `prepare` checks that the APK's `libminecraftpe.so` is the build the decompilation matches. `prepare` remembers the APK it read (by path, size and date), so running it again is instant; `extract` always reads it again. `sim` installs and launches the app on the booted Apple TV simulator. `check` lists what's missing on this Mac.

On an Apple TV, paired with Xcode (**Window > Devices and Simulators**) and with an Apple ID signed in to Xcode:

```bash
python3 scripts/tvcraft.py devices
```

```bash
python3 scripts/tvcraft.py build --device <UDID>
```

```bash
python3 scripts/tvcraft.py install --device <UDID>
```

```bash
python3 scripts/tvcraft.py launch --device <UDID>
```

The app's bundle ID is `io.github.chocoguy.tvcraft.<team ID>` (bundle IDs are global, so every team needs its own); `--bundle-id` or `TVCRAFT_BUNDLE_ID` overrides it, and `--team` or `TVCRAFT_TEAM` picks the team. `install` backs up the worlds on the TV into `tvos/save-backups` first. `installed` shows the version on the TV.

`log` also sums up the frame rate in a world and the thermal state (the Apple TV has no fan, and tvOS lowers its clocks when it gets hot). `log`, `backup`, `restore` and `renew` take `--device` too: `python3 scripts/tvcraft.py --help` lists them all.

## The build engine

`scripts/tvcraft.py` is also the engine TVCraft Installer runs, from the release tag it checked out. With `--json`, every stdout line is one event (`stage`, `progress`, `check`, `error`, `warning`, `note`, `result`, `installed`) and the tools' own output goes to stderr. `--work-dir` moves the staged files, the build and the backups out of `tvos/`; `--xcodegen` names the XcodeGen binary. The version stamp (`CFBundleShortVersionString`, `CFBundleVersion`, `TVCraftVersion`, `TVCraftCommit`, `TVCraftGameVersion`) comes from `port.json` and git. Its tests: `python3 -I scripts/tests/test_tvcraft.py`.

## Controls

A game controller plays the game. The Siri Remote works the menus.

| In the game | |
|---|---|
| Left stick | Move |
| Right stick | Look |
| RT / LT | Mine and attack / use and place |
| A | Jump (hold it with D-pad up or down to fly up or down) |
| B or L3 | Sneak (on and off) |
| X | Inventory |
| Y | Crafting |
| LB / RB | Previous / next hotbar slot |
| D-pad | Walk |
| Menu | Pause |
| Options (View) | Third person |

In menus, the left stick (or the remote's touch surface) moves a cursor, and A (or a click) clicks. The D-pad steps through a screen's buttons, and then A presses the highlighted one. B or Back goes back. On the title screen, Back leaves for the Home screen. A text box opens tvOS's keyboard. A Bluetooth keyboard works too: arrows or WASD, Return or Space, and Escape.

## Testing in the simulator

The simulator has no controller to press, so two launch settings help:

- `TVCRAFT_INPUT_LOG=1` logs each press and controller change.
- `TVCRAFT_SCRIPT` plays input through the same code a controller uses. It is a list of `<seconds> <action> [args]` steps separated by `;`. The actions are:
  - `pad <button or axis> <value>`, for example `pad rt 1` or `pad ly 0.8`
  - `cursor <x> <y>` in game pixels (1920×1080)
  - `mouse 1` and `mouse 0`, which press and release A in a menu
  - `back`
  - `log`, which writes the screen, the player's position and the camera angles to the log

```bash
python3 scripts/tvcraft.py sim --env TVCRAFT_INPUT_LOG=1 --env 'TVCRAFT_SCRIPT=3 cursor 960 640; 3.3 mouse 1; 3.5 mouse 0; 5 log'
```

That one clicks Play on the title screen and logs the next screen.

## How it fits together

- `project.yml`: the Xcode project. It compiles the fork's `minecraftpe/impl` (everything except the Android, SDL and DirectSound files), RakNet, jsoncpp, OpenAES, `Sources/` and the staged `pcm_data.c`, and it copies the staged `assets` into the app. The staging folder comes from `TVCRAFT_STAGING`, which `tvcraft.py` sets.
- `Sources/main.mm`: sends the log to `Library/Caches/log.txt` and changes into the app's resources, so the game finds `assets/...` as the SDL build does.
- `Sources/GameViewController.mm`: an OpenGL ES 1.1 view at 1920×1080, the 60 fps frame loop, and the Back button.
- `MCPE-0.8.1-fortv/minecraftpe/impl/tvos/AppPlatform_tvos.cpp`: the game's platform class for tvOS.
- Data (worlds, options, the log) live in `Library/Caches`, the only place tvOS lets an app write files. tvOS may purge it while the app is closed.

The defines are `USEGLES`, `USEOPENAL`, `TVTWEAKS` (tvOS input and screen changes) and `NOCURL` (Realms requests fail as network errors). [THIRD_PARTY.md](THIRD_PARTY.md) credits the parts that follow TVPort.
