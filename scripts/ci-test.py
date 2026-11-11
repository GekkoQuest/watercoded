#!/usr/bin/env python3
"""Run tests only on Actions, with deadlines independent of Swift's executors."""

import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
DIAGNOSTICS = ROOT / '.build' / 'test-diagnostics'
PACKAGE = 'Packages/WatercodedKit'


def process_tree(root_pid=None):
    """Snapshot only the command we launched and its descendants, never name-match kills."""
    result = subprocess.run(
        ['ps', '-axo', 'pid=,ppid=,lstart=,command='],
        capture_output=True, text=True, timeout=5, check=True,
    )
    rows = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3:
            rows[int(fields[0])] = (int(fields[1]), fields[2])
    if root_pid is None:
        return rows
    selected = {root_pid}
    while True:
        children = {pid for pid, (parent, _) in rows.items() if parent in selected}
        expanded = selected | children
        if expanded == selected:
            break
        selected = expanded
    return {pid: rows[pid] for pid in selected if pid in rows}


def stop_owned_processes(process, owned):
    # Signal only captured descendants, including those with their own process groups.
    # Check start time and command again; reparenting after root exit is harmless.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        current = process_tree()
        for pid, identity in owned.items():
            if pid > 1 and pid in current and current[pid][1] == identity[1]:
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
        if sig == signal.SIGTERM:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        print('::error::Test process did not exit after termination', flush=True)


def capture_stacks(label, owned):
    snapshot = DIAGNOSTICS / f'{label}-processes.txt'
    snapshot.write_text(''.join(f'{pid} {parent} {identity}\n'
                                for pid, (parent, identity) in owned.items()))
    # The runner/SwiftPM stacks are useful even when the test executor cannot handle
    # cancellation. Sample test executables first and cap diagnostic collection time.
    ordered = sorted(owned, key=lambda pid: 'test' not in owned[pid][1].lower())
    for pid in ordered[:6]:
        try:
            subprocess.run(
                ['/usr/bin/sample', str(pid), '1', '-file',
                 str(DIAGNOSTICS / f'{label}-{pid}.sample.txt')],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass


def run_phase(label, seconds, arguments):
    print(f'::group::{label} (deadline: {seconds}s)', flush=True)
    log_path = DIAGNOSTICS / f'{label}.log'
    with log_path.open('w') as output, log_path.open(errors='replace') as reader:
        process = subprocess.Popen(arguments, cwd=ROOT, start_new_session=True,
                                   stdout=output, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + seconds
        code = None
        while code is None and time.monotonic() < deadline:
            # A regular file avoids a pipe reader waiting forever on a surviving child.
            sys.stdout.write(reader.read())
            sys.stdout.flush()
            try:
                code = process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                pass
        if code is None:
            print(f'::error::{label} exceeded {seconds}s; capturing thread stacks', flush=True)
            owned = process_tree(process.pid)
            try:
                capture_stacks(label, owned)
            finally:
                stop_owned_processes(process, owned)
            code = 124
        sys.stdout.write(reader.read())
        sys.stdout.flush()
    # A misspelled filter must not silently turn a release check into zero tests.
    if code == 0 and label != 'build-tests':
        log = log_path.read_text(errors='replace')
        if not re.search(r'Test run with [1-9][0-9]* tests?\b', log):
            print(f'::error::{label} did not report any completed Swift tests', flush=True)
            code = 1
    print('::endgroup::', flush=True)
    return code if code >= 0 else 128 - code


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        print('This watchdog runs only on GitHub Actions. It must not run alongside live sessions.',
              file=sys.stderr)
        return 2
    live = subprocess.run(['pgrep', '-x', 'Watercoded'], capture_output=True, check=False)
    if live.returncode != 1:
        print('Refusing to run: Watercoded is active or its process check failed.', file=sys.stderr)
        return 2
    DIAGNOSTICS.mkdir(parents=True, exist_ok=True)
    test = ['swift', 'test', '--package-path', PACKAGE, '--skip-build']
    phases = [
        ('build-tests', 300, ['swift', 'build', '--package-path', PACKAGE, '--build-tests']),
        ('non-ui-tests', 120, test + ['--skip', 'WatercodedUITests']),
        ('ui-logic-tests', 60, test + ['--filter', 'WatercodedUITests', '--skip',
                                     'DiffRenderingTests|TranscriptNavigationTests|ToolExpansionTests']),
        ('tool-expansion-tests', 90, test + ['--filter', 'WatercodedUITests.ToolExpansionTests']),
        ('diff-rendering-tests', 45, test + ['--filter', 'WatercodedUITests.DiffRenderingTests']),
        ('transcript-navigation-tests', 45,
         test + ['--filter', 'WatercodedUITests.TranscriptNavigationTests']),
    ]
    for label, seconds, arguments in phases:
        code = run_phase(label, seconds, arguments)
        if code:
            return code
    return 0


if __name__ == '__main__':
    sys.exit(main())
