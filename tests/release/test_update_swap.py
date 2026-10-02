"""Exercise the shipped rename/rollback script using disposable app directories."""
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'Sources/Ghbdtn/Support/UpdateChecker.swift'


class UpdateSwapTests(unittest.TestCase):
    def run_swap(self, replacement=True, fail_open=False, fail_restore=False):
        with tempfile.TemporaryDirectory(prefix='ghbdtn swap test ') as directory:
            root = Path(directory)
            work = root / 'work'
            work.mkdir()
            dest = root / 'ghbdtn.app'
            dest.mkdir()
            (dest / 'marker').write_text('old')
            staged = work / 'ghbdtn.app'
            if replacement:
                staged.mkdir()
                (staged / 'marker').write_text('new')
            script = re.search(r'let script = """\n(.*?)\n        """', SOURCE.read_text(), re.S)[1]
            script = textwrap.dedent(script)
            # Simulate Launch Services refusing only the new app. Record that
            # recovery reopens the old app, without launching any real app.
            opener = root / 'open'
            opener.write_text('''#!/bin/bash
marker=$(/bin/cat "$1/marker")
echo "$marker" >> "$(/usr/bin/dirname "$1")/opened"
''' + ('[ "$marker" = old ]\n' if fail_open else 'exit 0\n'))
            opener.chmod(0o700)
            script = script.replace('/usr/bin/open', '"' + str(opener) + '"')
            if fail_restore:
                script = script.replace('/bin/mv "$1/previous.app" "$2"', '/usr/bin/false')
            path = work / 'swap.sh'
            path.write_text(script)
            result = subprocess.run(['/bin/bash', str(path), '99999999', str(staged), str(dest), str(work)],
                                    capture_output=True, text=True)
            marker = (dest / 'marker').read_text() if dest.exists() else None
            opened = (root / 'opened').read_text().splitlines() if (root / 'opened').exists() else []
            backup = (work / 'previous.app' / 'marker')
            return result.returncode, marker, work.exists(), opened, backup.read_text() if backup.exists() else None

    def test_success_installs_and_cleans_up(self):
        self.assertEqual(self.run_swap(), (0, 'new', False, ['new'], None))

    def test_failed_replacement_restores_original(self):
        code, marker, work, opened, _ = self.run_swap(replacement=False)
        self.assertNotEqual(code, 0)
        self.assertEqual(marker, 'old')
        self.assertFalse(work)
        self.assertEqual(opened, ['old'])

    def test_failed_launch_restores_and_reopens_original(self):
        code, marker, work, opened, _ = self.run_swap(fail_open=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(marker, 'old')
        self.assertFalse(work)
        self.assertEqual(opened, ['new', 'old'])

    def test_failed_recovery_preserves_backup(self):
        code, _, work, _, backup = self.run_swap(fail_open=True, fail_restore=True)
        self.assertNotEqual(code, 0)
        self.assertTrue(work)
        self.assertEqual(backup, 'old')


if __name__ == '__main__':
    unittest.main()
