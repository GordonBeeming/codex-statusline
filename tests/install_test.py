import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class InstallerTests(unittest.TestCase):
    def test_freshness_warning_still_configures_and_enables_updates(self):
        self.assert_install_status(75, ["update.py", "configure.py", "auto-update.py"])

    def test_failed_package_install_stops_setup(self):
        self.assert_install_status(1, ["update.py"])

    def test_argument_or_python_version_error_does_not_continue_setup(self):
        self.assert_install_status(2, ["update.py"])

    def test_current_package_finishes_setup(self):
        self.assert_install_status(0, ["update.py", "configure.py", "auto-update.py"])

    def assert_install_status(self, updater_status, expected):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            wrapper = root / "python"
            calls = root / "calls.json"
            wrapper.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
calls = Path(os.environ['INSTALL_CALLS'])
steps = json.loads(calls.read_text()) if calls.exists() else []
name = Path(sys.argv[1]).name
calls.write_text(json.dumps(steps + [name]))
sys.exit(int(os.environ['UPDATER_STATUS']) if name == 'update.py' else 0)
""")
            wrapper.chmod(0o755)
            result = subprocess.run(
                ["bash", str(Path(__file__).parents[1] / "install.sh"), "--auto-update"],
                env={**os.environ, "CODEX_STATUSLINE_PYTHON": str(wrapper),
                     "CODEX_STATUSLINE_SHARE_ROOT": str(root / "share"),
                     "INSTALL_CALLS": str(calls), "UPDATER_STATUS": str(updater_status)},
                capture_output=True, text=True,
            )
            self.assertEqual(json.loads(calls.read_text()), expected, result.stderr)
            self.assertEqual(result.returncode, 0 if updater_status in (0, 75) else updater_status, result.stderr)
