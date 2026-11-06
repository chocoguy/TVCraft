#!/usr/bin/env python3
"""TVCraft: build Minecraft PE 0.8.1 (the MCPE-0.8.1-fortv decompilation) into an Apple TV app and manage it on the TV.

Commands (each exits non-zero on error):
  extract                 stage the game's assets and sounds from your own 0.8.1 APK into tvos/staging (never committed)
  build [--sim | --device UDID]   generate the Xcode project and build the app (simulator, or signed for a device)
  sim [--udid UDID]       install and launch the simulator build on a booted Apple TV simulator
  devices                 list Apple TVs paired with this Mac
  install --device UDID   install the device build
  launch --device UDID    launch it (ending a running copy first)
  log --device UDID       copy the last run's log and memory-kill reports off the TV and summarise them
  backup --device UDID    copy the worlds off the TV into tvos/save-backups
  restore --device UDID   put the newest backup back on a TV that has lost its worlds
  renew --device UDID     rebuild and reinstall when a free Apple ID's install is about to stop opening

Several device functions follow TVPort's tvport/backend.py (MIT): team discovery, devicectl, launching, Jetsam reports and save backups.
"""
import argparse
import hashlib
import json
import os
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
from typing import Iterable, Optional

ROOT = Path(__file__).resolve().parent.parent
FORK = ROOT / 'MCPE-0.8.1-fortv'
TVOS = ROOT / 'tvos'
STAGING = TVOS / 'staging'
BUILD = TVOS / 'build'
BACKUPS = TVOS / 'save-backups'
APK_DIR = ROOT / 'apksource'

LIB_IN_APK = 'lib/armeabi-v7a/libminecraftpe.so'
LIB_SHA1 = 'c30bd6e3b72be7b97a222d79d1405b55f6d3bf71'   # the build tools/get_sound_data.py's offsets were taken from
BUNDLE_ID = os.environ.get('TVCRAFT_BUNDLE_ID', 'io.github.chocoguy.tvcraft')
SCHEME = 'TVCraft'
CACHES = 'Library/Caches'
WORLDS = 'games/com.mojang/minecraftWorlds'
SAVE_FILE = re.compile(r'^games/com\.mojang/(minecraftWorlds/[^/]+/(level\.dat|chunks\.dat|entities\.dat|player\.dat)|minecraftpe/options\.txt)$')
TV_TIMEOUT_S = 30
LAUNCH_SETTLE_S = 3


class Failure(Exception):
    pass


def run(argv: Iterable, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run([str(a) for a in argv], capture_output=True, text=True, **kwargs)


def stream(argv: Iterable, **kwargs) -> None:
    """Run a long command, showing its output as it goes."""
    argv = [str(a) for a in argv]
    if subprocess.run(argv, **kwargs).returncode:
        raise Failure(f'{Path(argv[0]).name} failed')


# ---------- extract ----------

def find_apk(given: Optional[str]) -> Path:
    if given:
        apk = Path(given).expanduser()
        if not apk.is_file():
            raise Failure(f'No APK at {apk}')
        return apk
    found = sorted(APK_DIR.glob('*0.8.1*.apk'))
    if not found:
        raise Failure(f'Put your Minecraft PE 0.8.1 APK in {APK_DIR} (or pass --apk)')
    return found[0]


def sha1(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def cmd_extract(args) -> None:
    apk = find_apk(args.apk)
    print(f'APK: {apk.name}')
    with zipfile.ZipFile(apk) as z:
        lib = z.read(LIB_IN_APK)
        if sha1(lib) != LIB_SHA1:
            raise Failure(f'{LIB_IN_APK} in this APK is not the 0.8.1 build the decompilation matches (SHA-1 {sha1(lib)}, want {LIB_SHA1})')
        assets = [n for n in z.namelist() if n.startswith('assets/') and not n.endswith('/')]
        out = STAGING / 'assets'
        if out.exists():
            shutil.rmtree(out)
        for name in assets:
            target = (STAGING / name).resolve()
            if STAGING.resolve() not in target.parents:   # a name with ../ in it
                raise Failure(f'Unsafe path in the APK: {name}')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(z.read(name))
    print(f'Assets: {len(assets)} files in {out.relative_to(ROOT)}')
    with tempfile.TemporaryDirectory() as folder:
        so = Path(folder) / 'libminecraftpe.so'
        so.write_bytes(lib)
        tool = FORK / 'tools/get_sound_data.py'
        result = run([sys.executable, '-I', tool, so], cwd=folder)
        if result.returncode or not (Path(folder) / 'pcm_data.c').is_file():
            raise Failure(f'get_sound_data.py failed: {result.stderr.strip()[-500:]}')
        STAGING.mkdir(parents=True, exist_ok=True)
        shutil.move(str(Path(folder) / 'pcm_data.c'), STAGING / 'pcm_data.c')
    print(f'Sounds: {(STAGING / "pcm_data.c").stat().st_size / 2**20:.1f} MB of C in {(STAGING / "pcm_data.c").relative_to(ROOT)}')


# ---------- build ----------

def xcode_teams(prefs: dict) -> list:
    """The teams of the Apple IDs signed in to Xcode, personal (free) teams first."""
    teams = [team for account in prefs.get('IDEProvisioningTeamByIdentifier', {}).values() for team in account if team.get('teamID')]
    return [team['teamID'] for team in sorted(teams, key=lambda team: not team.get('isFreeProvisioningTeam'))]


def known_team() -> str:
    """A team to sign with: TVCRAFT_TEAM, else the newest provisioning profile's, else the first Apple ID signed in to Xcode."""
    if os.environ.get('TVCRAFT_TEAM'):
        return os.environ['TVCRAFT_TEAM']
    folders = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles', Path.home() / 'Library/MobileDevice/Provisioning Profiles']
    for folder in folders:
        for profile in sorted(folder.glob('*.mobileprovision'), key=lambda p: p.stat().st_mtime, reverse=True) if folder.is_dir() else []:
            decoded = run(['security', 'cms', '-D', '-i', profile])
            if decoded.returncode == 0:
                return plistlib.loads(decoded.stdout.encode())['TeamIdentifier'][0]
    exported = run(['defaults', 'export', 'com.apple.dt.Xcode', '-'])
    try:
        teams = xcode_teams(plistlib.loads(exported.stdout.encode())) if exported.returncode == 0 else []
    except plistlib.InvalidFileException:
        teams = []
    return teams[0] if teams else ''


def check_staged() -> None:
    if not (STAGING / 'pcm_data.c').is_file() or not (STAGING / 'assets').is_dir():
        raise Failure('Run "tvcraft.py extract" first: the game files are not staged')
    if not (FORK / 'RakNet/Source').is_dir():
        raise Failure('The fork\'s submodules are missing: run "git submodule update --init --recursive"')


def generate_project(team: str) -> Path:
    if not shutil.which('xcodegen'):
        raise Failure('XcodeGen is missing: brew install xcodegen')
    env = dict(os.environ, TVCRAFT_TEAM=team, TVCRAFT_BUNDLE_ID=BUNDLE_ID)
    result = run(['xcodegen', 'generate', '--spec', TVOS / 'project.yml', '--project', TVOS], env=env)
    if result.returncode:
        raise Failure(result.stderr.strip() or result.stdout.strip())
    return TVOS / f'{SCHEME}.xcodeproj'


def app_path(sim: bool) -> Path:
    return BUILD / 'Build/Products' / ('Release-appletvsimulator' if sim else 'Release-appletvos') / f'{SCHEME}.app'


def cmd_build(args) -> None:
    check_staged()
    sim = not args.device
    team = '' if sim else known_team()
    if not sim and not team:
        raise Failure('No signing team: sign in to Xcode with an Apple ID (Settings > Accounts), or set TVCRAFT_TEAM')
    project = generate_project(team)
    destination = 'generic/platform=tvOS Simulator' if sim else (f'platform=tvOS,id={args.device}' if args.device != 'generic' else 'generic/platform=tvOS')
    command = ['xcodebuild', '-project', project, '-scheme', SCHEME, '-configuration', 'Release', '-destination', destination, '-derivedDataPath', BUILD]
    command += ['CODE_SIGNING_ALLOWED=NO'] if sim else ['-allowProvisioningUpdates']
    command += ['-quiet', 'build']
    stream(command)
    print(f'Built {app_path(sim).relative_to(ROOT)}')


def booted_tv_sim(udid: Optional[str]) -> str:
    if udid:
        return udid
    listing = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'booted', '-j']).stdout or '{}')
    for runtime, devices in listing.get('devices', {}).items():
        if 'tvOS' in runtime:
            for device in devices:
                if device.get('state') == 'Booted':
                    return device['udid']
    raise Failure('No Apple TV simulator is booted: open Simulator and boot one (or pass --udid)')


def cmd_sim(args) -> None:
    udid = booted_tv_sim(args.udid)
    app = app_path(True)
    if not app.is_dir():
        raise Failure('Build for the simulator first: tvcraft.py build --sim')
    for step in (['install', udid, app], ['launch', '--terminate-running-process', udid, BUNDLE_ID]):
        result = run(['xcrun', 'simctl', *step])
        if result.returncode:
            raise Failure(result.stderr.strip())
    container = run(['xcrun', 'simctl', 'get_app_container', udid, BUNDLE_ID, 'data']).stdout.strip()
    print(f'Launched on {udid}. Log: {container}/{CACHES}/log.txt')


# ---------- device ----------

def devicectl_json(*args, timeout: Optional[float] = None) -> dict:
    with tempfile.TemporaryDirectory() as folder:
        out = Path(folder) / 'out.json'
        try:
            result = run(['xcrun', 'devicectl', *args, '--quiet', '--json-output', out], timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failure('The Apple TV did not answer.') from None
        if not out.is_file():
            raise Failure(result.stderr.strip() or 'devicectl gave no answer. Is Xcode installed?')
        return json.loads(out.read_text())


def apple_tvs(listing: dict) -> list:
    tvs = []
    for device in listing.get('result', {}).get('devices', []):
        hardware = device.get('hardwareProperties', {})
        if hardware.get('deviceType') != 'appleTV' or hardware.get('reality') != 'physical':
            continue
        properties, connection = device.get('deviceProperties', {}), device.get('connectionProperties', {})
        tvs.append({'id': hardware.get('udid'), 'name': properties.get('name'), 'model': hardware.get('marketingName'), 'os': properties.get('osVersionNumber'),
                    'connected': connection.get('tunnelState') == 'connected', 'developer_mode': properties.get('developerModeStatus') == 'enabled'})
    return tvs


def cmd_devices(_) -> None:
    tvs = apple_tvs(devicectl_json('list', 'devices', timeout=TV_TIMEOUT_S))
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
        raise Failure('Build for the device first: tvcraft.py build --device <UDID>')
    result = run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device, app])
    if result.returncode:
        raise Failure(result.stderr.strip()[-900:] or 'The install failed')
    info = provisioning(app)
    print(f'Installed. It opens until {info.get("expires", "?")[:10]}' + (' (free Apple ID: run "renew" before then)' if info.get('free_team') else ''))


def running_pids(listing: dict, executable: str = SCHEME) -> list:
    return [str(p['processIdentifier']) for p in listing.get('result', {}).get('runningProcesses', []) if p.get('executable', '').rstrip('/').endswith(f'/{executable}')]


def cmd_launch(args) -> None:
    # devicectl's --terminate-existing launches at once, and the Home screen coming back can land on top of the new launch, so the old copy goes first (TVPort backend.py cmd_launch)
    pids = running_pids(devicectl_json('device', 'info', 'processes', '--device', args.device, timeout=TV_TIMEOUT_S))
    for pid in pids:
        run(['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', args.device, '--pid', pid])
    if pids:
        time.sleep(LAUNCH_SETTLE_S)
    result = run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device, BUNDLE_ID])
    if result.returncode:
        message = result.stdout + result.stderr
        raise Failure('The Apple TV is asleep. Wake it with the remote, then try again.' if 'asleep' in message else message.strip()[-700:])
    print(f'Launched {BUNDLE_ID}')


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
    reds = [line for line in text.splitlines() if line.startswith('[RED]')]
    if reds:
        out.append(f'{len(reds)} [RED] lines, the last: {reds[-1]}')
    return out


def cmd_log(args) -> None:
    with tempfile.TemporaryDirectory() as folder:
        folder = Path(folder)
        copied = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE_ID,
                      '--source', f'{CACHES}/log.txt', '--destination', folder / 'log.txt'])
        if copied.returncode or not (folder / 'log.txt').is_file():
            raise Failure('The game has not left a log on the Apple TV yet. Play it once, then look again.')
        run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'systemCrashLogs', '--source', '.', '--destination', folder / 'reports'])
        log = (folder / 'log.txt').read_text(errors='replace')
        kept = BUILD / 'last-log.txt'
        kept.parent.mkdir(parents=True, exist_ok=True)
        kept.write_text(log)
        for line in summarise_log(log):
            print(line)
        for kill in read_jetsam(folder / 'reports')[-3:]:
            print(f'tvOS ended the game for memory ({kill["mb"]:,} MB, {kill["reason"]}) at {kill["time"][:19]}')
        print(f'Full log: {kept.relative_to(ROOT)}')


# ---------- saves ----------

def save_listing(device: str) -> Optional[dict]:
    """The world files on the TV, as {path under Library/Caches: [size, last change]}: empty for a game that is not installed, None for a TV that did not answer."""
    try:
        data = devicectl_json('device', 'info', 'files', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE_ID, '--subdirectory', CACHES, timeout=TV_TIMEOUT_S)
    except (Failure, json.JSONDecodeError):
        return None
    if 'error' in data:
        return {} if data['error'].get('domain') == 'CoreDevice.ActionError' else None
    return {f['relativePath']: [f.get('metadata', {}).get('size'), f.get('metadata', {}).get('lastModDate')] for f in data.get('result', {}).get('files', [])
            if SAVE_FILE.match(f.get('relativePath', '')) and not f.get('resources', {}).get('isDirectory')}


def newest_backup(place: Path = BACKUPS) -> Optional[Path]:
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


def prune_backups(place: Path = BACKUPS) -> None:
    names = [p.name for p in place.glob('*') if (p / 'tvcraft-manifest.json').is_file()]
    for name in set(names) - kept_backups(names, date.today()):
        shutil.rmtree(place / name)


def cmd_backup(args) -> None:
    listing = save_listing(args.device)
    if listing is None:
        raise Failure('The Apple TV did not answer.')
    if not listing:
        print('No worlds on the Apple TV yet.')
        return
    last = newest_backup()
    if last and read_manifest(last) == listing:
        print(f'Nothing changed since {last.name}.')
        return
    BACKUPS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    with tempfile.TemporaryDirectory(dir=BACKUPS) as folder:
        folder = Path(folder)
        for path in listing:
            (folder / path).parent.mkdir(parents=True, exist_ok=True)
            copied = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE_ID,
                          '--source', f'{CACHES}/{path}', '--destination', folder / path])
            if copied.returncode:
                raise Failure(f'Copying {path} failed: {copied.stderr.strip()[-300:]}')
        if save_listing(args.device) != listing:   # the game saved while we copied: a mix of old and new files is no backup
            raise Failure('The game saved during the copy. Try again in a moment.')
        (folder / 'tvcraft-manifest.json').write_text(json.dumps(listing, indent=1, sort_keys=True))
        folder.rename(BACKUPS / stamp)
    prune_backups()
    print(f'Backed up {len(listing)} files to {(BACKUPS / stamp).relative_to(ROOT)}')


def cmd_restore(args) -> None:
    listing = save_listing(args.device)
    if listing is None:
        raise Failure('The Apple TV did not answer.')
    if listing and not args.force:
        raise Failure('The Apple TV still has worlds; restore never replaces them (use --force to overwrite).')
    backup = newest_backup()
    if not backup:
        raise Failure('There is no backup yet.')
    files = [p for p in backup.rglob('*') if p.is_file() and p.name != 'tvcraft-manifest.json']
    for path in files:
        relative = path.relative_to(backup)
        result = run(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', args.device, '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE_ID,
                      '--source', path, '--destination', f'{CACHES}/{relative}'])
        if result.returncode:
            raise Failure(f'Copying {relative} failed: {result.stderr.strip()[-300:]}')
    print(f'Restored {len(files)} files from {backup.name}')


def cmd_renew(args) -> None:
    info = provisioning(app_path(False))
    if info and info['days_left'] > 2 and not args.force:
        print(f'No need yet: the install opens until {info["expires"][:10]}.')
        return
    cmd_build(argparse.Namespace(device=args.device))
    cmd_install(args)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('extract'); p.add_argument('--apk'); p.set_defaults(func=cmd_extract)
    p = sub.add_parser('build'); g = p.add_mutually_exclusive_group(); g.add_argument('--sim', action='store_true'); g.add_argument('--device', help='UDID, or "generic"'); p.set_defaults(func=cmd_build)
    p = sub.add_parser('sim'); p.add_argument('--udid'); p.set_defaults(func=cmd_sim)
    p = sub.add_parser('devices'); p.set_defaults(func=cmd_devices)
    for name, func in (('install', cmd_install), ('launch', cmd_launch), ('log', cmd_log), ('backup', cmd_backup)):
        p = sub.add_parser(name); p.add_argument('--device', required=True); p.set_defaults(func=func)
    p = sub.add_parser('restore'); p.add_argument('--device', required=True); p.add_argument('--force', action='store_true'); p.set_defaults(func=cmd_restore)
    p = sub.add_parser('renew'); p.add_argument('--device', required=True); p.add_argument('--force', action='store_true'); p.set_defaults(func=cmd_renew)
    args = parser.parse_args()
    try:
        args.func(args)
    except Failure as error:
        print(f'tvcraft: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
