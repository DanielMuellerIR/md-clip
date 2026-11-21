#!/usr/bin/env python3
"""Opt-in-Vordergrundprüfung der Vorschau mit ausschließlich privaten Nutzdaten."""
import argparse
import base64
import json
from itertools import count
import os
from pathlib import Path
import platform
import plistlib
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
mode = parser.add_mutually_exclusive_group(required=True)
mode.add_argument('--allow-focus', action='store_true', help='Fokussierte Tastaturprüfung ausdrücklich erlauben')
mode.add_argument('--background', action='store_true', help='AppKit-Ereignisse bei unverändertem Systemfokus prüfen')
parser.add_argument('--output', type=Path, required=True, help='Neuer Ordner für synthetische Ergebnisbelege')
args = parser.parse_args()
if platform.system() != 'Darwin':
    print('SKIP: Vordergrundprüfung benötigt macOS')
    raise SystemExit(0)
console = plistlib.loads(subprocess.check_output(['ioreg', '-n', 'Root', '-d1', '-a']))
console = console[0] if isinstance(console, list) else console
# Der globale Wert kann bereits frei melden, während die Benutzersitzung noch gesperrt ist.
session_unlocked = any(
    session.get('kCGSSessionOnConsoleKey') is True
    and session.get('kCGSSessionUserIDKey') == os.getuid()
    and session.get('CGSSessionScreenIsLocked', False) is False
    for session in console.get('IOConsoleUsers', [])
)
if (console.get('IOConsoleLocked') is not False
        or os.stat('/dev/console').st_uid != os.getuid() or not session_unlocked):
    parser.error('Die eigene Konsolensitzung muss entsperrt sein.')
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=False)
ROOT = Path(__file__).resolve().parents[1]
BODY = '# Tastatur ä😀\n\nErste Zeile.\nZweite Zeile.\n\n```sh\nprintf "%s" \\\n  "\\# unverändert"\n```\n'
results = []
children = []


def interrupted(_signum, _frame):
    raise KeyboardInterrupt('Vordergrundprüfung abgebrochen')


signal.signal(signal.SIGTERM, interrupted)


def osa(source, *arguments):
    return subprocess.check_output(['osascript', '-e', source, *map(str, arguments)],
                                   text=True, stderr=subprocess.STDOUT, timeout=8).strip()


def activate(pid):
    osa('on run argv\ntell application "System Events"\n'
        'set frontmost of first application process whose unix id is (item 1 of argv as integer) to true\n'
        'end tell\nend run', pid)


def terminate(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=4)


def record(name, passed, **values):
    result = dict(case=name, passed=bool(passed), **values)
    results.append(result)
    (args.output/'result.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
    print(('OK: ' if passed else 'FAIL: ')+name, flush=True)


with tempfile.TemporaryDirectory(prefix='md-clip-foreground-', dir='/private/tmp') as temporary:
    work = Path(temporary)
    runtime = work/'runtime with spaces'
    (runtime/'bin').mkdir(parents=True)
    (runtime/'helpers').mkdir()
    shutil.copy2(ROOT/'bin/md-clip', runtime/'bin/md-clip')
    shutil.copytree(ROOT/'lib', runtime/'lib')
    app = work/'Preview Keyboard Test.app'
    (app/'Contents/MacOS').mkdir(parents=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.example.md-clip-foreground-test',
        'CFBundleName': 'Preview Keyboard Test', 'CFBundleExecutable': 'md-clip-preview',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': False,
    }))
    undo = runtime/'helpers/clipboard-undo'
    preview = app/'Contents/MacOS/md-clip-preview'
    board_helper = work/'private-board'
    accessibility = work/'accessibility'
    swift = ['swiftc', '-target', platform.machine() + '-apple-macos14.0']
    strict = ['-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors']
    for sources, binary, flags in (
        (['helpers/clipboard-undo.swift', 'tests/clipboard-undo-test-main.swift'], undo, [*strict, '-O']),
        (['helpers/md-clip-preview.swift', 'tests/md-clip-preview-test-main.swift'], preview, strict),
        (['tests/test-preview-integration.swift'], board_helper, []),
        (['tests/preview-accessibility.swift'], accessibility, []),
    ):
        subprocess.run([*swift, *flags, *(str(ROOT / source) for source in sources),
                        '-o', str(binary)], check=True)
    (runtime/'helpers/md-clip-preview').symlink_to(preview)
    cli = runtime/'bin/md-clip'
    driver = subprocess.Popen([str(board_helper), str(undo), str(cli), str(work/'board'), '--serve-private-board'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(args.output/'board-stderr.log').open('wb'),
                              text=True, bufsize=1)
    children.append(driver)

    def receive():
        if not select.select([driver.stdout], [], [], 8)[0]:
            raise AssertionError('Private Zwischenablage antwortet nicht')
        line = driver.stdout.readline()
        assert line, 'Privater Board-Prozess beendet'
        return json.loads(line)

    ready = receive()
    environment = dict(os.environ, MD_CLIP_TEST_PASTEBOARD=ready['board'],
                       MD_CLIP_TEST_DIRECTORY=ready['directory'],
                       MD_CLIP_TEST_PREVIEW_EVIDENCE=str(work/'observed.json'),
                       MD_CLIP_TEST_PREVIEW_INPUT=str(work/'input-event.json'))
    if args.background:
        environment['MD_CLIP_TEST_PREVIEW_BACKGROUND'] = '1'
    else:
        environment.pop('MD_CLIP_TEST_PREVIEW_BACKGROUND', None)
    environment.pop('MD_CLIP_TEST_PREVIEW_ACTION', None)
    input_file = work/'body.txt'
    input_file.write_text(BODY)
    observed = work/'observed.json'
    event_file = work/'input-event.json'

    input_serial = count(1)

    def send_input(**value):
        identifier = next(input_serial)
        pending = event_file.with_suffix('.pending')
        pending.write_text(json.dumps(dict(id=identifier, **value)))
        pending.replace(event_file)
        return identifier

    def send_key(code, characters, command=False, shift=False):
        return send_input(code=code, characters=characters, command=command, shift=shift)

    def board(operation, **values):
        driver.stdin.write(json.dumps(dict(operation=operation, **values))+'\n')
        driver.stdin.flush()
        return receive()

    def observation(process, predicate=lambda value: value.get('accept')):
        end = time.monotonic()+12
        while time.monotonic() < end:
            assert process.poll() is None, ('Vorschau vorzeitig beendet', process.poll())
            try:
                value = json.loads(observed.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                value = {}
            if value and args.background:
                assert value.get('front_pid') != value.get('preview_pid'), (
                    'Die private Vorschau hat im Hintergrundmodus den Systemfokus übernommen'
                )
            if predicate(value):
                return value
            time.sleep(.05)
        raise AssertionError('Erwarteter Fensterzustand nicht erreicht')

    def start():
        observed.unlink(missing_ok=True)
        event_file.unlink(missing_ok=True)
        process = subprocess.Popen([str(cli), '--input', str(input_file), '--plain', '--replace', '--preview-window', '--quiet'],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append(process)
        try:
            value = observation(process)
            pid = value['preview_pid']
            if args.allow_focus:
                activate(pid)
            return process, pid
        except Exception:
            terminate(process)
            raise

    def focus(process, pid, name):
        target = {'content': 'md-clip-preview-content', 'notes': 'Quelle und Konvertierungshinweise'}[name]
        if args.allow_focus:
            subprocess.run([str(accessibility), str(pid), 'focus', target], check=True, capture_output=True, timeout=6)
            return observation(process, lambda value: value.get('focus') == name and value.get('key_window'))
        identifier = send_input(focus=name)
        return observation(process, lambda value: value.get('last_input') == identifier and value.get('focus') == name)

    def finished(process, expected):
        try:
            output, error = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            return False, None, 'Fenster blieb offen'
        return process.returncode == expected and not output, process.returncode, error.decode('utf-8', 'replace')

    def tab_sequence(process, reverse=False):
        sequence = []
        for _ in range(8):
            identifier = send_key(48, '\t', shift=reverse)
            current = observation(process, lambda value: value.get('last_input') == identifier)
            sequence.append(current['focus'])
        return sequence

    try:
        for name, location, key, expected in (
            ('return-initial', None, (36, '\r'), 0),
            ('return-content', 'content', (36, '\r'), 0),
            ('enter-content', 'content', (76, '\x03'), 0),
            ('return-notes', 'notes', (36, '\r'), 0),
            ('escape-content', 'content', (53, '\x1b'), 4),
            ('escape-notes', 'notes', (53, '\x1b'), 4),
            ('command-return-content', 'content', (36, '\r', True), 0),
            ('command-q-content', 'content', (12, 'q', True), 4),
            ('command-z-content', 'content', (6, 'z', True), 0),
        ):
            seeded = board('seed', previous=name.startswith('command-z'))
            process = None
            try:
                process, pid = start()
                before = focus(process, pid, location) if location else observation(process)
                send_key(*key)
                passed, actual, error = finished(process, expected)
                snapshot = board('snapshot')
                if passed and name.startswith('command-z'):
                    passed = snapshot['items'] == seeded['original']
                elif passed and expected == 0:
                    encoded = base64.b64encode(BODY.encode()).decode()
                    passed = snapshot['items'] == [{'public.utf8-plain-text': encoded}]
                    restored = board('undo')
                    passed = passed and restored['exit'] == 0 and restored['items'] == seeded['original']
                elif passed:
                    passed = snapshot['items'] == seeded['items'] and snapshot['change_count'] == seeded['change_count']
                passed = passed and snapshot['host_change_count'] == seeded['host_change_count']
                record(name, passed, initial_focus=before.get('focus'), exit=actual, error=error,
                       host_unchanged=snapshot['host_change_count'] == seeded['host_change_count'])
            except Exception as error:
                record(name, False, error=str(error))
            finally:
                if process:
                    terminate(process)

        seeded = board('seed', previous=True)
        process, pid = start()
        try:
            initial = observation(process)
            if initial['keyboard_access']:
                forward = tab_sequence(process)
                backward = tab_sequence(process, reverse=True)
                expected = {'content', 'notes', 'accept', 'cancel', 'undo'}
                record('tab-and-shift-tab', expected.issubset(forward) and expected.issubset(backward),
                       keyboard_access=True, forward=forward, backward=backward)
            else:
                record('tab-disabled-by-system', True, skipped=True,
                       reason='Vollständige Tastaturnavigation ist aus; die Prüfung aller Tab-Ziele steht noch aus.',
                       keyboard_access=False)
            board('write', text='Neue private Generation')
            invalid = observation(process, lambda value: not value.get('accept') and not value.get('undo'))
            if initial['keyboard_access']:
                forward = tab_sequence(process)
                backward = tab_sequence(process, reverse=True)
                record('tab-skips-unavailable-actions', {'content', 'notes', 'cancel'}.issubset(forward)
                       and {'content', 'notes', 'cancel'}.issubset(backward)
                       and not {'accept', 'undo'}.intersection(forward+backward),
                       status=invalid['status'], forward=forward, backward=backward)
            else:
                record('tab-unavailable-actions-disabled-by-system', True, skipped=True, keyboard_access=False)
        finally:
            terminate(process)

        seeded = board('seed')
        process, pid = start()
        try:
            focus(process, pid, 'content')
            send_key(0, 'a', True)
            selection = observation(process, lambda value: value.get('selection') == [0, len(BODY.encode('utf-16-le'))//2])
            typed = send_key(7, 'X')
            after_typing = observation(process, lambda value: value.get('last_input') == typed)
            unchanged = after_typing['content'] == BODY
            record('read-only-select-all', unchanged, selection=selection['selection'])
            send_key(8, 'c', True)
            invalid = observation(process, lambda value: value.get('accept') is False)
            snapshot = board('snapshot')
            encoded = base64.b64encode(BODY.encode()).decode()
            record('copy-private-and-invalidate', snapshot['items'] == [{'public.utf8-plain-text': encoded}]
                   and snapshot['host_change_count'] == seeded['host_change_count'], status=invalid['status'],
                   private_items=snapshot['items'], host_change_count_before=seeded['host_change_count'],
                   host_change_count_after=snapshot['host_change_count'])
            refused = send_key(36, '\r')
            observation(process, lambda value: value.get('last_input') == refused)
            record('invalid-return-does-not-write', process.poll() is None and board('snapshot')['change_count'] == snapshot['change_count'])
            send_key(53, '\x1b')
            record('invalid-escape-closes', finished(process, 4)[0])
        finally:
            terminate(process)

        seeded = board('seed', previous=True, pending_seconds=8)
        process, pid = start()
        try:
            expired = observation(process, lambda value: value.get('accept') is False and value.get('undo') is True)
            record('pending-expiry-keeps-undo', board('snapshot')['items'] == seeded['items'], status=expired['status'])
            send_key(6, 'z', True)
            record('undo-after-pending-expiry', finished(process, 0)[0] and board('snapshot')['items'] == seeded['original'])
        finally:
            terminate(process)
    finally:
        for process in reversed(children[1:]):
            terminate(process)
        try:
            board('stop')
        finally:
            terminate(driver)

if not results or not all(item['passed'] for item in results):
    raise SystemExit(1)
print('OK: Vorschau mit fensterlokalen AppKit-Ereignissen und privater CLI-/Undo-Integration')
