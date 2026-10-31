"""Regression checks for startup access lists; no network or live data used."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ENTRYPOINT = Path(os.environ.get(
    'ATM10_ENTRYPOINT', Path(__file__).resolve().parents[1] / 'entrypoint.sh'
))
PLAYER = {'name': 'PlayerOne', 'uuid': '11111111-2222-3333-4444-555555555555'}
GUEST = {'name': 'Guest', 'uuid': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}
OPERATOR = dict(PLAYER, level=4, bypassesPlayerLimit=False)


class AccessListsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.write('ops.json', [])
        self.write('whitelist.json', [GUEST])
        self.write('usercache.json', [])
        fake_bin = self.root / 'bin'
        fake_bin.mkdir()
        fake_curl = fake_bin / 'curl'
        fake_curl.write_text('''#!/bin/bash
if [[ "$*" == *api.minecraftservices.com* ]] && [ "${MOCK_PRIMARY_FAIL:-}" = 1 ]; then
    exit 22
fi
[ -n "${MOCK_PROFILE:-}" ] || exit 22
printf '%s\\n' "$MOCK_PROFILE"
''')
        fake_curl.chmod(0o755)
        self.env = dict(os.environ, OPS='PlayerOne', MOCK_PROFILE='',
                        MOCK_PRIMARY_FAIL='', PATH=str(fake_bin) + ':' + os.environ['PATH'])

    def write(self, name, data):
        (self.root / name).write_text(json.dumps(data))

    def read(self, name):
        return json.loads((self.root / name).read_text())

    def run_startup(self):
        source = ENTRYPOINT.read_text()
        start = source.index('if [ -n "${OPS:-}" ]; then')
        end = source.index('exec /bin/bash startserver.sh', start)
        section = source[start:end].replace('/data/', str(self.root) + '/')
        return subprocess.run(['bash', '-c', 'set -e\n' + section],
                              env=self.env, text=True, capture_output=True)

    def test_cached_uuid_restores_access_without_network(self):
        self.write('usercache.json', [PLAYER])
        result = self.run_startup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read('ops.json'), [OPERATOR])
        self.assertCountEqual(self.read('whitelist.json'), [GUEST, PLAYER])
        self.assertIn('Using saved UUID', result.stdout)

    def test_failed_lookup_preserves_existing_operators_and_guests(self):
        self.write('ops.json', [OPERATOR])
        self.write('whitelist.json', [GUEST, PLAYER])
        self.env['OPS'] = 'PlayerOne,MissingPlayer'
        result = self.run_startup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read('ops.json'), [OPERATOR])
        self.assertCountEqual(self.read('whitelist.json'), [GUEST, PLAYER])
        self.assertIn('preserving existing access', result.stdout)

    def test_fallback_profile_lookup_adds_new_operator(self):
        self.env['MOCK_PRIMARY_FAIL'] = '1'
        self.env['MOCK_PROFILE'] = json.dumps({
            'name': PLAYER['name'], 'id': PLAYER['uuid'].replace('-', '')
        })
        result = self.run_startup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read('ops.json'), [OPERATOR])
        self.assertCountEqual(self.read('whitelist.json'), [GUEST, PLAYER])

    def test_invalid_profile_cannot_add_an_invalid_uuid(self):
        for profile in [{'name': 'PlayerOne', 'id': None},
                        {'name': 'SomeoneElse', 'id': PLAYER['uuid'].replace('-', '')}]:
            with self.subTest(profile=profile):
                self.env['MOCK_PROFILE'] = json.dumps(profile)
                result = self.run_startup()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.read('ops.json'), [])
                self.assertEqual(self.read('whitelist.json'), [GUEST])

    def test_repeated_startup_keeps_guests_and_avoids_duplicates(self):
        self.write('usercache.json', [PLAYER])
        for _ in range(2):
            result = self.run_startup()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read('ops.json'), [OPERATOR])
        self.assertCountEqual(self.read('whitelist.json'), [GUEST, PLAYER])

    def test_malformed_access_list_stops_without_overwriting_files(self):
        self.write('ops.json', [OPERATOR])
        self.write('whitelist.json', {'unexpected': 'object'})
        result = self.run_startup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read('ops.json'), [OPERATOR])
        self.assertEqual(self.read('whitelist.json'), {'unexpected': 'object'})


if __name__ == '__main__':
    unittest.main()
