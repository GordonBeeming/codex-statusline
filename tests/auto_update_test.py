import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("auto_update", Path(__file__).parents[1] / "scripts/auto-update.py")
auto_update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auto_update)


class ScheduleTests(unittest.TestCase):
    def test_enable_writes_background_schedule_and_disable_removes_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            def launchctl(arguments, **kwargs):
                return subprocess.CompletedProcess(arguments, 1 if arguments[1] == "print" else 0)
            with patch.object(auto_update.Path, "home", return_value=home), \
                 patch.object(auto_update.platform, "system", return_value="Darwin"), \
                 patch.object(auto_update.platform, "machine", return_value="arm64"), \
                 patch.dict(auto_update.os.environ, {"CODEX_STATUSLINE_SHARE_ROOT": str(home / "share"), "CODEX_STATUSLINE_BIN_DIR": str(home / "bin")}), \
                 patch.object(auto_update.subprocess, "run", side_effect=launchctl) as run, \
                 patch.object(auto_update.sys, "argv", ["auto-update.py", "enable"]):
                auto_update.main()
                agent = home / "Library/LaunchAgents" / f"{auto_update.LABEL}.plist"
                config = plistlib.loads(agent.read_bytes())
                self.assertEqual(config["StartInterval"], 21600)
                self.assertTrue(config["RunAtLoad"])
                self.assertTrue((home / "share/update.py").is_file())
                self.assertEqual(run.call_args.args[0][1], "bootstrap")
                with patch.object(auto_update.sys, "argv", ["auto-update.py", "disable"]):
                    auto_update.main()
                self.assertFalse(agent.exists())


if __name__ == "__main__":
    unittest.main()
