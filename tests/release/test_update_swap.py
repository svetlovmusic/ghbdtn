"""Exercise the shipped rename/rollback script using disposable app directories."""
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'Sources/Ghbdtn/Support/UpdateChecker.swift'


class UpdateSwapTests(unittest.TestCase):
    def run_swap(self, replacement=True):
        with tempfile.TemporaryDirectory() as directory:
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
            # Never launch an app in a unit test. Keep all rename/rollback logic intact.
            script = script.replace('/usr/bin/open', '/usr/bin/true')
            path = work / 'swap.sh'
            path.write_text(script)
            result = subprocess.run(['/bin/bash', str(path), '99999999', str(staged), str(dest), str(work)],
                                    capture_output=True, text=True)
            return result.returncode, (dest / 'marker').read_text(), work.exists()

    def test_success_installs_and_cleans_up(self):
        self.assertEqual(self.run_swap(), (0, 'new', False))

    def test_failed_replacement_restores_original(self):
        code, marker, _ = self.run_swap(replacement=False)
        self.assertNotEqual(code, 0)
        self.assertEqual(marker, 'old')


if __name__ == '__main__':
    unittest.main()
