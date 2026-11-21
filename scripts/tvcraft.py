#!/usr/bin/env python3
"""TVCraft: build Minecraft PE 0.8.1 (the MCPE-0.8.1-fortv decompilation) into an Apple TV app and manage it on the TV.

This is also the build engine TVCraft Installer runs (from the release tag it checked out) with --json: each line on
stdout is then one JSON event, and everything the tools print goes to stderr.

Commands (each exits non-zero on error):
  check                   report each prerequisite (Xcode, the tvOS platform, XcodeGen, your APK, a signing team)
  prepare                 stage the game's assets and sounds from your own 0.8.1 APK (read once, then cached)
  extract                 the same, always reading the APK again
  build [--sim | --device ID] [--platform tvos]   generate the Xcode project and build the app (simulator, or signed for a device)
  install --device ID     back up the worlds on the TV, then install the device build (it never launches it)
  installed --device ID   what version of the game is on the TV
  clean                   remove what prepare and build made
  devices                 list Apple TVs paired with this Mac
  sim [--udid UDID]       install and launch the simulator build on a booted Apple TV simulator
  launch --device ID      launch it (ending a running copy first)
  log --device ID         copy the last run's log and memory-kill reports off the TV and summarise them
  backup --device ID      copy the worlds off the TV into the backups folder
  restore --device ID     put the newest backup back on a TV that has lost its worlds
  renew --device ID       rebuild and reinstall when a free Apple ID's install is about to stop opening

Every command takes --json, --work-dir DIR (staging, build and backups go there instead of tvos/), --apk/--disc FILE,
--team ID, --bundle-id ID and --xcodegen PATH.

Several device functions follow TVPort's tvport/backend.py (MIT): team discovery, devicectl, launching, Jetsam reports and save backups.
"""
import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, List, Optional

ROOT = Path(__file__).resolve().parent.parent
FORK = ROOT / 'MCPE-0.8.1-fortv'
TVOS = ROOT / 'tvos'
APK_DIR = ROOT / 'apksource'
PORT_JSON = ROOT / 'port.json'

# Where prepare, build and backup write. configure() moves them into --work-dir.
STAGING = TVOS / 'staging'
BUILD = TVOS / 'build'
BACKUPS = TVOS / 'save-backups'

LIB_IN_APK = 'lib/armeabi-v7a/libminecraftpe.so'
DEFAULT_ICON = 'assets/app/ios/icons/mcpe_ios_icon.png'   # in the APK: the iOS app's 512x512 icon
LIB_SHA1 = 'c30bd6e3b72be7b97a222d79d1405b55f6d3bf71'   # the build tools/get_sound_data.py's offsets were taken from
BASE_BUNDLE_ID = 'io.github.chocoguy.tvcraft'            # a build gets BASE_BUNDLE_ID.<team>: bundle IDs are global, so each team needs its own
SCHEME = 'TVCraft'
CACHES = 'Library/Caches'
WORLDS = 'games/com.mojang/minecraftWorlds'
SAVE_FILE = re.compile(r'^games/com\.mojang/(minecraftWorlds/[^/]+/(level\.dat|chunks\.dat|entities\.dat|player\.dat)|minecraftpe/options\.txt)$')
TV_TIMEOUT_S = 30
LAUNCH_SETTLE_S = 3
PREPARE_SCHEMA = 1                     # bump when prepare's output changes, so cached staging is redone
MIN_XCODE = (27, 0)
MIN_PYTHON = (3, 9)
EXTRA_PATH = ['/opt/homebrew/bin', '/usr/local/bin']   # an app opened from Finder gives its tools only /usr/bin:/bin:/usr/sbin:/sbin

JSON = False


class Failure(Exception):
    def __init__(self, message: str, code: str = 'failed', fix: str = ''):
        super().__init__(message)
        self.message, self.code, self.fix = message, code, fix


# ---------- events ----------

def emit(event: str, **fields) -> None:
    """One event: a JSON line on stdout with --json, otherwise plain text for the Terminal."""
    if JSON:
        print(json.dumps({'event': event, **fields}), flush=True)
        return
    if event == 'stage':
        print(f'==> {fields["label"]}', flush=True)
    elif event == 'check':
        print(f'{"ok " if fields["ok"] else "NO "} {fields["label"]}: {fields["detail"]}', flush=True)
        if not fields['ok'] and fields.get('fix'):
            print(f'    {fields["fix"]}', flush=True)
    elif event == 'error':
        print(f'tvcraft: {fields["message"]}', file=sys.stderr, flush=True)
        if fields.get('fix'):
            print(f'  {fields["fix"]}', file=sys.stderr, flush=True)
    elif event == 'warning':
        print(f'warning: {fields["message"]}', flush=True)
    elif event == 'note':
        print(fields['message'], flush=True)
    elif event == 'result':
        print(f'Built {fields["app"]} ({fields.get("version")}, {fields.get("commit") or "no commit"})', flush=True)
    elif event == 'installed':
        print(f'Installed: {fields.get("version")} (build {fields.get("build")})' if fields['present'] else 'Not installed', flush=True)


def stage(name: str, label: str) -> None:
    emit('stage', id=name, label=label)


def note(message: str) -> None:
    emit('note', message=message)


def warn(message: str) -> None:
    emit('warning', message=message)


def run(argv: Iterable, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run([str(a) for a in argv], capture_output=True, text=True, **kwargs)


def stream(argv: Iterable, **kwargs) -> None:
    """Run a long command, showing its output as it goes (on stderr with --json: stdout is the events')."""
    argv = [str(a) for a in argv]
    if subprocess.run(argv, stdout=sys.stderr if JSON else None, **kwargs).returncode:
        raise Failure(f'{Path(argv[0]).name} failed')


def stream_lines(argv: Iterable, on_line=None, keep: int = 300, **kwargs) -> tuple:
    """Run a command, passing each output line to stderr (or stdout outside --json) and on_line. Its status and last lines."""
    process = subprocess.Popen([str(a) for a in argv], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace', **kwargs)
    tail: List[str] = []
    for line in process.stdout:
        print(line, end='', file=sys.stderr if JSON else sys.stdout, flush=True)
        tail = (tail + [line.rstrip('\n')])[-keep:]
        if on_line:
            on_line(line)
    return process.wait(), tail


# ---------- paths, versions, identity ----------

def configure(work_dir: Optional[str], xcodegen: Optional[str] = None) -> None:
    """Point staging, build and backups at --work-dir, and give child tools a PATH that works when opened from Finder."""
    global STAGING, BUILD, BACKUPS
    if work_dir:
        work = Path(work_dir).expanduser().resolve()
        STAGING, BUILD, BACKUPS = work / 'staging', work / 'build', work / 'save-backups'
    extra = ([str(Path(xcodegen).expanduser().resolve().parent)] if xcodegen else []) + EXTRA_PATH
    path = os.environ.get('PATH', '/usr/bin:/bin:/usr/sbin:/sbin').split(':')
    os.environ['PATH'] = ':'.join([p for p in extra if p not in path] + path)


def port_info() -> dict:
    try:
        return json.loads(PORT_JSON.read_text())
    except (OSError, ValueError):
        return {}


def numeric_version(version: str) -> tuple:
    """(major, minor, patch) of "v1.2.3-rc1", "1.2" and the like; missing parts are 0."""
    found = re.match(r'v?(\d+)(?:\.(\d+))?(?:\.(\d+))?', version.strip())
    return tuple(int(part or 0) for part in found.groups()) if found else (0, 0, 0)


def build_number(version: str) -> int:
    major, minor, patch = numeric_version(version)
    return major * 10000 + minor * 100 + patch


def git_commit() -> str:
    result = run(['git', '-C', ROOT, 'rev-parse', '--short', 'HEAD'])
    return result.stdout.strip() if result.returncode == 0 else ''


def team_bundle_id(team: str) -> str:
    return f'{BASE_BUNDLE_ID}.{team}' if team else BASE_BUNDLE_ID


def app_path(sim: bool) -> Path:
    return BUILD / 'Build/Products' / ('Release-appletvsimulator' if sim else 'Release-appletvos') / f'{SCHEME}.app'


def built_bundle_id(sim: bool) -> str:
    try:
        return plistlib.loads((app_path(sim) / 'Info.plist').read_bytes()).get('CFBundleIdentifier', '')
    except (OSError, plistlib.InvalidFileException, ValueError):
        return ''


def bundle_id(args, sim: bool = False) -> str:
    """The app's bundle ID: --bundle-id, TVCRAFT_BUNDLE_ID, the built app's, else BASE_BUNDLE_ID.<team>."""
    given = getattr(args, 'bundle_id', None) or os.environ.get('TVCRAFT_BUNDLE_ID')
    return given or built_bundle_id(sim) or team_bundle_id('' if sim else known_team(getattr(args, 'team', None)))


# ---------- prepare (extract) ----------

def find_apk(given: Optional[str]) -> Path:
    if given:
        apk = Path(given).expanduser()
        if not apk.is_file():
            raise Failure(f'No APK at {apk}', 'apk-missing', 'Choose your Minecraft PE 0.8.1 APK again.')
        return apk
    found = sorted(APK_DIR.glob('*0.8.1*.apk'))
    if not found:
        raise Failure(f'Put your Minecraft PE 0.8.1 APK in {APK_DIR} (or pass --apk)', 'apk-missing', 'Pass --apk with your own 0.8.1 APK.')
    return found[0]


def sha1(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def read_game_library(apk: Path) -> bytes:
    """The APK's libminecraftpe.so, if it is the build the decompilation matches."""
    try:
        with zipfile.ZipFile(apk) as z:
            lib = z.read(LIB_IN_APK)
    except (zipfile.BadZipFile, OSError):
        raise Failure(f'{apk.name} is not an APK that can be read', 'apk-unreadable', 'Choose the .apk file of Minecraft PE 0.8.1.') from None
    except KeyError:
        raise Failure(f'{apk.name} has no {LIB_IN_APK}', 'apk-wrong', 'TVCraft needs the armeabi-v7a APK of Minecraft PE 0.8.1.') from None
    if sha1(lib) != LIB_SHA1:
        raise Failure(f'{LIB_IN_APK} in this APK is not the 0.8.1 build the decompilation matches (SHA-1 {sha1(lib)}, want {LIB_SHA1})',
                      'apk-wrong', 'TVCraft needs Minecraft PE 0.8.1 (500801011), armeabi-v7a.')
    return lib


def prepare_stamp(apk: Path, icon: Optional[str]) -> dict:
    """What prepare's output depends on: the APK (by path, size and modification time), the icon and this script's schema."""
    info = apk.resolve().stat()
    return {'schema': PREPARE_SCHEMA, 'apk': str(apk.resolve()), 'size': info.st_size, 'mtime_ns': info.st_mtime_ns, 'icon': icon or ''}


def staged() -> bool:
    return (STAGING / 'pcm_data.c').is_file() and (STAGING / 'assets').is_dir() and (STAGING / 'Assets.xcassets').is_dir()


def cmd_prepare(args, force: bool = False) -> None:
    apk = find_apk(args.apk)
    stamp = prepare_stamp(apk, args.icon)
    stamp_file = STAGING / 'prepared.json'
    try:
        cached = json.loads(stamp_file.read_text())
    except (OSError, ValueError):
        cached = None
    if not force and cached == stamp and staged():
        note(f'{apk.name} is already prepared.')
        return
    stamp_file.unlink(missing_ok=True)
    stage('apk', 'Reading your APK')
    note(f'APK: {apk.name}')
    lib = read_game_library(apk)
    with zipfile.ZipFile(apk) as z:
        assets = [n for n in z.namelist() if n.startswith('assets/') and not n.endswith('/')]
        out = STAGING / 'assets'
        if out.exists():
            shutil.rmtree(out)
        for count, name in enumerate(assets, 1):
            target = (STAGING / name).resolve()
            if STAGING.resolve() not in target.parents:   # a name with ../ in it
                raise Failure(f'Unsafe path in the APK: {name}', 'apk-unsafe', 'Use an unmodified APK.')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(z.read(name))
            if count % 100 == 0:
                emit('progress', fraction=round(count / len(assets), 3))
    note(f'Assets: {len(assets)} files in {out}')
    stage('sounds', 'Extracting the sounds')
    with tempfile.TemporaryDirectory() as folder:
        so = Path(folder) / 'libminecraftpe.so'
        so.write_bytes(lib)
        tool = FORK / 'tools/get_sound_data.py'
        result = run([sys.executable, '-I', tool, so], cwd=folder)
        if result.returncode or not (Path(folder) / 'pcm_data.c').is_file():
            raise Failure(f'get_sound_data.py failed: {result.stderr.strip()[-500:]}', 'sounds-failed')
        STAGING.mkdir(parents=True, exist_ok=True)
        shutil.move(str(Path(folder) / 'pcm_data.c'), STAGING / 'pcm_data.c')
    note(f'Sounds: {(STAGING / "pcm_data.c").stat().st_size / 2**20:.1f} MB of C in {STAGING / "pcm_data.c"}')
    stage('icon', 'Making the icon and Top Shelf images')
    make_icon(Path(args.icon).expanduser() if args.icon else STAGING / DEFAULT_ICON)
    stamp_file.write_text(json.dumps(stamp, indent=1) + '\n')


def cmd_extract(args) -> None:
    cmd_prepare(args, force=True)


def make_icon(image: Path) -> None:
    """tvOS's layered app icon and Top Shelf banners from one image, by TVPort's tv_icon.swift, into the staging Assets.xcassets."""
    if not image.is_file():
        raise Failure(f'No icon image at {image}', 'icon-missing')
    catalog = STAGING / 'Assets.xcassets'
    result = run(['xcrun', 'swift', TVOS / 'tools/tv_icon.swift', image, catalog])
    if result.returncode:
        raise Failure(f'tv_icon.swift: {result.stderr.strip()[-500:]}', 'icon-failed')
    note(f'Icon and Top Shelf: from {image.name} in {catalog}')


# ---------- signing teams ----------

def xcode_teams(prefs: dict) -> list:
    """The teams of the Apple IDs signed in to Xcode, personal (free) teams first."""
    teams = [team for account in prefs.get('IDEProvisioningTeamByIdentifier', {}).values() for team in account if team.get('teamID')]
    return [team['teamID'] for team in sorted(teams, key=lambda team: not team.get('isFreeProvisioningTeam'))]


def free_teams(prefs: dict) -> set:
    return {team['teamID'] for account in prefs.get('IDEProvisioningTeamByIdentifier', {}).values() for team in account
            if team.get('teamID') and team.get('isFreeProvisioningTeam')}


def xcode_prefs() -> dict:
    exported = run(['defaults', 'export', 'com.apple.dt.Xcode', '-'])
    try:
        return plistlib.loads(exported.stdout.encode()) if exported.returncode == 0 else {}
    except (plistlib.InvalidFileException, ValueError):
        return {}


def known_team(given: Optional[str] = None) -> str:
    """A team to sign with: --team, TVCRAFT_TEAM, else the newest provisioning profile's, else the first Apple ID signed in to Xcode."""
    if given:
        return given
    if os.environ.get('TVCRAFT_TEAM'):
        return os.environ['TVCRAFT_TEAM']
    folders = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles', Path.home() / 'Library/MobileDevice/Provisioning Profiles']
    for folder in folders:
        for profile in sorted(folder.glob('*.mobileprovision'), key=lambda p: p.stat().st_mtime, reverse=True) if folder.is_dir() else []:
            decoded = run(['security', 'cms', '-D', '-i', profile])
            if decoded.returncode == 0:
                return plistlib.loads(decoded.stdout.encode())['TeamIdentifier'][0]
    teams = xcode_teams(xcode_prefs())
    return teams[0] if teams else ''


# ---------- check ----------

def version_of(text: str) -> tuple:
    found = re.search(r'(\d+)\.(\d+)', text)
    return (int(found[1]), int(found[2])) if found else (0, 0)


def find_xcodegen(given: Optional[str]) -> str:
    if given:
        path = Path(given).expanduser()
        return str(path) if os.access(path, os.X_OK) else ''
    return shutil.which('xcodegen') or ''


def cmd_check(args) -> int:
    results = []

    def check(name: str, label: str, ok: bool, detail: str, fix: str = '') -> None:
        results.append(bool(ok))
        emit('check', id=name, label=label, ok=bool(ok), detail=detail, fix='' if ok else fix)

    check('mac', 'Apple silicon Mac', platform.machine() == 'arm64', platform.machine(), 'TVCraft builds on Apple silicon Macs only.')

    developer = run(['xcode-select', '-p']).stdout.strip()
    xcode = run(['xcodebuild', '-version']) if developer and 'CommandLineTools' not in developer else None
    xcode_line = xcode.stdout.splitlines()[0] if xcode and xcode.returncode == 0 and xcode.stdout else ''
    check('xcode', f'Xcode {MIN_XCODE[0]} or later', bool(xcode_line) and version_of(xcode_line) >= MIN_XCODE,
          xcode_line or (f'only the Command Line Tools ({developer})' if developer else 'not found'),
          'Install Xcode from the App Store, open it once, then: sudo xcode-select -s /Applications/Xcode.app')
    if xcode_line:
        first = run(['xcodebuild', '-checkFirstLaunchStatus'])
        check('xcode-first-launch', 'Xcode set up', first.returncode == 0, 'done' if first.returncode == 0 else 'not yet',
              'Open Xcode once and let it install its components.')
        sdks = run(['xcodebuild', '-showsdks', '-json'])
        try:
            names = [s.get('canonicalName', '') for s in json.loads(sdks.stdout or '[]') if s.get('platform') == 'appletvos']
        except ValueError:
            names = []
        check('platform-tvos', 'tvOS support in Xcode', bool(names), names[-1] if names else 'not installed', 'Run: xcodebuild -downloadPlatform tvOS')

    xcodegen = find_xcodegen(args.xcodegen)
    xcodegen_version = run([xcodegen, '--version']).stdout.strip() if xcodegen else ''
    check('xcodegen', 'XcodeGen', bool(xcodegen), xcodegen_version or 'not found', 'Install it: brew install xcodegen (TVCraft Installer downloads its own).')

    check('python', f'Python {MIN_PYTHON[0]}.{MIN_PYTHON[1]} or later', sys.version_info[:2] >= MIN_PYTHON, platform.python_version(), 'Update Xcode.')
    check('source', 'Game source (MCPE-0.8.1-fortv)', (FORK / 'RakNet/Source').is_dir() and (FORK / 'minecraftpe/impl').is_dir(),
          str(FORK), 'Run: git submodule update --init --recursive MCPE-0.8.1-fortv')

    try:
        apk = find_apk(args.apk)
        read_game_library(apk)
        check('apk', 'Your Minecraft PE 0.8.1 APK', True, apk.name)
    except Failure as failure:
        check('apk', 'Your Minecraft PE 0.8.1 APK', False, failure.message, failure.fix)

    team = known_team(args.team)
    free = team in free_teams(xcode_prefs())
    check('team', 'A signing team (Apple ID in Xcode)', bool(team),
          (f'{team}, a free Apple ID: installs open for 7 days' if free else team) if team else 'none',
          'Sign in to Xcode with an Apple ID: Xcode > Settings > Accounts.')
    return 0 if all(results) else 1


# ---------- build ----------

# What a failed build said, and what to tell the user. The first that matches wins.
KNOWN_FAILURES = [
    (r'No Accounts?\b|No Account for Team|not signed in',
     'xcode-account', "Xcode isn't signed in to the team's Apple ID.", 'Sign in under Xcode > Settings > Accounts.'),
    (r'has no devices|no devices from which|[Nn]o devices? (?:are|is) registered',
     'no-devices', 'The team has no Apple TV registered.', "Pair the Apple TV in Xcode's Devices window, switch it on and wake it, then build again."),
    (r'(?:App ID|identifier).*(?:is not available|cannot be registered|already in use)',
     'bundle-id-taken', 'The bundle ID {bundle} belongs to another team.', 'Pass a different --bundle-id.'),
    (r'maximum number of apps|[Ll]imit.*App IDs',
     'app-id-limit', 'A free Apple ID can register only a few app IDs a week.', 'Wait a few days, or use a paid Apple Developer team.'),
    (r'[Nn]o (?:signing certificate|certificate)',
     'certificate', 'No development certificate for the team is on this Mac.',
     'Xcode > Settings > Accounts: select the team, Manage Certificates, and add an Apple Development certificate.'),
    (r'No profiles? for',
     'no-profile', "Xcode couldn't make a provisioning profile for the app.", "Check the team in Xcode > Settings > Accounts, and that the Apple TV is paired."),
    (r'Unable to find a destination|is not available|device is locked|asleep',
     'device-unreachable', "Xcode couldn't reach the Apple TV.", 'Wake the Apple TV with its remote, check it in Xcode > Window > Devices and Simulators, then try again.'),
]


def explain(lines: List[str], bundle: str) -> Failure:
    errors = [line for line in lines if re.search(r'\berror\b', line, re.IGNORECASE)] or lines[-20:]
    text = '\n'.join(errors)
    for pattern, code, message, fix in KNOWN_FAILURES:
        if re.search(pattern, text):
            return Failure(message.format(bundle=bundle), code, fix.format(bundle=bundle))
    first = next((line.strip() for line in errors if line.strip()), 'the build failed')
    return Failure(first[:400], 'build-failed', 'The full log says more.')


def check_staged() -> None:
    if not staged():
        raise Failure('The game files are not staged', 'not-prepared', 'Run "tvcraft.py prepare" first.')
    if not (FORK / 'RakNet/Source').is_dir():
        raise Failure("The fork's submodules are missing", 'source-missing', 'Run: git submodule update --init --recursive MCPE-0.8.1-fortv')


def generate_project(team: str, bundle: str, xcodegen: Optional[str]) -> Path:
    tool = find_xcodegen(xcodegen)
    if not tool:
        raise Failure('XcodeGen is missing', 'xcodegen-missing', 'brew install xcodegen (TVCraft Installer downloads its own)')
    env = dict(os.environ, TVCRAFT_TEAM=team, TVCRAFT_BUNDLE_ID=bundle, TVCRAFT_STAGING=str(STAGING.resolve()))
    result = run([tool, 'generate', '--spec', TVOS / 'project.yml', '--project', TVOS], env=env)
    if result.returncode:
        raise Failure(result.stderr.strip() or result.stdout.strip(), 'configure-failed')
    return TVOS / f'{SCHEME}.xcodeproj'


def source_count() -> int:
    """About how many files the build compiles (project.yml's sources), for its progress."""
    impl = FORK / 'minecraftpe/impl'
    skip = {'AppPlatform_sdl.cpp', 'main.cpp', 'SoundSystemDirectSound.cpp', 'SoundSystemSL.cpp'}
    files = [p for p in impl.rglob('*') if p.suffix in ('.c', '.cpp', '.cc', '.m', '.mm') and 'android' not in p.relative_to(impl).parts and p.name not in skip]
    files += list((FORK / 'RakNet/Source').glob('*.cpp')) + list((FORK / 'jsoncpp/jsoncpp/src/lib_json').glob('*.cpp')) + list((TVOS / 'Sources').glob('*.mm'))
    return len(files) + 3   # OpenAES's two files and pcm_data.c


def hardware_udid(device: str) -> str:
    """The UDID for `device`, which may be devicectl's own identifier (they differ), its name or the UDID itself. `device` if devicectl doesn't know it."""
    try:
        entries = devicectl_json('list', 'devices', timeout=TV_TIMEOUT_S).get('result', {}).get('devices', [])
    except (Failure, ValueError):
        entries = []
    for entry in entries:
        hardware = entry.get('hardwareProperties', {})
        if device in {entry.get('identifier'), hardware.get('udid'), entry.get('deviceProperties', {}).get('name')} and hardware.get('udid'):
            return hardware['udid']
    return device


def cmd_build(args) -> None:
    check_staged()
    sim = getattr(args, 'sim', False) or not args.device
    team = '' if sim else known_team(getattr(args, 'team', None))
    if not sim and not team:
        raise Failure('No signing team', 'no-team', 'Sign in to Xcode with an Apple ID (Settings > Accounts), or pass --team')
    bundle = getattr(args, 'bundle_id', None) or os.environ.get('TVCRAFT_BUNDLE_ID') or team_bundle_id(team)
    info = port_info()
    version = info.get('version', '0.0.0')
    commit = git_commit()
    stage('configure', 'Setting up the Xcode project')
    project = generate_project(team, bundle, getattr(args, 'xcodegen', None))
    if sim:
        destination = 'generic/platform=tvOS Simulator'
    elif args.device == 'generic':
        destination = 'generic/platform=tvOS'
    else:
        destination = f'platform=tvOS,id={hardware_udid(args.device)}'
    major, minor, patch = numeric_version(version)
    command = ['xcodebuild', '-project', project, '-scheme', SCHEME, '-configuration', 'Release', '-destination', destination, '-derivedDataPath', BUILD,
               f'MARKETING_VERSION={major}.{minor}.{patch}', f'CURRENT_PROJECT_VERSION={build_number(version)}',
               f'TVCRAFT_VERSION={version}', f'TVCRAFT_COMMIT={commit or "unknown"}']
    command += ['CODE_SIGNING_ALLOWED=NO'] if sim else ['-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration']
    command += ['build'] if JSON else ['-quiet', 'build']
    stage('compile', 'Compiling the game')
    total, done = source_count(), [0]

    def on_line(line: str) -> None:
        if line.startswith('CompileC '):
            done[0] += 1
            if done[0] % 10 == 0:
                emit('progress', fraction=round(min(0.99, done[0] / total), 3))

    status, tail = stream_lines(command, on_line)
    if status:
        raise explain(tail, bundle)
    emit('progress', fraction=1.0)
    app = app_path(sim)
    profile = provisioning(app) if not sim else {}
    result = {'app': str(app), 'bundleId': bundle, 'version': version, 'commit': commit, 'platform': 'tvos', 'simulator': sim,
              'team': profile.get('team', team), 'expires': profile.get('expires'), 'free': profile.get('free_team', False)}
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / ('result-sim.json' if sim else 'result.json')).write_text(json.dumps(result, indent=1) + '\n')
    emit('result', **result)


def booted_tv_sim(udid: Optional[str]) -> str:
    if udid:
        return udid
    listing = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'booted', '-j']).stdout or '{}')
    for runtime, devices in listing.get('devices', {}).items():
        if 'tvOS' in runtime:
            for device in devices:
                if device.get('state') == 'Booted':
                    return device['udid']
    raise Failure('No Apple TV simulator is booted: open Simulator and boot one (or pass --udid)', 'no-simulator')


def cmd_sim(args) -> None:
    udid = booted_tv_sim(args.udid)
    app = app_path(True)
    if not app.is_dir():
        raise Failure('Build for the simulator first: tvcraft.py build --sim', 'not-built')
    bundle = bundle_id(args, sim=True)
    # As on a TV (cmd_launch): ending the old copy brings the Home screen back, which can land on top of a launch made at once and suspend it
    if run(['xcrun', 'simctl', 'terminate', udid, bundle]).returncode == 0:
        time.sleep(LAUNCH_SETTLE_S)
    result = run(['xcrun', 'simctl', 'install', udid, app])
    if result.returncode:
        raise Failure(result.stderr.strip(), 'install-failed')
    env = dict(os.environ, **{f'SIMCTL_CHILD_{k}': v for k, v in (args.env or [])})
    result = run(['xcrun', 'simctl', 'launch', udid, bundle], env=env)
    if result.returncode:
        raise Failure(result.stderr.strip(), 'launch-failed')
    container = run(['xcrun', 'simctl', 'get_app_container', udid, bundle, 'data']).stdout.strip()
    note(f'Launched on {udid}. Log: {container}/{CACHES}/log.txt')


# ---------- device ----------

def devicectl_json(*args, timeout: Optional[float] = None) -> dict:
    with tempfile.TemporaryDirectory() as folder:
        out = Path(folder) / 'out.json'
        try:
            result = run(['xcrun', 'devicectl', *args, '--quiet', '--json-output', out], timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failure('The Apple TV did not answer.', 'device-unreachable', 'Wake it with the remote, then try again.') from None
        if not out.is_file():
            raise Failure(result.stderr.strip() or 'devicectl gave no answer. Is Xcode installed?', 'devicectl-failed')
        return json.loads(out.read_text())


def apple_tvs(listing: dict) -> list:
    tvs = []
    for device in listing.get('result', {}).get('devices', []):
        hardware = device.get('hardwareProperties', {})
        if hardware.get('deviceType') != 'appleTV' or hardware.get('reality') != 'physical':
            continue
        properties, connection = device.get('deviceProperties', {}), device.get('connectionProperties', {})
        tvs.append({'id': hardware.get('udid'), 'identifier': device.get('identifier'), 'name': properties.get('name'), 'model': hardware.get('marketingName'),
                    'os': properties.get('osVersionNumber'), 'connected': connection.get('tunnelState') == 'connected',
                    'developer_mode': properties.get('developerModeStatus') == 'enabled'})
    return tvs


def cmd_devices(_) -> None:
    tvs = apple_tvs(devicectl_json('list', 'devices', timeout=TV_TIMEOUT_S))
    if JSON:
        for tv in tvs:
            emit('device', **tv)
        return
    if not tvs:
        print('No Apple TV is paired with this Mac (Xcode > Window > Devices and Simulators).')
    for tv in tvs:
        state = 'connected' if tv['connected'] else 'not connected'
        mode = '' if tv['developer_mode'] else ', developer mode off'
        print(f'{tv["id"]}  {tv["name"]} ({tv["model"]}, tvOS {tv["os"]}): {state}{mode}')


def provisioning(app: Path) -> dict:
    """What a signed app's profile says: its team, and when tvOS stops opening it."""
    profile = app / 'embedded.mobileprovision'
    if not profile.is_file():
        return {}
    decoded = run(['security', 'cms', '-D', '-i', profile])
    if decoded.returncode:
        return {}
    data = plistlib.loads(decoded.stdout.encode())
    expires = data['ExpirationDate'].replace(tzinfo=timezone.utc)
    return {'team': data['TeamIdentifier'][0], 'expires': expires.isoformat(), 'days_left': (expires - datetime.now(timezone.utc)).days,
            'free_team': bool(data.get('LocalProvision')) or (expires - data['CreationDate'].replace(tzinfo=timezone.utc)).days <= 7}


def cmd_install(args) -> None:
    app = app_path(False)
    if not (app / 'embedded.mobileprovision').is_file():
        raise Failure('The app has not been built for a device yet', 'not-built', 'Run: tvcraft.py build --device <UDID>')
    bundle = bundle_id(args)
    stage('backup', 'Backing up your worlds')
    try:
        backup_worlds(args.device, bundle)
    except Failure as failure:   # the data container survives an update with the same bundle ID; the backup is a second copy
        warn(f'No backup this time: {failure.message}')
    stage('install', 'Installing on the Apple TV')
    status, tail = stream_lines(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device, app])
    if status:
        message = '\n'.join(tail)
        if 'asleep' in message or 'locked' in message:
            raise Failure('The Apple TV is asleep.', 'device-asleep', 'Wake it with the remote, then try again.')
        raise Failure(message.strip()[-900:] or 'The install failed', 'install-failed', "Wake the Apple TV, check it in Xcode's Devices window, and try again.")
    info = provisioning(app)
    note(f'Installed. It opens until {info.get("expires", "?")[:10]}' + (' (free Apple ID: Reinstall, or "renew", before then)' if info.get('free_team') else ''))


def cmd_installed(args) -> None:
    bundle = bundle_id(args)
    data = devicectl_json('device', 'info', 'apps', '--device', args.device, '--bundle-id', bundle, timeout=TV_TIMEOUT_S)
    if 'error' in data and 'result' not in data:
        raise Failure("Couldn't ask the Apple TV what's installed.", 'device-unreachable', "Wake it up and check it's paired in Xcode's Devices window.")
    found = next((a for a in data.get('result', {}).get('apps', []) if a.get('bundleIdentifier') == bundle), None)
    if found:
        emit('installed', present=True, bundleId=bundle, version=found.get('version'), build=found.get('bundleVersion'))
    else:
        emit('installed', present=False, bundleId=bundle)


def running_pids(listing: dict, executable: str = SCHEME) -> list:
    return [str(p['processIdentifier']) for p in listing.get('result', {}).get('runningProcesses', []) if p.get('executable', '').rstrip('/').endswith(f'/{executable}')]


def cmd_launch(args) -> None:
    # devicectl's --terminate-existing launches at once, and the Home screen coming back can land on top of the new launch, so the old copy goes first (TVPort backend.py cmd_launch)
    pids = running_pids(devicectl_json('device', 'info', 'processes', '--device', args.device, timeout=TV_TIMEOUT_S))
    for pid in pids:
        run(['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', args.device, '--pid', pid])
    if pids:
        time.sleep(LAUNCH_SETTLE_S)
    bundle = bundle_id(args)
    env = ['--environment-variables', json.dumps(dict(args.env))] if getattr(args, 'env', None) else []
    result = run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device, *env, bundle])
    if result.returncode:
        message = result.stdout + result.stderr
        raise Failure('The Apple TV is asleep. Wake it with the remote, then try again.' if 'asleep' in message else message.strip()[-700:], 'launch-failed')
    note(f'Launched {bundle}')


def read_jetsam(folder: Path, process: str = SCHEME) -> list:
    """Times tvOS ended this app for memory: an out-of-memory kill leaves only these reports, no crash report."""
    kills = []
    for path in sorted(folder.rglob('JetsamEvent-*.ips')):
        lines = path.read_text(errors='replace').split('\n', 1)
        if len(lines) < 2:
            continue
        try:
            report = json.loads(lines[1])
        except json.JSONDecodeError:
            continue
        page = report.get('memoryStatus', {}).get('pageSize', 16384)
        for entry in report.get('processes', []):
            if entry.get('name') == process and entry.get('reason'):
                kills.append({'time': report.get('date', path.stem), 'reason': entry['reason'], 'mb': entry.get('rpages', 0) * page >> 20})
    return sorted(kills, key=lambda kill: kill['time'])


def summarise_log(text: str) -> list:
    """Plain lines about one run's log.txt."""
    out = []
    renderer = re.search(r'GL_RENDERER: (.*)', text)
    version = re.search(r'GL_VERSION: (.*)', text)
    if version:
        out.append(f'OpenGL: {version[1].strip()} on {renderer[1].strip() if renderer else "?"}')
    else:
        out.append('The game did not get as far as creating its OpenGL context.')
    frames = re.findall(r'frames: ([\d.]+) fps over \d+ s, slowest (\d+) ms, (\d+) slow, in a world', text)
    if frames:
        rates = [float(f[0]) for f in frames]
        out.append(f'In a world: {min(rates):.0f} to {max(rates):.0f} fps over {len(frames) * 10} s, the slowest frame {max(int(f[1]) for f in frames)} ms')
    heat = re.findall(r'power: thermal state (\w+)', text)
    if heat:
        out.append(f'Thermal state: {heat[-1]} at the end' + (', reached serious' if 'serious' in heat or 'critical' in heat else ''))
    reds = [line for line in text.splitlines() if line.startswith('[RED]')]
    if reds:
        out.append(f'{len(reds)} [RED] lines, the last: {reds[-1]}')
    return out


def cmd_log(args) -> None:
    bundle = bundle_id(args)
    with tempfile.TemporaryDirectory() as folder:
        folder = Path(folder)
        copied = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                      '--source', f'{CACHES}/log.txt', '--destination', folder / 'log.txt'])
        if copied.returncode or not (folder / 'log.txt').is_file():
            raise Failure('The game has not left a log on the Apple TV yet. Play it once, then look again.', 'no-log')
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'systemCrashLogs', '--source', '.', '--destination', folder / 'reports'])
        log = (folder / 'log.txt').read_text(errors='replace')
        kept = BUILD / 'last-log.txt'
        kept.parent.mkdir(parents=True, exist_ok=True)
        kept.write_text(log)
        for line in summarise_log(log):
            note(line)
        for kill in read_jetsam(folder / 'reports')[-3:]:
            note(f'tvOS ended the game for memory ({kill["mb"]:,} MB, {kill["reason"]}) at {kill["time"][:19]}')
        note(f'Full log: {kept}')


# ---------- saves ----------

def save_listing(device: str, bundle: str) -> Optional[dict]:
    """The world files on the TV, as {path under Library/Caches: [size, last change]}: empty for a game that is not installed, None for a TV that did not answer."""
    try:
        data = devicectl_json('device', 'info', 'files', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle, '--subdirectory', CACHES, timeout=TV_TIMEOUT_S)
    except (Failure, json.JSONDecodeError):
        return None
    if 'error' in data:
        return {} if data['error'].get('domain') == 'CoreDevice.ActionError' else None
    return {f['relativePath']: [f.get('metadata', {}).get('size'), f.get('metadata', {}).get('lastModDate')] for f in data.get('result', {}).get('files', [])
            if SAVE_FILE.match(f.get('relativePath', '')) and not f.get('resources', {}).get('isDirectory')}


def newest_backup(place: Optional[Path] = None) -> Optional[Path]:
    place = place or BACKUPS
    found = sorted(p for p in place.glob('*') if (p / 'tvcraft-manifest.json').is_file()) if place.is_dir() else []
    return found[-1] if found else None


def read_manifest(backup: Path) -> Optional[dict]:
    try:
        return json.loads((backup / 'tvcraft-manifest.json').read_text())
    except (OSError, json.JSONDecodeError):
        return None


def kept_backups(names: Iterable[str], today: date, newest: int = 20, days: int = 30) -> set:
    """The newest 20 backups, and the newest of each of the last 30 days. Backups are named YYYYMMDD-HHMMSS; any other name is kept, never pruned."""
    names = list(names)
    stamped = sorted((n for n in names if re.fullmatch(r'\d{8}-\d{6}', n)), reverse=True)
    keep, seen_days = set(stamped[:newest]) | (set(names) - set(stamped)), set()
    for name in stamped:
        try:
            day = datetime.strptime(name[:8], '%Y%m%d').date()
        except ValueError:
            continue
        if today - day < timedelta(days=days) and day not in seen_days:
            seen_days.add(day)
            keep.add(name)
    return keep


def prune_backups(place: Optional[Path] = None) -> None:
    place = place or BACKUPS
    names = [p.name for p in place.glob('*') if (p / 'tvcraft-manifest.json').is_file()]
    for name in set(names) - kept_backups(names, date.today()):
        shutil.rmtree(place / name)


def backup_worlds(device: str, bundle: str) -> None:
    listing = save_listing(device, bundle)
    if listing is None:
        raise Failure('The Apple TV did not answer.', 'device-unreachable', 'Wake it with the remote, then try again.')
    if not listing:
        note('No worlds on the Apple TV yet.')
        return
    last = newest_backup()
    if last and read_manifest(last) == listing:
        note(f'Nothing changed since the backup {last.name}.')
        return
    BACKUPS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    with tempfile.TemporaryDirectory(dir=BACKUPS) as folder:
        folder = Path(folder)
        for path in listing:
            (folder / path).parent.mkdir(parents=True, exist_ok=True)
            copied = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                          '--source', f'{CACHES}/{path}', '--destination', folder / path])
            if copied.returncode:
                raise Failure(f'Copying {path} failed: {copied.stderr.strip()[-300:]}', 'backup-failed')
        if save_listing(device, bundle) != listing:   # the game saved while we copied: a mix of old and new files is no backup
            raise Failure('The game saved during the copy. Try again in a moment.', 'backup-changed')
        (folder / 'tvcraft-manifest.json').write_text(json.dumps(listing, indent=1, sort_keys=True))
        folder.rename(BACKUPS / stamp)
    prune_backups()
    note(f'Backed up {len(listing)} files to {BACKUPS / stamp}')


def cmd_backup(args) -> None:
    backup_worlds(args.device, bundle_id(args))


def cmd_restore(args) -> None:
    bundle = bundle_id(args)
    listing = save_listing(args.device, bundle)
    if listing is None:
        raise Failure('The Apple TV did not answer.', 'device-unreachable')
    if listing and not args.force:
        raise Failure('The Apple TV still has worlds; restore never replaces them (use --force to overwrite).', 'worlds-present')
    backup = newest_backup()
    if not backup:
        raise Failure('There is no backup yet.', 'no-backup')
    files = [p for p in backup.rglob('*') if p.is_file() and p.name != 'tvcraft-manifest.json']
    for path in files:
        relative = path.relative_to(backup)
        result = run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                      '--source', path, '--destination', f'{CACHES}/{relative}'])
        if result.returncode:
            raise Failure(f'Copying {relative} failed: {result.stderr.strip()[-300:]}', 'restore-failed')
    note(f'Restored {len(files)} files from {backup.name}')


def cmd_renew(args) -> None:
    info = provisioning(app_path(False))
    if info and info['days_left'] > 2 and not args.force:
        note(f'No need yet: the install opens until {info["expires"][:10]}.')
        return
    cmd_build(args)
    cmd_install(args)


def cmd_clean(_) -> None:
    """Only what prepare and build make: the work dir may hold other things, and backups are always kept."""
    for name in ('assets', 'Assets.xcassets'):
        shutil.rmtree(STAGING / name, ignore_errors=True)
    for name in ('pcm_data.c', 'prepared.json'):
        (STAGING / name).unlink(missing_ok=True)
    shutil.rmtree(BUILD, ignore_errors=True)
    note(f'Removed the staged game files and the build (backups in {BACKUPS} are kept).')


# ---------- main ----------

def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--json', action='store_true', help='one JSON event per stdout line; tool output goes to stderr')
    common.add_argument('--work-dir', help='put the staged game files, the build and the backups here instead of in tvos/')
    common.add_argument('--apk', '--disc', dest='apk', help='your own Minecraft PE 0.8.1 APK (default: the one in apksource/)')
    common.add_argument('--team', help='the signing team ID (default: TVCRAFT_TEAM, else the one Xcode uses)')
    common.add_argument('--bundle-id', help=f'the app\'s bundle ID (default: {BASE_BUNDLE_ID}.<team>)')
    common.add_argument('--xcodegen', help='the XcodeGen binary (default: xcodegen on PATH)')
    common.add_argument('--icon', help='an image for the app icon and Top Shelf (default: the icon in the APK)')
    env_kv = dict(action='append', type=lambda kv: tuple(kv.split('=', 1)), metavar='KEY=VALUE', help='launch environment, e.g. TVCRAFT_INPUT_LOG=1')

    top = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = top.add_subparsers(dest='command', required=True)
    for name, func in (('check', cmd_check), ('prepare', cmd_prepare), ('extract', cmd_extract), ('clean', cmd_clean), ('devices', cmd_devices)):
        p = sub.add_parser(name, parents=[common])
        p.set_defaults(func=func)
        if name == 'prepare':
            p.add_argument('--force', action='store_true', help='read the APK again even if it is already prepared')
    p = sub.add_parser('build', parents=[common])
    g = p.add_mutually_exclusive_group()
    g.add_argument('--sim', action='store_true')
    g.add_argument('--device', help='UDID or devicectl identifier, or "generic"')
    p.add_argument('--platform', choices=('tvos',), default='tvos')
    p.set_defaults(func=cmd_build)
    p = sub.add_parser('sim', parents=[common])
    p.add_argument('--udid')
    p.add_argument('--env', **env_kv)
    p.set_defaults(func=cmd_sim)
    for name, func in (('install', cmd_install), ('installed', cmd_installed), ('launch', cmd_launch), ('log', cmd_log), ('backup', cmd_backup)):
        p = sub.add_parser(name, parents=[common])
        p.add_argument('--device', required=True)
        p.add_argument('--platform', choices=('tvos',), default='tvos')
        p.set_defaults(func=func)
        if name == 'launch':
            p.add_argument('--env', **env_kv)
    for name, func in (('restore', cmd_restore), ('renew', cmd_renew)):
        p = sub.add_parser(name, parents=[common])
        p.add_argument('--device', required=True)
        p.add_argument('--force', action='store_true')
        p.set_defaults(func=func)
    return top


def main(argv: Optional[List[str]] = None) -> int:
    global JSON
    args = parser().parse_args(argv)
    JSON = args.json
    try:
        configure(args.work_dir, args.xcodegen)
        if args.command == 'prepare':
            return cmd_prepare(args, force=args.force) or 0
        return args.func(args) or 0
    except Failure as failure:
        emit('error', code=failure.code, message=failure.message, fix=failure.fix)
        return 1
    except KeyboardInterrupt:
        emit('error', code='cancelled', message='Cancelled.', fix='')
        return 130


if __name__ == '__main__':
    sys.exit(main())
