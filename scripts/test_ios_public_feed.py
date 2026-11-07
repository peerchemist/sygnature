#!/usr/bin/env python3
"""Exercise production iOS public-feed worker against an isolated macOS Sygnature.

Use a dedicated simulator. Notifications use provisional authorization (no prompt).
Default mode allocates a finite UIKit execution window and invokes the native
worker while backgrounded. It does not prove suspended-app wake or OS cadence.
--simulate-bg-task attempts the unsupported simulator BGTaskScheduler path.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'network.noosphere.sygnature'
IDENTIFIER = 'network.noosphere.sygnature.public-feed'


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', help='dedicated simulator UUID')
    parser.add_argument('--simulate-bg-task', action='store_true', help='Attempt the unsupported simulator BGTaskScheduler path instead of the allocated-window check')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/ios-public-feed-qa')
    args = parser.parse_args()
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], text=True))['devices']
    device = next((d for group in devices.values() for d in group if d['udid'] == args.simulator), None)
    if device is None or not device['name'].startswith('Sygnature-PublicFeed-QA'):
        parser.error('Use a dedicated simulator named Sygnature-PublicFeed-QA; its QA app is replaced each run.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    state = {}
    lock = threading.Lock()
    processes = []

    class Bridge(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            with lock:
                value = state.get(self.path.lstrip('/'))
            self.reply(value)

        def do_POST(self):
            key = self.path.lstrip('/')
            length = int(self.headers.get('Content-Length', 0))
            if not 0 < length < 1024 * 1024:
                self.send_error(400)
                return
            value = json.loads(self.rfile.read(length))
            with lock:
                state[key] = value
                # Feed capabilities are ephemeral and never written to results.
                public = {k: v for k, v in state.items() if k != 'share'}
                (output / 'public-results.json').write_text(json.dumps(public, indent=2))
            print(f'Phase: {key}', flush=True)
            self.reply(True)

        def reply(self, value):
            data = json.dumps(value).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Bridge)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    define = f'--dart-define=PUBLIC_FEED_TEST_BRIDGE=http://127.0.0.1:{server.server_port}'

    def wait_for(key, timeout=180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with lock:
                if state.get('mac-failed') or state.get('ios-failed'):
                    raise RuntimeError('Harness setup failed; inspect platform logs')
                value = state.get(key)
            if value is not None:
                return value
            if any(p.poll() is not None for p in processes):
                raise RuntimeError('macOS coordinator exited')
            time.sleep(.25)
        raise TimeoutError(key)

    def command(key):
        with lock:
            state[key] = True

    def trigger(pid, phase):
        commands = output / f'{phase}.lldb'
        commands.write_text(
            f'process attach --pid {pid}\n'
            'expression -l objc -- @import BackgroundTasks;\n'
            f'expression -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"{IDENTIFIER}"]\n'
            'process detach\nquit\n')
        with (output / f'{phase}-lldb.log').open('w') as log:
            run(['xcrun', 'lldb', '--batch', '--source', str(commands)],
                stdout=log, stderr=subprocess.STDOUT, timeout=180)

    def invoke(pid, phase, port):
        if args.simulate_bg_task:
            trigger(pid, phase)
        else:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/enqueue', timeout=10) as response:
                if response.read() != b'scheduled':
                    raise RuntimeError('Background scheduler did not accept QA task')

    try:
        # All Flutter builds use test-only entry points; normal wallet files are untouched.
        for platform, flags in [('macos', []), ('ios', ['--simulator'])]:
            print(f'Building {platform} QA app', flush=True)
            with (output / f'{platform}-build.log').open('w') as log:
                run(['flutter', 'build', platform, '--debug', '--no-pub', *flags,
                     '--target=test/support/apple_public_feed_harness.dart', define],
                    cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        maclog = (output / 'macos.log').open('w')
        mac = subprocess.Popen([str(ROOT / 'build/macos/Build/Products/Debug/sygnature.app/Contents/MacOS/sygnature')],
                               cwd=ROOT, stdout=maclog, stderr=subprocess.STDOUT,
                               start_new_session=True)
        processes.append(mac)
        wait_for('mac-ready')
        subprocess.run(['xcrun', 'simctl', 'uninstall', args.simulator, BUNDLE], capture_output=True)
        run(['xcrun', 'simctl', 'install', args.simulator,
             str(ROOT / 'build/ios/iphonesimulator/Runner.app')], capture_output=True)
        ios_env = dict(os.environ, SIMCTL_CHILD_SYGNATURE_PUBLIC_FEED_QA='1')
        launch = run(['xcrun', 'simctl', 'launch', '--terminate-running-process',
                      f'--stdout={output / "ios.log"}', f'--stderr={output / "ios-stderr.log"}',
                      args.simulator, BUNDLE], capture_output=True, env=ios_env)
        pid = int(launch.stdout.strip().rsplit(': ', 1)[1])
        ios_ready = wait_for('ios-ready')
        container = Path(run(['xcrun', 'simctl', 'get_app_container', args.simulator,
                              BUNDLE, 'data'], capture_output=True).stdout.strip())
        support = container / 'Library/Application Support'
        result_file = support / 'public-feed-qa-result.json'
        lifecycle_file = support / 'public-feed-qa-lifecycle.txt'
        # Put another app in front; the subscriber has no foreground poller/timer.
        run(['xcrun', 'simctl', 'launch', args.simulator, 'com.apple.mobilesafari'], capture_output=True)
        time.sleep(35 if args.simulate_bg_task else 3)
        lifecycle = lifecycle_file.read_text().strip()
        if lifecycle not in ('hidden', 'paused'):
            raise RuntimeError(f'App did not enter background: {lifecycle}')
        command('start-dkg')
        wait_for('dkg-published')
        # A public feed is polled, not pushed: no scheduler invocation => no alert.
        time.sleep(10 if args.simulate_bg_task else 2)
        if result_file.exists():
            raise RuntimeError('Worker ran before the explicit test invocation')
        invoke(pid, 'background-dkg', ios_ready['controlPort'])
        deadline = time.monotonic() + 45
        while not result_file.exists() and time.monotonic() < deadline:
            time.sleep(.25)
        if not result_file.exists():
            raise RuntimeError('Worker did not run; inspect native logs (BGTaskScheduler is unavailable on simulator)')
        result = json.loads(result_file.read_text())
        (output / 'background-dkg-result.json').write_text(json.dumps(result, indent=2))
        if result.get('nativeState', {}).get('applicationState') != 2:
            raise RuntimeError('Worker did not execute while UIKit reported background state')
        if not result['success'] or not result['notificationIds']:
            raise RuntimeError('Background worker failed or did not deliver notification')
        if result['notificationTitles'] != ['New key generation request']:
            raise RuntimeError('Unexpected local notification')
        if result['feeds'][0]['cursor'] <= ios_ready['baselineCursor'] or not result['leaseReleased']:
            raise RuntimeError('Cursor did not advance durably or lease was retained')
        if result['feeds'][0]['outbox'] or result['feeds'][0]['failures']:
            raise RuntimeError('Delivery left pending notification intent or feed failure')
        print('PASS: background DKG request delivered', flush=True)
        # A second OS invocation must work without foreground re-registration.
        invoke(pid, 'repeat-no-new-event', ios_ready['controlPort'])
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            repeated = json.loads(result_file.read_text())
            if repeated['runs'] > result['runs']:
                break
            time.sleep(.25)
        (output / 'repeat-result.json').write_text(json.dumps(repeated, indent=2))
        if repeated['runs'] != result['runs'] + 1:
            raise RuntimeError('Second explicit worker invocation did not complete')
        if repeated['feeds'][0]['cursor'] != result['feeds'][0]['cursor']:
            raise RuntimeError('No-event run changed cursor')
        if repeated['notificationIds'] != result['notificationIds']:
            raise RuntimeError('Duplicate event notification')
        command('finish-dkg')
        wait_for('dkg-completed')
        command('start-signing')
        wait_for('signing-published')
        invoke(pid, 'background-signing', ios_ready['controlPort'])
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            final = json.loads(result_file.read_text())
            if final['runs'] > repeated['runs']:
                break
            time.sleep(.25)
        (output / 'background-signing-result.json').write_text(json.dumps(final, indent=2))
        if final.get('nativeState', {}).get('applicationState') != 2 or not final['leaseReleased']:
            raise RuntimeError('Signing worker was not backgrounded or retained its lease')
        if final['feeds'][0]['cursor'] <= repeated['feeds'][0]['cursor'] or final['feeds'][0]['outbox']:
            raise RuntimeError('Signing cursor/outbox was not committed')
        if not final['success'] or 'New signing request' not in final['notificationTitles']:
            raise RuntimeError('Signing request did not produce a background notification')
        print(f'PASS: background signing request delivered. Results: {output}', flush=True)
        print('LIMIT: UIKit execution window was allocated; suspended-app wake and OS cadence are NOT verified.', flush=True)
    finally:
        command('stop')
        for process in processes:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
        subprocess.run(['xcrun', 'simctl', 'terminate', args.simulator, BUNDLE],
                       capture_output=True)
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
