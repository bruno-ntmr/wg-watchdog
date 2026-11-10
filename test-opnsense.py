"""Exercise the actual shell AWG helpers with a simulated native backend.

No network, root privileges, PHP or OPNsense installation required.
Run: python3 test-opnsense.py
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
UUID = '11111111-1111-4111-8111-111111111111'
MOCK = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['MOCK_STATE']); s=json.loads(p.read_text())
tool=Path(sys.argv[0]).name; args=sys.argv[1:]; rc=0
if tool=='php':
    if 'simplexml_load_file' in args[1]: rc=0 if s['general'] else 1
    else:
        desired=int(args[-1])
        if desired==0 and (not s['enabled'] or not s['general']): rc=3
        else:
            s['enabled']=desired; s['events'].append('enabled='+str(desired))
elif tool=='configctl':
    if args[:2]==['amneziawg','reconfigure']:
        event=('target' if len(args)==3 else 'apply')+str(s['enabled'])
        s['events'].append(event)
        if s.get('fail')==event:
            s['fail']=None; rc=1
        else: s['running']=s['enabled']
    else:
        s['events'].append('filter')
        if s.get('fail')=='filter': s['fail']=None; rc=1
elif tool=='ifconfig': rc=0 if s['running'] else 1
p.write_text(json.dumps(s)); sys.exit(rc)
'''


class ToggleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.model = self.root / 'model.json'
        self.model.write_text(json.dumps(dict(enabled=1, running=1, general=1, events=[])))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('php', 'configctl', 'ifconfig', 'sleep', 'logger'):
            script = self.bin / name
            script.write_text(MOCK)
            script.chmod(0o755)
        source = (ROOT / 'wg-watchdog.sh').read_text()
        # Load the real definitions without running discovery/the main loop.
        prefix = source.split('\nif [ "$DISCOVER" = 1 ]; then', 1)[0]
        self.library = self.root / 'library.sh'
        self.library.write_text(prefix)

    def tearDown(self):
        self.tmp.cleanup()

    def execute(self, command):
        env = dict(os.environ, MOCK_STATE=str(self.model), HELPER=str(self.library),
                   TEST_BIN=str(self.bin), TEST_STATE=str(self.state), TEST_UUID=UUID)
        return subprocess.run(['sh', '-c', '. "$HELPER"; PATH="$TEST_BIN:$PATH"; '
                               'STATE=$TEST_STATE; ' + command], env=env, capture_output=True, text=True)

    def read(self):
        return json.loads(self.model.read_text())

    def update(self, **values):
        state = self.read()
        state.update(values)
        self.model.write_text(json.dumps(state))

    def test_checkbox_and_both_apply_steps(self):
        result = self.execute('restart_opn_awg "$TEST_UUID" awg1')
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read()
        self.assertEqual(state['events'], ['enabled=0', 'target0', 'apply0',
                                          'enabled=1', 'target1', 'apply1', 'filter'])
        self.assertEqual((state['enabled'], state['running']), (1, 1))
        self.assertFalse((self.state / 'opnsense-awg.pending').exists())

    def test_failed_apply_can_restore_original_enabled_state(self):
        self.update(fail='apply0')
        result = self.execute('restart_opn_awg "$TEST_UUID" awg1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read()['enabled'], 0)
        self.assertTrue((self.state / 'opnsense-awg.pending').exists())
        # A separate process represents a later cron run after SIGKILL/reboot.
        result = self.execute('recover_opn_awg')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.read()['enabled'], self.read()['running']), (1, 1))
        self.assertFalse((self.state / 'opnsense-awg.pending').exists())

    def test_failed_restore_retains_record_for_retry(self):
        self.update(enabled=0, running=0, fail='target1')
        (self.state / 'opnsense-awg.pending').write_text(f'{UUID} awg1\n')
        self.assertNotEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertTrue((self.state / 'opnsense-awg.pending').exists())
        self.assertEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertFalse((self.state / 'opnsense-awg.pending').exists())

    def test_concurrent_admin_disable_is_preserved(self):
        self.update(enabled=0, running=0)
        self.assertNotEqual(self.execute('restart_opn_awg "$TEST_UUID" awg1').returncode, 0)
        self.assertEqual(self.read()['enabled'], 0)
        self.assertEqual(self.read()['events'], [])
        self.assertFalse((self.state / 'opnsense-awg.pending').exists())

    def test_global_disable_never_runs_reconfigure(self):
        self.update(general=0, enabled=0, running=0)
        (self.state / 'opnsense-awg.pending').write_text(f'{UUID} awg1\n')
        self.assertNotEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertNotIn('target1', self.read()['events'])
        self.assertTrue((self.state / 'opnsense-awg.pending').exists())


if __name__ == '__main__':
    unittest.main()
