#!/usr/bin/env python3
"""Test a real macOS coordinator and iOS signer on a dedicated Simulator.

Uses isolated testnet wallets. Screenshots are opt-in with --screenshots.
No funded transaction is broadcast. Requires Flutter, Xcode and macOS.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'network.noosphere.sygnature'
STATE_KEYS = {
    'mac-ready', 'ios-public-key', 'invitation', 'fingerprint', 'group-key',
    'group-address', 'ios-active', 'signed-message', 'ios-done', 'mac-passed',
}


def stop_process_group(process):
    """Stop only descendants of a Flutter command started by this runner."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('simulator', help='dedicated iOS Simulator UUID; no real wallet data')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/apple-roast-e2e')
    parser.add_argument('--port', type=int, default=0, help='loopback bridge port (default: automatic)')
    parser.add_argument('--screenshots', action='store_true', help='also capture native iOS PNGs')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This workflow requires macOS and Xcode.')

    devices = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], text=True,
    ))['devices']
    device = next((device for group in devices.values() for device in group
                   if device['udid'] == args.simulator), None)
    if device is None:
        parser.error('Simulator UUID is not available; use xcrun simctl list devices available.')
    if device['state'] not in ('Shutdown', 'Booted'):
        parser.error('Wait for the Simulator to finish its current state transition.')

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    screenshots = output / 'screenshots'
    if args.screenshots:
        screenshots.mkdir(exist_ok=True)
    state = {}
    lock = threading.Lock()

    class Bridge(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            with lock:
                value = state.get(self.path.lstrip('/'))
            self.reply(value)

        def do_POST(self):
            key = self.path.lstrip('/')
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 1024 * 1024:
                    self.send_error(400, 'Invalid request length')
                    return
                value = json.loads(self.rfile.read(length))
                if key.startswith('capture/'):
                    name = key.split('/', 1)[1]
                    if not args.screenshots or not re.fullmatch(r'[0-9]{2}-[a-z-]+', name):
                        self.send_error(400, 'Screenshot capture is disabled or name is invalid')
                        return
                    subprocess.run(['xcrun', 'simctl', 'io', args.simulator,
                                    'screenshot', str(screenshots / f'{name}.png')],
                                   check=True, capture_output=True, timeout=30)
                    print(f'Captured {name}', flush=True)
                elif key in STATE_KEYS:
                    with lock:
                        state[key] = value
                        (output / 'public-results.json').write_text(json.dumps(state, indent=2))
                    print(f'Phase: {key}', flush=True)
                else:
                    self.send_error(404)
                    return
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                print(f'Bridge request failed: {error}', file=sys.stderr, flush=True)
                self.send_error(500, 'Test bridge request failed')
                return
            self.reply(True)

        def reply(self, value):
            data = json.dumps(value).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(('127.0.0.1', args.port), Bridge)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    processes = []
    booted_here = False
    status_bar_overridden = False
    ios_started = False
    try:
        if device['state'] == 'Shutdown':
            subprocess.run(['xcrun', 'simctl', 'boot', args.simulator], check=True)
            booted_here = True
        subprocess.run(['xcrun', 'simctl', 'bootstatus', args.simulator, '-b'], check=True)
        if args.screenshots:
            subprocess.run(['xcrun', 'simctl', 'status_bar', args.simulator, 'override',
                            '--time', '9:41', '--dataNetwork', 'wifi', '--wifiMode', 'active',
                            '--wifiBars', '3', '--batteryState', 'charged',
                            '--batteryLevel', '100'], check=True)
            status_bar_overridden = True

        base = ['flutter', 'test', '--no-pub',
                'integration_test/apple_roast_workflow_test.dart',
                '--dart-define=RUN_APPLE_ROAST_WORKFLOW=true',
                f'--dart-define=CAPTURE_APPLE_SCREENSHOTS={str(args.screenshots).lower()}',
                f'--dart-define=APPLE_TEST_BRIDGE=http://127.0.0.1:{server.server_port}',
                '--reporter=expanded']
        with (output / 'macos.log').open('w') as maclog, (output / 'ios.log').open('w') as ioslog:
            mac = subprocess.Popen(base + ['-d', 'macos'], cwd=ROOT, start_new_session=True,
                                   stdout=maclog, stderr=subprocess.STDOUT)
            processes.append(mac)
            deadline = time.monotonic() + 900
            while not state.get('mac-ready'):
                if mac.poll() is not None:
                    raise RuntimeError(f'macOS startup failed; see {output / "macos.log"}')
                if time.monotonic() > deadline:
                    raise TimeoutError('macOS startup')
                time.sleep(1)
            ios = subprocess.Popen(base + ['-d', args.simulator], cwd=ROOT, start_new_session=True,
                                   stdout=ioslog, stderr=subprocess.STDOUT)
            processes.append(ios)
            ios_started = True
            deadline = time.monotonic() + 900
            while any(process.poll() is None for process in processes):
                if any(process.poll() not in (None, 0) for process in processes):
                    raise RuntimeError(f'Workflow failed; see logs in {output}')
                if time.monotonic() > deadline:
                    raise TimeoutError('Apple workflow')
                time.sleep(1)
            if any(process.returncode != 0 for process in processes):
                raise RuntimeError(f'Workflow failed; see logs in {output}')
            if not state.get('mac-passed') or not state.get('ios-done'):
                raise RuntimeError('Workflow did not report completion')
            print(f'PASS: DKG and verified ROAST signature. Logs: {output}', flush=True)
            if args.screenshots:
                print(f'Screenshots: {screenshots}', flush=True)
    finally:
        for process in processes:
            stop_process_group(process)
        if ios_started:
            subprocess.run(['xcrun', 'simctl', 'terminate', args.simulator, BUNDLE_ID],
                           capture_output=True)
        if status_bar_overridden:
            subprocess.run(['xcrun', 'simctl', 'status_bar', args.simulator, 'clear'],
                           capture_output=True)
        if booted_here:
            subprocess.run(['xcrun', 'simctl', 'shutdown', args.simulator], capture_output=True)
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
