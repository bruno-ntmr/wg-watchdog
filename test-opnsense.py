"""Test the direct OPNsense awg-tools backend with simulated native commands.

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
MOCK = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['MOCK_STATE']); s=json.loads(p.read_text())
tool=Path(sys.argv[0]).name; args=sys.argv[1:]; rc=0
if tool=='php':
    code=args[1]
    if 'serializeToConfig' in code or 'load_phalcon' in code:
        raise RuntimeError('AWG plugin execution/config mutation is forbidden')
    if '$matches[0][1]' in code:
        if not s.get('readable', True): rc=2
        elif not s.get('managed', True): rc=1
        elif not s['enabled'] or not s['general']: print('awg1')
        else: rc=1
    elif s['enabled'] and s['general'] and s.get('readable', True):
        print('awg1 opnsense-awg 11111111-1111-4111-8111-111111111111')
    else: rc=1
elif tool=='awg-quick':
    assert args[1]=='/usr/local/etc/amnezia/awg1.conf'
    action=args[0]; s['events'].append(action)
    if s.get('fail')==action:
        s['fail']=None; rc=1
    else:
        s['exists']=int(action=='up'); s['up']=s['exists']
elif tool=='configctl':
    assert args==['filter','reload'], 'AWG plugin must not be called'
    s['events'].append('filter')
    if s.get('fail')=='filter': s['fail']=None; rc=1
elif tool in ('ifconfig','ip'):
    if tool=='ifconfig' and len(args)>1:
        assert args==['awg1','group','amneziawg']
        s['events'].append('group'); rc=0 if s['exists'] else 1
    elif s['exists']:
        flags='POINTOPOINT,UP' if s['up'] else 'POINTOPOINT'
        print('awg1: flags=0<'+flags+'>')
    else: rc=1
p.write_text(json.dumps(s)); sys.exit(rc)
'''


class DirectRestartTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.model = self.root / 'model.json'
        self.model.write_text(json.dumps(dict(enabled=1, exists=1, up=1, general=1, events=[])))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('php', 'awg-quick', 'configctl', 'ifconfig', 'ip', 'sleep', 'logger'):
            script = self.bin / name
            script.write_text(MOCK)
            script.chmod(0o755)
        source = (ROOT / 'wg-watchdog.sh').read_text()
        self.library = self.root / 'library.sh'
        self.library.write_text(source.split('\nif [ "$DISCOVER" = 1 ]; then', 1)[0])

    def tearDown(self):
        self.tmp.cleanup()

    def execute(self, command):
        env = dict(os.environ, MOCK_STATE=str(self.model), HELPER=str(self.library),
                   TEST_BIN=str(self.bin), TEST_STATE=str(self.state))
        return subprocess.run(['sh', '-c', '. "$HELPER"; PATH="$TEST_BIN:$PATH"; '
                               'STATE=$TEST_STATE; IFACE=awg1; ' + command],
                              env=env, capture_output=True, text=True)

    def read(self):
        return json.loads(self.model.read_text())

    def update(self, **values):
        state = self.read()
        state.update(values)
        self.model.write_text(json.dumps(state))

    def pending(self, content='quick awg1\n'):
        path = self.state / 'opnsense-awg.pending'
        path.write_text(content)
        return path

    def test_direct_down_up_without_plugin_or_config_changes(self):
        result = self.execute('restart_opn_awg awg1')
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.read()
        self.assertEqual(state['events'], ['down', 'up', 'group', 'filter'])
        self.assertEqual((state['enabled'], state['exists'], state['up']), (1, 1, 1))
        self.assertFalse((self.state / 'opnsense-awg.pending').exists())

    def test_standalone_awg_without_plugin_model(self):
        self.update(managed=False, enabled=0)
        result = self.execute('restart_opn_awg awg1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()['events'], ['down', 'up', 'group', 'filter'])
        self.assertEqual(self.read()['enabled'], 0)

    def test_failed_up_is_recovered_by_a_later_process(self):
        self.update(fail='up')
        self.assertNotEqual(self.execute('restart_opn_awg awg1').returncode, 0)
        self.assertEqual(self.read()['enabled'], 1)
        self.assertEqual(self.read()['exists'], 0)
        self.assertTrue((self.state / 'opnsense-awg.pending').exists())
        result = self.execute('recover_opn_awg')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()['events'], ['down', 'up', 'up', 'group', 'filter'])
        self.assertFalse((self.state / 'opnsense-awg.pending').exists())

    def test_failed_recovery_retains_record_for_retry(self):
        self.update(exists=0, up=0, fail='up')
        path = self.pending()
        self.assertNotEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertTrue(path.exists())
        self.assertEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertFalse(path.exists())

    def test_manual_disable_is_preserved(self):
        self.update(enabled=0, exists=0, up=0)
        self.assertEqual(self.execute('restart_opn_awg awg1').returncode, 0)
        self.assertEqual(self.read()['enabled'], 0)
        self.assertEqual(self.read()['events'], [])
        self.assertFalse((self.state / 'opnsense-awg.pending').exists())

    def test_pending_recovery_respects_manual_disable(self):
        self.update(enabled=0, exists=0, up=0)
        path = self.pending()
        self.assertEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertEqual(self.read()['enabled'], 0)
        self.assertEqual(self.read()['events'], [])
        self.assertFalse(path.exists())

    def test_pending_recovery_respects_administrative_down(self):
        self.update(up=0)
        path = self.pending()
        self.assertEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertEqual(self.read()['up'], 0)
        self.assertEqual(self.read()['events'], [])
        self.assertFalse(path.exists())

    def test_global_disable_is_preserved(self):
        self.update(general=0)
        path = self.pending()
        self.assertEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertEqual(self.read()['events'], [])
        self.assertFalse(path.exists())

    def test_unknown_admin_intent_does_not_start_device(self):
        self.update(readable=False, exists=0, up=0)
        path = self.pending()
        self.assertNotEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertTrue(path.exists())
        self.assertEqual(self.read()['events'], [])

    def test_recovery_after_successful_up_does_not_restart_again(self):
        self.pending()
        self.assertEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertEqual(self.read()['events'], ['group', 'filter'])

    def test_legacy_toggle_record_is_not_misinterpreted(self):
        path = self.pending('11111111-1111-4111-8111-111111111111 awg1\n')
        self.assertNotEqual(self.execute('recover_opn_awg').returncode, 0)
        self.assertTrue(path.exists())
        self.assertEqual(self.read()['events'], [])


if __name__ == '__main__':
    unittest.main()
