"""Failure-path tests: only Accepted submissions may be stapled and distributed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools' / 'notarize.sh'


class NotarizationTests(unittest.TestCase):
    submission_id = '7b3b584e-5d6d-43af-9970-46825957e973'

    def run_notary(self, status='Accepted', submit_exit=0, wait_exit=0,
                   staple_exit=0, wait_stream='stdout', submit_response=None,
                   wait_response=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / 'release.dmg'
            artifact.touch()
            trace = root / 'calls'
            xcrun = root / 'xcrun'
            xcrun.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ['TRACE'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['notarytool', 'submit']:
    print(os.environ['SUBMIT_RESPONSE'])
    sys.exit(int(os.environ['SUBMIT_EXIT']))
if sys.argv[1:3] == ['notarytool', 'wait']:
    # The real timeout may print JSON only on stderr. The ID must already be
    # durable before wait starts, not reconstructed from that unreliable output.
    log = pathlib.Path(os.environ['LOG_DIR'])
    assert json.loads((log / 'submission.json').read_text())['id'] == sys.argv[3]
    assert (log / 'submission-id.txt').read_text().strip() == sys.argv[3]
    stream = sys.stderr if os.environ['WAIT_STREAM'] == 'stderr' else sys.stdout
    print(os.environ['WAIT_RESPONSE'], file=stream)
    sys.exit(int(os.environ['WAIT_EXIT']))
if sys.argv[1:3] == ['stapler', 'staple']:
    sys.exit(int(os.environ['STAPLE_EXIT']))
''')
            xcrun.chmod(0o700)
            log = root / 'log'
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       NOTARY_PROFILE='test', TRACE=str(trace), LOG_DIR=str(log),
                       SUBMIT_EXIT=str(submit_exit), WAIT_EXIT=str(wait_exit),
                       STAPLE_EXIT=str(staple_exit), WAIT_STREAM=wait_stream,
                       SUBMIT_RESPONSE=submit_response if submit_response is not None else
                           json.dumps({'id': self.submission_id}),
                       WAIT_RESPONSE=wait_response if wait_response is not None else
                           json.dumps({'status': status, 'id': self.submission_id}))
            result = subprocess.run([str(SCRIPT), str(artifact), str(log)],
                                    env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in trace.read_text().splitlines()]
            files = {p.name: p.read_text() for p in log.iterdir() if p.is_file()}
            return result, calls, files

    def assert_not_stapled(self, calls):
        self.assertFalse(any(call[0] == 'stapler' for call in calls))
        self.assertEqual(sum(call[:2] == ['notarytool', 'submit'] for call in calls), 1)

    def test_accepted_is_stapled_and_validated(self):
        result, calls, files = self.run_notary()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[:2] for call in calls], [
            ['notarytool', 'submit'], ['notarytool', 'wait'],
            ['stapler', 'staple'], ['stapler', 'validate']])
        self.assertNotIn('--wait', calls[0])
        self.assertEqual(calls[1][2], self.submission_id)
        self.assertIn('--timeout', calls[1])
        self.assertEqual(files['submission-id.txt'].strip(), self.submission_id)

    def test_rejected_never_staples(self):
        result, calls, _ = self.run_notary('Invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assert_not_stapled(calls)
        self.assertIn(['notarytool', 'log'], [call[:2] for call in calls])

    def test_timeout_json_on_stderr_preserves_submission(self):
        result, calls, files = self.run_notary('In Progress', wait_exit=1,
                                             wait_stream='stderr')
        self.assertNotEqual(result.returncode, 0)
        self.assert_not_stapled(calls)
        self.assertEqual(files['wait.json'], '')
        self.assertEqual(json.loads(files['wait.stderr.log'])['status'], 'In Progress')
        self.assertEqual(json.loads(files['submission.json'])['id'], self.submission_id)
        self.assertEqual(files['submission-id.txt'].strip(), self.submission_id)
        self.assertIn(self.submission_id, result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_empty_wait_output_preserves_submission(self):
        result, calls, files = self.run_notary(wait_exit=1, wait_response='')
        self.assertNotEqual(result.returncode, 0)
        self.assert_not_stapled(calls)
        self.assertEqual(files['submission-id.txt'].strip(), self.submission_id)
        self.assertIn('no valid status', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_wait_requires_valid_accepted_status_even_with_exit_zero(self):
        for response in ('', 'not JSON', '[]', '{"status": true}'):
            with self.subTest(response=response):
                result, calls, _ = self.run_notary(wait_response=response)
                self.assertNotEqual(result.returncode, 0)
                self.assert_not_stapled(calls)
                self.assertNotIn('Traceback', result.stderr)

    def test_malformed_submit_response_never_waits_or_staples(self):
        for response in ('', 'not JSON', '[]', '{}', '{"id": null}'):
            with self.subTest(response=response):
                result, calls, files = self.run_notary(submit_response=response)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual([call[:2] for call in calls], [['notarytool', 'submit']])
                self.assertNotIn('submission-id.txt', files)
                self.assertIn('no valid submission ID', result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_tool_failure_even_with_accepted_output(self):
        result, calls, _ = self.run_notary('Accepted', wait_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assert_not_stapled(calls)

    def test_submit_failure_stops_before_wait_and_preserves_known_id(self):
        result, calls, files = self.run_notary(submit_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[:2] for call in calls], [['notarytool', 'submit']])
        self.assertEqual(files['submission-id.txt'].strip(), self.submission_id)

    def test_stapling_failure_stops_pipeline(self):
        result, calls, _ = self.run_notary(staple_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(['stapler', 'validate'], [call[:2] for call in calls])


if __name__ == '__main__':
    unittest.main()
