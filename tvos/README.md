# TVCraft for Apple TV

Minecraft PE 0.8.1 (the `MCPE-0.8.1-fortv` decompilation) as a tvOS app. You need a Mac with Xcode and its tvOS platform, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and your own Minecraft PE 0.8.1 APK in `apksource/`.

```bash
git submodule update --init --recursive
```

```bash
python3 scripts/tvcraft.py extract
```

```bash
python3 scripts/tvcraft.py build --sim
```

```bash
python3 scripts/tvcraft.py sim
```

`extract` copies the game's assets and sounds out of your APK into `tvos/staging`, which git ignores. It checks that the APK's `libminecraftpe.so` is the build the decompilation matches. `sim` installs and launches the app on the booted Apple TV simulator.

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

`log`, `backup`, `restore` and `renew` take `--device` too: `python3 scripts/tvcraft.py --help` lists them all.

## How it fits together

- `project.yml`: the Xcode project. It compiles the fork's `minecraftpe/impl` (everything except the Android, SDL and DirectSound files), RakNet, jsoncpp, OpenAES, `Sources/` and the staged `pcm_data.c`, and it copies `staging/assets` into the app.
- `Sources/main.mm`: sends the log to `Library/Caches/log.txt` and changes into the app's resources, so the game finds `assets/...` as the SDL build does.
- `Sources/GameViewController.mm`: an OpenGL ES 1.1 view at 1920×1080, the 60 fps frame loop, and the Back button.
- `MCPE-0.8.1-fortv/minecraftpe/impl/tvos/AppPlatform_tvos.cpp`: the game's platform class for tvOS.
- Data (worlds, options, the log) live in `Library/Caches`, the only place tvOS lets an app write files. tvOS may purge it while the app is closed.

The defines are `USEGLES`, `USEOPENAL`, `TVTWEAKS` (tvOS input and screen changes) and `NOCURL` (Realms requests fail as network errors). [THIRD_PARTY.md](THIRD_PARTY.md) credits the parts that follow TVPort.
