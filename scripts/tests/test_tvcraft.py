"""Tests for scripts/tvcraft.py's pure functions. They need no Apple TV, no APK and no Xcode: python3 -I scripts/tests/test_tvcraft.py"""
import io
import json
import os
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import tvcraft  # noqa: E402


class Teams(unittest.TestCase):
    def test_personal_team_first(self):
        prefs = {'IDEProvisioningTeamByIdentifier': {'a': [{'teamID': 'PAID1', 'isFreeProvisioningTeam': False}, {'teamID': 'FREE1', 'isFreeProvisioningTeam': True}], 'b': [{'name': 'no id'}]}}
        self.assertEqual(tvcraft.xcode_teams(prefs), ['FREE1', 'PAID1'])

    def test_no_accounts(self):
        self.assertEqual(tvcraft.xcode_teams({}), [])


class Devices(unittest.TestCase):
    def test_only_physical_apple_tvs(self):
        listing = {'result': {'devices': [
            {'hardwareProperties': {'deviceType': 'appleTV', 'reality': 'physical', 'udid': 'TV1', 'marketingName': 'Apple TV 4K (3rd generation)'},
             'deviceProperties': {'name': 'Living Room', 'osVersionNumber': '27.2', 'developerModeStatus': 'enabled'}, 'connectionProperties': {'tunnelState': 'connected'}},
            {'hardwareProperties': {'deviceType': 'iPhone', 'reality': 'physical', 'udid': 'P1'}},
            {'hardwareProperties': {'deviceType': 'appleTV', 'reality': 'virtual', 'udid': 'SIM'}},
        ]}}
        tvs = tvcraft.apple_tvs(listing)
        self.assertEqual([tv['id'] for tv in tvs], ['TV1'])
        self.assertTrue(tvs[0]['connected'] and tvs[0]['developer_mode'])

    def test_running_pids(self):
        listing = {'result': {'runningProcesses': [{'processIdentifier': 12, 'executable': 'file:///private/var/containers/Bundle/Application/X/TVCraft.app/TVCraft'},
                                                   {'processIdentifier': 13, 'executable': 'file:///usr/libexec/other'}]}}
        self.assertEqual(tvcraft.running_pids(listing), ['12'])


class Saves(unittest.TestCase):
    def test_save_files(self):
        match = tvcraft.SAVE_FILE.match
        self.assertTrue(match('games/com.mojang/minecraftWorlds/My World/chunks.dat'))
        self.assertTrue(match('games/com.mojang/minecraftWorlds/w/level.dat'))
        self.assertTrue(match('games/com.mojang/minecraftpe/options.txt'))
        self.assertFalse(match('games/com.mojang/minecraftWorlds/w/level.dat_old'))
        self.assertFalse(match('log.txt'))

    def test_kept_backups(self):
        today = date(2026, 11, 6)
        names = [f'202611{d:02d}-12000{i}' for d in range(1, 7) for i in range(5)] + ['20260901-120000', 'not-a-backup']
        kept = tvcraft.kept_backups(names, today, newest=3)
        self.assertEqual(len([n for n in kept if n.startswith('20261106')]), 3)      # the newest three
        for day in range(1, 6):                                                        # and the newest of each other recent day
            self.assertIn(f'202611{day:02d}-120004', kept)
        self.assertNotIn('20260901-120000', kept)                                      # older than 30 days
        self.assertIn('not-a-backup', kept)                                            # a name it does not know is never pruned

    def test_newest_backup_and_manifest(self):
        with tempfile.TemporaryDirectory() as folder:
            place = Path(folder)
            self.assertIsNone(tvcraft.newest_backup(place))
            for name, listing in (('20261105-100000', {'a': [1, 'x']}), ('20261106-100000', {'a': [2, 'y']})):
                (place / name).mkdir()
                (place / name / 'tvcraft-manifest.json').write_text(json.dumps(listing))
            (place / '20261107-000000').mkdir()                                       # an unfinished copy has no manifest
            newest = tvcraft.newest_backup(place)
            self.assertEqual(newest.name, '20261106-100000')
            self.assertEqual(tvcraft.read_manifest(newest), {'a': [2, 'y']})


class Logs(unittest.TestCase):
    def test_summary(self):
        log = 'boot: TVCraft\ngl: GL_VERSION: OpenGL ES-CM 1.1 APPLE\ngl: GL_RENDERER: Apple A15 GPU\n[RED] failed to load assets/images/x.png\n'
        lines = tvcraft.summarise_log(log)
        self.assertIn('OpenGL: OpenGL ES-CM 1.1 APPLE on Apple A15 GPU', lines)
        self.assertTrue(any('1 [RED] lines' in line for line in lines))

    def test_frames_and_heat(self):
        log = ('gl: GL_VERSION: x\npower: thermal state nominal\nframes: 59.8 fps over 10 s, slowest 40 ms, 2 slow, in a world\n'
               'frames: 57.1 fps over 10 s, slowest 90 ms, 9 slow, in a world\nframes: 60.0 fps over 10 s, slowest 17 ms, 0 slow, in menus\npower: thermal state fair (300 s after launch)\n')
        lines = tvcraft.summarise_log(log)
        self.assertIn('In a world: 57 to 60 fps over 20 s, the slowest frame 90 ms', lines)
        self.assertIn('Thermal state: fair at the end', lines)

    def test_no_gl(self):
        self.assertIn('did not get as far', tvcraft.summarise_log('boot: TVCraft\n')[0])

    def test_jetsam(self):
        with tempfile.TemporaryDirectory() as folder:
            report = {'date': '2026-11-06 10:00:00', 'memoryStatus': {'pageSize': 16384}, 'processes': [{'name': 'TVCraft', 'reason': 'per-process-limit', 'rpages': 6400}, {'name': 'other'}]}
            (Path(folder) / 'JetsamEvent-2026-11-06.ips').write_text('{"header": 1}\n' + json.dumps(report))
            kills = tvcraft.read_jetsam(Path(folder))
            self.assertEqual(kills, [{'time': '2026-11-06 10:00:00', 'reason': 'per-process-limit', 'mb': 100}])


class Engine(unittest.TestCase):
    """The parts TVCraft Installer depends on: events, versions, bundle IDs, the work dir and the prepare stamp."""

    def setUp(self):
        self.saved = (tvcraft.STAGING, tvcraft.BUILD, tvcraft.BACKUPS, tvcraft.JSON, os.environ.get('PATH'), os.environ.get('SDKROOT'))

    def tearDown(self):
        tvcraft.STAGING, tvcraft.BUILD, tvcraft.BACKUPS, tvcraft.JSON, path, sdkroot = self.saved
        os.environ['PATH'] = path
        if sdkroot is None:
            os.environ.pop('SDKROOT', None)
        else:
            os.environ['SDKROOT'] = sdkroot

    def events(self, func, *args, **kwargs) -> list:
        tvcraft.JSON = True
        out = io.StringIO()
        with redirect_stdout(out):
            func(*args, **kwargs)
        return [json.loads(line) for line in out.getvalue().splitlines()]

    def test_events_are_json_lines(self):
        events = self.events(tvcraft.emit, 'check', id='xcode', label='Xcode', ok=False, detail='none', fix='Install it')
        self.assertEqual(events, [{'event': 'check', 'id': 'xcode', 'label': 'Xcode', 'ok': False, 'detail': 'none', 'fix': 'Install it'}])

    def test_failure_becomes_error_event(self):
        tvcraft.JSON = True
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, redirect_stdout(out):
            status = tvcraft.main(['prepare', '--json', '--work-dir', folder, '--apk', str(Path(folder) / 'missing.apk')])
        self.assertEqual(status, 1)
        event = json.loads(out.getvalue().splitlines()[-1])
        self.assertEqual((event['event'], event['code']), ('error', 'apk-missing'))
        self.assertTrue(event['fix'])

    def test_versions(self):
        self.assertEqual(tvcraft.numeric_version('v1.2.3-rc1'), (1, 2, 3))
        self.assertEqual(tvcraft.numeric_version('1.0'), (1, 0, 0))
        self.assertEqual(tvcraft.build_number('1.2.3'), 10203)
        self.assertEqual(tvcraft.build_number('v10.0.0-rc2'), 100000)

    def test_port_json(self):
        info = tvcraft.port_info()
        self.assertEqual(info['entry'], 'scripts/tvcraft.py')
        self.assertEqual(info['submodules'], ['MCPE-0.8.1-fortv'])   # never MCPE-1.1.5-decomp
        self.assertGreaterEqual(tvcraft.numeric_version(info['version']), tvcraft.numeric_version(info['minAppVersion']))
        self.assertEqual(info['inputs'][0]['accept'][0]['libSha1'], tvcraft.LIB_SHA1)

    def test_bundle_id_per_team(self):
        self.assertEqual(tvcraft.team_bundle_id('ABCDE12345'), 'io.github.chocoguy.tvcraft.ABCDE12345')
        self.assertEqual(tvcraft.team_bundle_id(''), 'io.github.chocoguy.tvcraft')

    def test_free_teams(self):
        prefs = {'IDEProvisioningTeamByIdentifier': {'a': [{'teamID': 'PAID1'}, {'teamID': 'FREE1', 'isFreeProvisioningTeam': True}]}}
        self.assertEqual(tvcraft.free_teams(prefs), {'FREE1'})

    def test_work_dir_and_path(self):
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder) / 'Application Support' / 'work'
            os.environ['PATH'] = '/usr/bin:/bin'
            os.environ['SDKROOT'] = '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
            tvcraft.configure(str(work), '/opt/tools/xcodegen/bin/xcodegen')
            self.assertEqual(tvcraft.STAGING, work.resolve() / 'staging')
            self.assertEqual(tvcraft.BUILD, work.resolve() / 'build')
            self.assertEqual(tvcraft.BACKUPS, work.resolve() / 'save-backups')
            path = os.environ['PATH'].split(':')
            self.assertEqual(path[:3], ['/opt/tools/xcodegen/bin', '/opt/homebrew/bin', '/usr/local/bin'])
            self.assertEqual(path[-2:], ['/usr/bin', '/bin'])
            self.assertNotIn('SDKROOT', os.environ)   # /usr/bin/python3's macOS SDK must not reach the tvOS build

    def test_prepare_stamp(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder) / 'game.apk'
            apk.write_bytes(b'one')
            first = tvcraft.prepare_stamp(apk)
            self.assertEqual(first, tvcraft.prepare_stamp(apk))
            apk.write_bytes(b'longer')
            self.assertNotEqual(first, tvcraft.prepare_stamp(apk))

    def test_wrong_apk(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = Path(folder) / 'other.apk'
            with zipfile.ZipFile(apk, 'w') as z:
                z.writestr(tvcraft.LIB_IN_APK, b'not the game')
            with self.assertRaises(tvcraft.Failure) as caught:
                tvcraft.read_game_library(apk)
            self.assertEqual(caught.exception.code, 'apk-wrong')
            (Path(folder) / 'text.apk').write_text('hello')
            with self.assertRaises(tvcraft.Failure) as caught:
                tvcraft.read_game_library(Path(folder) / 'text.apk')
            self.assertEqual(caught.exception.code, 'apk-unreadable')

    def test_explain_build_failures(self):
        failure = tvcraft.explain(['** BUILD FAILED **', "error: No Account for Team 'X'."], 'b')
        self.assertEqual(failure.code, 'xcode-account')
        failure = tvcraft.explain(['foo.cpp:1: error: expected ;'], 'b')
        self.assertEqual((failure.code, failure.message), ('build-failed', 'foo.cpp:1: error: expected ;'))

    def test_options_after_command(self):
        args = tvcraft.parser().parse_args(['build', '--platform', 'tvos', '--disc', 'x.apk', '--device', 'D1', '--work-dir', 'w', '--json'])
        self.assertEqual((args.apk, args.device, args.work_dir, args.json, args.platform), ('x.apk', 'D1', 'w', True, 'tvos'))


if __name__ == '__main__':
    unittest.main()
