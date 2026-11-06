"""Tests for scripts/tvcraft.py's pure functions. They need no Apple TV, no APK and no Xcode: python3 -I scripts/tests/test_tvcraft.py"""
import json
import sys
import tempfile
import unittest
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

    def test_no_gl(self):
        self.assertIn('did not get as far', tvcraft.summarise_log('boot: TVCraft\n')[0])

    def test_jetsam(self):
        with tempfile.TemporaryDirectory() as folder:
            report = {'date': '2026-11-06 10:00:00', 'memoryStatus': {'pageSize': 16384}, 'processes': [{'name': 'TVCraft', 'reason': 'per-process-limit', 'rpages': 6400}, {'name': 'other'}]}
            (Path(folder) / 'JetsamEvent-2026-11-06.ips').write_text('{"header": 1}\n' + json.dumps(report))
            kills = tvcraft.read_jetsam(Path(folder))
            self.assertEqual(kills, [{'time': '2026-11-06 10:00:00', 'reason': 'per-process-limit', 'mb': 100}])


if __name__ == '__main__':
    unittest.main()
