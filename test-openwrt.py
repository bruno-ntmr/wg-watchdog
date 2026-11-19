"""OpenWrt owner discovery, including procd devices absent from netifd."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
MOCK = '''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
if Path(sys.argv[0]).name=='ubus':
    target=sys.argv[2]
    if target=='network.interface': print(os.environ['TEST_DUMP'])
    else: print(os.environ['TEST_STATUS'])
else:
    data=json.load(sys.stdin)
    for expression in sys.argv[1:]:
        if expression=='-e': continue
        if expression in ('@.l3_device','@.proto'):
            print(data[expression[2:]])
        else:
            match=re.search(r'@\\.interface\\[@\\.(\\w+)="([^"]+)"\\]',expression)
            if not match: raise RuntimeError(expression)
            key, value=match.groups()
            for row in data['interface']:
                if row.get(key)==value: print(row['interface'])
'''


class OpenWrtDiscoveryTest(unittest.TestCase):
    def discover(self, name, rows=(), status=None, services='awgmgmt'):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            source = (ROOT / 'wg-watchdog.sh').read_text()
            (tmp / 'library.sh').write_text(source.split('\nif [ "$DISCOVER" = 1 ]; then', 1)[0])
            for tool in ('ubus', 'jsonfilter'):
                path = tmp / tool
                path.write_text(MOCK)
                path.chmod(0o755)
            env = dict(os.environ, TEST_DIR=str(tmp), TEST_NAME=name,
                       TEST_DUMP=json.dumps({'interface': list(rows)}),
                       TEST_STATUS=json.dumps(status or {}), TEST_SERVICES=services)
            return subprocess.run(['sh', '-c', '. "$TEST_DIR/library.sh"; '
                'PATH="$TEST_DIR:$PATH"; NAME=$TEST_NAME; IFACE=$NAME; '
                'userspace_services() { printf "%s\\n" "$TEST_SERVICES"; }; '
                'detect_openwrt_backend || exit 1; printf "%s %s %s\\n" "$IFACE" "$BACKEND" "$TARGET"'],
                env=env, capture_output=True, text=True)

    def test_userspace_device_without_netifd(self):
        result = self.discover('awgmgmt')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'awgmgmt openwrt-service awgmgmt')

    def test_native_wireguard_uses_logical_name(self):
        result = self.discover('wg0', [{'interface': 'vpn', 'l3_device': 'wg0'}],
                              {'l3_device': 'wg0', 'proto': 'wireguard'})
        self.assertEqual(result.stdout.strip(), 'wg0 openwrt vpn')

    def test_userspace_with_static_netifd_registration(self):
        result = self.discover('awg0', [{'interface': 'awg0', 'l3_device': 'awg0'}],
                              {'l3_device': 'awg0', 'proto': 'static'}, 'userspace')
        self.assertEqual(result.stdout.strip(), 'awg0 openwrt-service userspace')

    def test_multiple_netifd_owners_are_rejected(self):
        result = self.discover('awg0', [{'interface': x, 'l3_device': 'awg0'} for x in ('one', 'two')])
        self.assertNotEqual(result.returncode, 0)

    def test_multiple_userspace_owners_are_rejected(self):
        self.assertNotEqual(self.discover('awgmgmt', services='one\ntwo').returncode, 0)

    def test_missing_userspace_owner_is_rejected(self):
        self.assertNotEqual(self.discover('awgmgmt', services='').returncode, 0)


if __name__ == '__main__':
    unittest.main()
