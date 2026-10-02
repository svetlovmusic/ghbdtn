"""Exercise CI credential validation with fake tools; never touch real Keychain."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'tools' / 'ci-signing.sh'
AUTH_KEYS = ('SIGNING_P12_BASE64', 'SIGNING_P12_PASSWORD', 'NOTARY_KEY_P8',
             'NOTARY_KEY_ID', 'NOTARY_ISSUER_ID', 'APPLE_ID', 'APPLE_APP_PASSWORD')


class CISigningTests(unittest.TestCase):
    def run_import(self, overrides=None, failure=''):
        with tempfile.TemporaryDirectory(prefix='ghbdtn CI signing ') as directory:
            root = Path(directory)
            mock_bin = root / 'bin'
            mock_bin.mkdir()
            trace = root / 'calls.jsonl'
            mock = '''#!/usr/bin/env python3
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
with open(os.environ['TRACE'], 'a') as stream:
    stream.write(json.dumps([tool] + sys.argv[1:]) + '\\n')
if tool == 'openssl':
    print('fake-keychain-password')
elif tool == 'security' and os.environ['FAILURE'] == 'security':
    sys.exit(42)
elif tool == 'xcrun':
    operation = sys.argv[2]
    if os.environ['FAILURE'] == operation:
        sys.exit(17)
    if operation == 'store-credentials':
        if '--key' in sys.argv:
            assert pathlib.Path(sys.argv[sys.argv.index('--key') + 1]).read_text() == 'fake-api-key'
    elif operation == 'history':
        print('{"history": []}')
    else:
        sys.exit(99)
'''
            for name in ('security', 'openssl', 'xcrun'):
                path = mock_bin / name
                path.write_text(mock)
                path.chmod(0o700)
            env = dict(os.environ)
            for key in AUTH_KEYS:
                env.pop(key, None)
            env.update(PATH=f'{mock_bin}:{os.environ["PATH"]}',
                       RUNNER_TEMP=str(root), TRACE=str(trace), FAILURE=failure,
                       SIGNING_P12_BASE64='ZHVtbXk=', SIGNING_P12_PASSWORD='fake-p12-password',
                       NOTARY_KEYCHAIN=str(root / 'signing.keychain-db'), NOTARY_PROFILE='test-profile',
                       APPLE_ID='test@example.invalid', APPLE_APP_PASSWORD='fake-app-password')
            for key, value in (overrides or {}).items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = value
            result = subprocess.run(['/bin/bash', str(SCRIPT)], env=env,
                                    capture_output=True, text=True)
            calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            leftovers = [name for name in ('ghbdtn-signing.p12', 'ghbdtn-notary.p8')
                         if (root / name).exists()]
            return result, calls, leftovers

    def test_missing_or_empty_values_fail_before_any_keychain_operation(self):
        for key in ('RUNNER_TEMP', 'SIGNING_P12_BASE64', 'SIGNING_P12_PASSWORD',
                    'NOTARY_KEYCHAIN', 'NOTARY_PROFILE', 'APPLE_ID', 'APPLE_APP_PASSWORD'):
            for value in (None, ''):
                with self.subTest(key=key, value=value):
                    result, calls, leftovers = self.run_import({key: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f'Missing {key}', result.stderr)
                    self.assertEqual(calls, [])
                    self.assertEqual(leftovers, [])

    def test_api_key_requires_key_id_before_import(self):
        result, calls, leftovers = self.run_import({'NOTARY_KEY_P8': 'fake-api-key'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing NOTARY_KEY_ID', result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(leftovers, [])

    def test_apple_id_profile_is_verified_in_the_same_keychain(self):
        result, calls, leftovers = self.run_import()
        self.assertEqual(result.returncode, 0, result.stderr)
        notary = [call for call in calls if call[0] == 'xcrun']
        self.assertEqual([call[1:3] for call in notary],
                         [['notarytool', 'store-credentials'], ['notarytool', 'history']])
        self.assertEqual(notary[0][3], 'test-profile')
        self.assertEqual(notary[1][notary[1].index('--keychain-profile') + 1], 'test-profile')
        self.assertEqual(notary[0][notary[0].index('--keychain') + 1],
                         notary[1][notary[1].index('--keychain') + 1])
        self.assertNotIn('history', result.stdout)
        self.assertEqual(leftovers, [])

    def test_api_key_auth_supports_individual_and_team_keys(self):
        for issuer in (None, 'fake-issuer'):
            with self.subTest(issuer=issuer):
                result, calls, leftovers = self.run_import({
                    'NOTARY_KEY_P8': 'fake-api-key', 'NOTARY_KEY_ID': 'fake-key-id',
                    'NOTARY_ISSUER_ID': issuer, 'APPLE_ID': None, 'APPLE_APP_PASSWORD': None})
                self.assertEqual(result.returncode, 0, result.stderr)
                store = next(call for call in calls if call[:3] == ['xcrun', 'notarytool', 'store-credentials'])
                self.assertEqual('--issuer' in store, issuer is not None)
                self.assertNotIn('--apple-id', store)
                self.assertEqual(leftovers, [])

    def test_tool_failures_remain_failures_and_remove_temporary_secrets(self):
        for operation, code in (('security', 42), ('store-credentials', 17), ('history', 17)):
            with self.subTest(operation=operation):
                result, calls, leftovers = self.run_import(failure=operation)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(leftovers, [])
                self.assertNotIn('imported and validated', result.stdout)
                if operation == 'store-credentials':
                    self.assertFalse(any(call[:3] == ['xcrun', 'notarytool', 'history'] for call in calls))


if __name__ == '__main__':
    unittest.main()
