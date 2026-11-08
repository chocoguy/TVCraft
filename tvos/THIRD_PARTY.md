# Third-party code in the tvOS app

Parts of `tvos/Sources` and `scripts/tvcraft.py` follow, or are adapted from, [TVPort](https://github.com/68hctmzzjf-svg/TVPort) and the [nxnative](https://github.com/seedds/nxnative) project it forks, which are under the MIT License:

- the Back-press handling and `GCEventViewController` routing (`dm/ios/Sources/front_ios.m`),
- keeping data in `Library/Caches` and the log redirect (`dm/ios/Sources/main.m`),
- the save protection in the app's preferences (`dm/ios/SourcesTV/TVSaves.m`),
- the controller mapping by position (`dm/ios/Sources/DmGamepad.m`, `dm/host/pad_apple.h`),
- team discovery, devicectl use, Jetsam reports and save backups (`tvport/backend.py`).
- the app icon and Top Shelf generator, `tvos/tools/tv_icon.swift` (`dm/ios/tools/tv_icon.swift`, copied unchanged).

```
MIT License

Copyright (c) 2026 seedds

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The game code is the MCPE-0.8.1 decompilation (submodule `MCPE-0.8.1-fortv`) with its own license and libraries (glm, jsoncpp, RakNet, OpenAES). The game's assets and sounds come from your own APK at build time and are never in this repository.
