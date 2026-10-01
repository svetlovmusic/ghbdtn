"""Failure-path tests: only Accepted submissions may be stapled and distributed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools' / 'notarize.sh'


class NotarizationTests(unittest.TestCase):
    def run_notary(self, status='Accepted', submit_exit=0, staple_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / 'release.dmg'
            artifact.touch()
            trace = root / 'calls'
            xcrun = root / 'xcrun'
            xcrun.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TRACE'], 'a') as f: f.write(' '.join(sys.argv[1:3]) + '\\n')
if sys.argv[1:3] == ['notarytool', 'submit']:
    print(json.dumps({'status': os.environ['STATUS'], 'id': 'test-submission'}))
    sys.exit(int(os.environ['SUBMIT_EXIT']))
if sys.argv[1:3] == ['stapler', 'staple']:
    sys.exit(int(os.environ['STAPLE_EXIT']))
''')
            xcrun.chmod(0o700)
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       NOTARY_PROFILE='test', TRACE=str(trace), STATUS=status,
                       SUBMIT_EXIT=str(submit_exit), STAPLE_EXIT=str(staple_exit))
            result = subprocess.run([str(SCRIPT), str(artifact), str(root / 'log')],
                                    env=env, capture_output=True, text=True)
            return result.returncode, trace.read_text()

    def test_accepted_is_stapled_and_validated(self):
        code, trace = self.run_notary()
        self.assertEqual(code, 0)
        self.assertIn('stapler staple', trace)
        self.assertIn('stapler validate', trace)

    def test_rejected_never_staples(self):
        code, trace = self.run_notary('Invalid')
        self.assertNotEqual(code, 0)
        self.assertNotIn('stapler', trace)
        self.assertIn('notarytool log', trace)

    def test_timeout_never_staples(self):
        code, trace = self.run_notary('In Progress', 1)
        self.assertNotEqual(code, 0)
        self.assertNotIn('stapler', trace)

    def test_tool_failure_even_with_accepted_output(self):
        code, trace = self.run_notary('Accepted', 1)
        self.assertNotEqual(code, 0)
        self.assertNotIn('stapler', trace)

    def test_stapling_failure_stops_pipeline(self):
        code, trace = self.run_notary(staple_exit=1)
        self.assertNotEqual(code, 0)
        self.assertNotIn('stapler validate', trace)


if __name__ == '__main__':
    unittest.main()
