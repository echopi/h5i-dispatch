"""Offline dispatch regression tests using synthetic HOME state and worker spies.

The h5i adapter filters INSTRUCTION/CODEX_BIN for agent-codex, matching the
observed h5i 0.3.3 contract. No models or real credentials are used.
Run: python3 -m unittest discover -s scripts/tests -v
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'dispatch.sh'

H5I = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
root = pathlib.Path.cwd()
if args == ['--version']:
    print('h5i 0.3.3')
    sys.exit(0)
with (root / 'events.jsonl').open('a') as out:
    out.write(json.dumps(args[:3]) + '\n')
if args[:2] == ['box', '--name']:
    work = root / '.git/.h5i/env/human' / args[2] / 'work'
    work.mkdir(parents=True)
    (root / 'kind').write_text(args[args.index('--profile') + 1])
    sys.exit(0)
if args[:2] == ['box', 'run']:
    work = root / '.git/.h5i/env/human' / args[2] / 'work'
    allowed = ['PATH', 'HOME']
    if (root / 'kind').read_text() != 'agent-codex':
        allowed += ['INSTRUCTION', 'QODER_BIN', 'PI_BIN', 'DISPATCH_PROXY', 'PROXY_PORT']
    env = {k: v for k, v in os.environ.items() if k in allowed}
    with (root / 'commands.jsonl').open('a') as out:
        out.write(json.dumps(args[4:]) + '\n')
    sys.exit(subprocess.call(args[4:], cwd=work, env=env))
if args[:2] == ['box', 'export']:
    work = root / '.git/.h5i/env/human' / args[2] / 'work'
    leftovers = list(work.glob('.dispatch-*.md'))
    assert not leftovers, leftovers
    assert not (work / 'qhome').exists()
    assert not (work / 'phome').exists()
    out = root / 'h5i-export' / args[2]
    out.mkdir(parents=True)
    (out / 'patch.diff').write_text('')
    sys.exit(0)
if args[:2] == ['box', 'rm']:
    sys.exit(8 if (root / 'rm-fails').exists() else 0)
raise SystemExit('unexpected h5i command: ' + repr(args))
'''

WORKER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
work = pathlib.Path.cwd()
root = work.parents[5]
args = sys.argv[1:]
if '-p' in args:
    prompt = args[args.index('-p') + 1]
else:
    prompt = sys.stdin.read() if args[-1:] == ['-'] else args[-1]
with (root / 'worker.jsonl').open('a') as out:
    out.write(json.dumps({'args': args, 'prompt': prompt, 'home': os.environ['HOME']}) + '\n')
if prompt.strip() == 'Reply with exactly: ok':
    status = root / 'probe-exit'
    print('ok')
    sys.exit(int(status.read_text()) if status.exists() else 0)
if '.dispatch-task.md' not in prompt:
    print('missing task instruction', file=sys.stderr)
    sys.exit(42)
(work / 'result.txt').write_text((work / '.dispatch-task.md').read_text())
'''


class DispatchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dispatch regression ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=Test',
                        '-c', 'user.email=test@localhost', 'commit', '--allow-empty',
                        '--no-verify', '-qm', 'fixture'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.bin = self.root / 'worker tools'
        self.bin.mkdir()
        for name, body in [('h5i', H5I), ('codex', WORKER),
                           ('custom-codex', WORKER), ('qodercli', WORKER), ('pi', WORKER)]:
            path = self.bin / name
            path.write_text(body)
            path.chmod(0o755)
        self.home = self.root / 'synthetic-home'
        for name in ('.qoder', '.pi'):
            state = self.home / name
            state.mkdir(parents=True)
            (state / 'fixture.txt').write_text('synthetic state only\n')
        self.task = self.root / 'task.md'
        self.task.write_text('Only write result.txt. Task body: $(touch BAD) `id`\n')

    def dispatch(self, kind='codex', preflight='1', custom=False, expected=0, keep=False):
        env = dict(PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                   HOME=str(self.home), H5I_BIN=str(self.bin / 'h5i'),
                   QODER_BIN=str(self.bin / 'qodercli'), PI_BIN=str(self.bin / 'pi'),
                   DISPATCH_PREFLIGHT=preflight, WORKER_TIMEOUT='15',
                   DISPATCH_KEEP_BOX='1' if keep else '0',
                   CODEX_BIN=str(self.bin / 'custom-codex') if custom else '')
        result = subprocess.run(['bash', str(SCRIPT), kind, 'test-box', str(self.task)],
                                cwd=self.root, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, expected, result.stdout)
        work = self.root / '.git/.h5i/env/human/test-box/work'
        self.assertTrue((self.root / 'worker.jsonl').is_file(), result.stdout)
        calls = [json.loads(line) for line in (self.root / 'worker.jsonl').read_text().splitlines()]
        events = [json.loads(line) for line in (self.root / 'events.jsonl').read_text().splitlines()]
        if expected == 0:
            self.assertEqual((work / 'result.txt').read_text(), self.task.read_text())
            self.assertEqual(len(calls), 2 if preflight == '1' else 1)
            self.assertIn('.dispatch-task.md', calls[-1]['prompt'])
            self.assertTrue(any(event[:2] == ['box', 'export'] for event in events))
        else:
            self.assertEqual(len(calls), 1)
            self.assertFalse((work / 'result.txt').exists())
            self.assertFalse(any(event[:2] == ['box', 'export'] for event in events))
            self.assertEqual(sum(event[:2] == ['box', 'rm'] for event in events),
                             0 if keep else 1)
            self.assertNotIn('preflight ok', result.stdout)
        if preflight == '1':
            self.assertEqual(calls[0]['prompt'].strip(), 'Reply with exactly: ok')
        if kind in ('qoder', 'pi'):
            home_dir = 'qhome' if kind == 'qoder' else 'phome'
            self.assertEqual(calls[0]['home'], str(work / home_dir))
        for call in calls:
            self.assertNotIn('Task body:', json.dumps(call['args']))
        self.assertNotIn('Task body:', (self.root / 'commands.jsonl').read_text())
        self.assertFalse((work / 'BAD').exists())
        return result

    def test_codex_default_preflight_and_task_survive_filter(self):
        self.dispatch()

    def test_codex_task_survives_filter_without_preflight(self):
        self.dispatch(preflight='0')

    def test_custom_codex_binary_survives_filter(self):
        (self.bin / 'codex').write_text('#!/bin/sh\nexit 43\n')
        self.dispatch(custom=True)

    def test_qoder_preflight_and_task(self):
        self.dispatch(kind='qoder')

    def test_pi_preflight_and_task(self):
        self.dispatch(kind='pi')

    def test_failed_preflight_aborts_each_worker(self):
        for kind in ('codex', 'qoder', 'pi'):
            with self.subTest(kind=kind):
                case = DispatchTest()
                case.setUp()
                self.addCleanup(case.doCleanups)
                (case.root / 'probe-exit').write_text('9')
                case.dispatch(kind=kind, expected=3)

    def test_cleanup_failure_is_reported_without_claiming_removal(self):
        (self.root / 'probe-exit').write_text('9')
        (self.root / 'rm-fails').touch()
        result = self.dispatch(expected=3)
        self.assertIn('cleanup failed', result.stdout)
        self.assertIn('keeping box', result.stdout)
        self.assertNotIn('box cleaned', result.stdout)

    def test_failed_preflight_respects_keep_box(self):
        (self.root / 'probe-exit').write_text('9')
        self.dispatch(expected=3, keep=True)


if __name__ == '__main__':
    unittest.main()
