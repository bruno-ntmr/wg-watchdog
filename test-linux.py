"""Real WG/AWG test using the isolated namespace approach from 0din tests.

Run: unshare --user --map-root-user --net --mount python3 test-linux.py
Creates no host interfaces, users, services, routes or persistent keys.
"""
import os
import pathlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent


def run(*args, data=None, check=True):
    result = subprocess.run(args, input=data, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr}')
    return result


def main():
    if os.getuid() != 0 or pathlib.Path('/proc/self/uid_map').read_text().split()[:3] == ['0', '0', '4294967295']:
        raise SystemExit('Use unshare --user --map-root-user --net --mount')
    run('ip', 'link', 'set', 'lo', 'up')
    pairs = []
    with tempfile.TemporaryDirectory(prefix='wg-watchdog-linux-') as directory:
        tmp = pathlib.Path(directory)
        # Ubuntu confines wg-quick to /etc/wireguard. Bind ONLY in this private
        # mount namespace; the real /etc/wireguard and its contents are untouched.
        configs = tmp / 'configs'
        configs.mkdir()
        run('mount', '--bind', str(configs), '/etc/wireguard')
        try:
            for n, tool in enumerate(('wg', 'awg')):
                kind = 'wireguard' if tool == 'wg' else 'amneziawg'
                server, client = f'wd-{tool}-s', f'wd-{tool}-c'
                a, b = [run(tool, 'genkey').stdout.strip() for _ in range(2)]
                ap, bp = [run(tool, 'pubkey', data=key).stdout.strip() for key in (a, b)]
                port = 52990 + n * 2
                conf = pathlib.Path('/etc/wireguard') / f'{client}.conf'
                conf.write_text(f'[Interface]\nPrivateKey = {b}\nAddress = 10.231.{n}.2/24\nListenPort = {port+1}\nTable = off\n'
                                f'[Peer]\nPublicKey = {ap}\nEndpoint = 127.0.0.1:{port}\nAllowedIPs = 10.231.{n}.1/32\nPersistentKeepalive = 1\n')
                conf.chmod(0o600)
                run('ip', 'link', 'add', server, 'type', kind)
                run(tool, 'set', server, 'listen-port', str(port), 'private-key', '/dev/stdin', data=a)
                run(tool, 'set', server, 'peer', bp, 'allowed-ips', f'10.231.{n}.2/32')
                run('ip', 'addr', 'add', f'10.231.{n}.1/32', 'dev', server)
                run('ip', 'link', 'set', server, 'up')
                run(f'{tool}-quick', 'up', str(conf))
                pairs.append((tool, client, server, conf, ap, port))
            cfg = tmp / 'watchdog.conf'
            cfg.write_text(''.join(f'{c} 1 {t}-quick {f} {t}\n' for t, c, s, f, p, port in pairs))
            state = tmp / 'state'
            cmd = ('sh', str(ROOT / 'wg-watchdog.sh'), '-c', str(cfg), '--state-dir', str(state), '-v')
            installed = tmp / 'installed.sh'
            installed_conf = tmp / 'installed.conf'
            installer = ('sh', str(ROOT / 'install.sh'), '--no-cron', '--timeout', '1',
                         '--bin', str(installed), '--config', str(installed_conf))
            run(*installer)
            discovered = installed_conf.read_text()
            assert 'wd-wg-c 1 wg-quick' in discovered
            assert 'wd-awg-c 1 awg-quick' in discovered
            installed_conf.write_text(discovered.replace('wd-wg-c 1 ', 'wd-wg-c 7 '))
            preserved = installed_conf.read_bytes()
            run(*installer)
            assert installed_conf.read_bytes() == preserved
            run(*installer, '--uninstall')
            assert not installed.exists() and installed_conf.read_bytes() == preserved
            print('Installer discovers WG/AWG, preserves config, is idempotent and uninstalls: PASS', flush=True)
            for tool, client, _, _, _, _ in pairs:
                for _ in range(40):
                    if int(run(tool, 'show', client, 'latest-handshakes').stdout.split()[1]) > 0:
                        break
                    time.sleep(.25)
                else:
                    raise AssertionError(f'{tool}: no initial handshake')
            # An offline extra peer must not restart a healthy multi-peer tunnel.
            state.mkdir()
            for tool, client, _, _, _, _ in pairs:
                dead_pub = run(tool, 'pubkey', data=run(tool, 'genkey').stdout).stdout.strip()
                run(tool, 'set', client, 'peer', dead_pub, 'allowed-ips', '10.250.250.250/32')
                (state / f'{client}.since').write_text(str(int(time.time()) - 1000))
            healthy = run(*cmd)
            assert 'stale handshake; restarting' not in healthy.stderr
            for _, client, _, _, _, _ in pairs:
                (state / f'{client}.since').write_text(str(int(time.time())))
            print('Healthy peer plus offline peer: no restart, PASS', flush=True)
            print(run(*cmd).stderr, flush=True)
            fault_time = int(time.time())
            for tool, client, _, _, pub, _ in pairs:
                run(tool, 'set', client, 'peer', pub, 'endpoint', '127.0.0.1:9')
                run(tool, 'set', client, 'peer', pub, 'preshared-key', '/dev/stdin', data=run(tool, 'genpsk').stdout)
            print('WG and AWG runtime keys broken inside isolated namespace; waiting 65 seconds', flush=True)
            time.sleep(65)
            result = run(*cmd)
            print(result.stderr, flush=True)
            assert result.stderr.count('restart command completed') == 2
            for tool, client, _, _, _, port in pairs:
                for _ in range(60):
                    handshake = int(run(tool, 'show', client, 'latest-handshakes').stdout.split()[1])
                    if handshake > fault_time:
                        break
                    time.sleep(.25)
                else:
                    raise AssertionError(f'{tool}: handshake did not recover')
                assert run(tool, 'show', client, 'endpoints').stdout.split()[1] == f'127.0.0.1:{port}'
                print(f'{tool}: endpoint restored and fresh real handshake', flush=True)
            # A never-handshaken peer must not cause an immediate restart.
            tool, client, _, _, pub, _ = pairs[0]
            run(tool, 'set', client, 'peer', pub, 'remove')
            run(tool, 'set', client, 'peer', pub, 'allowed-ips', '10.231.0.1/32', 'endpoint', '127.0.0.1:9')
            result = run(*cmd)
            assert 'startup/restart grace period' in result.stderr
            assert 'stale handshake; restarting' not in result.stderr
            print('Cooldown and zero-handshake grace: PASS', flush=True)
            (state / 'lock').mkdir()
            (state / 'lock' / 'pid').write_text(str(os.getpid()))
            result = run(*cmd)
            assert 'another invocation holds the lock' in result.stderr
            (state / 'lock' / 'pid').unlink()
            (state / 'lock').rmdir()
            print('Concurrent invocation lock: PASS', flush=True)
            (state / 'lock').mkdir()
            (state / 'lock' / 'pid').write_text('2147483647')
            run(*cmd)
            assert not (state / 'lock').exists()
            print('Stale lock reclamation: PASS', flush=True)
            before = {p.name: p.read_bytes() for p in state.iterdir()}
            run(*cmd, '--dry-run')
            assert before == {p.name: p.read_bytes() for p in state.iterdir()}
            print('Dry-run leaves state unchanged: PASS', flush=True)
        finally:
            for tool, client, server, conf, _, _ in pairs:
                run(f'{tool}-quick', 'down', str(conf), check=False)
                run('ip', 'link', 'del', server, check=False)
            run('umount', '/etc/wireguard')
            print('Temporary WG/AWG devices and configs removed', flush=True)


if __name__ == '__main__':
    main()
