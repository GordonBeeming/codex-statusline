import hashlib
import importlib.util
import io
import json
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("updater", Path(__file__).parents[1] / "scripts/update.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.share = self.root / "share"
        self.share.mkdir()
        self.old = self.share / "releases/old"
        self.old.mkdir(parents=True)
        (self.share / "current").symlink_to(self.old)
        self.archive = self.root / "package.tar.gz"
        self.manifest = {
            "version": "0.159.3+statusline.3.abcdef123456",
            "cli_version": "0.159.3-statusline.3",
            "platform": updater.PLATFORM,
            "tag": "v0.159.3+statusline.3.abcdef123456",
        }

    def package(self, version="0.159.3-statusline.3", extra=None):
        files = {
            "bin/codex": f"#!/bin/sh\nprintf 'codex-cli {version}\\n'\n".encode(),
            "renderer/statusline.sh": b"#!/bin/sh\ncat >/dev/null\n",
            "updater/update.py": b"print('packaged updater')\n",
        }
        with tarfile.open(self.archive, "w:gz") as archive:
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o755
                archive.addfile(member, io.BytesIO(data))
            if extra:
                archive.addfile(extra)
        self.manifest["sha256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def install(self):
        updater.install_archive(self.archive, self.manifest, self.share, self.root / "bin")

    def test_success_switches_current_and_keeps_previous(self):
        self.package()
        self.install()
        self.assertEqual((self.share / "previous").resolve(), self.old)
        self.assertEqual((self.share / "current").resolve().name, self.manifest["version"])
        self.assertTrue((self.root / "bin/codex-statusline").is_file())
        self.assertEqual((self.share / "update.py").read_bytes(), b"print('packaged updater')\n")

    def test_downgrade_is_rejected_before_archive_download(self):
        self.assert_downgrade_rejected("0.160.0-statusline.3")

    def test_same_upstream_patch_downgrade_is_rejected(self):
        self.assert_downgrade_rejected("0.159.3-statusline.4")

    def assert_downgrade_rejected(self, installed_version):
        self.package()
        (self.old / "statusline-release.json").write_text(json.dumps({"cli_version": installed_version}))
        release = {"tag_name": self.manifest["tag"], "assets": [{
            "name": f"{updater.PLATFORM}.json", "browser_download_url": "manifest",
        }]}
        def download_manifest(url, path):
            self.assertEqual(url, "manifest")
            path.write_text(json.dumps(self.manifest))
        with patch.object(updater.platform, "system", return_value="Darwin"), \
             patch.object(updater.platform, "machine", return_value="arm64"), \
             patch.object(updater.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(release).encode())), \
             patch.object(updater, "download", side_effect=download_manifest) as download:
            with self.assertRaisesRegex(ValueError, "downgrade"):
                updater.update(self.share, self.root / "bin")
        self.assertEqual(download.call_count, 1)
        self.assertEqual((self.share / "current").resolve(), self.old)

    def test_checksum_failure_preserves_current(self):
        self.package()
        self.manifest["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.install()
        self.assertEqual((self.share / "current").resolve(), self.old)

    def test_wrong_binary_preserves_current(self):
        self.package(version="0.1.0")
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            self.install()
        self.assertEqual((self.share / "current").resolve(), self.old)

    def test_archive_traversal_preserves_current(self):
        self.package(extra=tarfile.TarInfo("../../escape"))
        with self.assertRaisesRegex(ValueError, "Unsafe archive"):
            self.install()
        self.assertEqual((self.share / "current").resolve(), self.old)
        self.assertFalse((self.root / "escape").exists())

    def test_external_symlink_rejected(self):
        member = tarfile.TarInfo("external")
        member.type = tarfile.SYMTYPE
        member.linkname = "/tmp"
        self.package(extra=member)
        with self.assertRaisesRegex(ValueError, "Unsafe archive symlink"):
            self.install()

    def test_interrupted_activation_can_be_retried(self):
        self.package()
        with patch.object(updater, "activate", side_effect=OSError("interrupted")):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.install()
        self.assertEqual((self.share / "current").resolve(), self.old)
        self.install()
        self.assertEqual((self.share / "current").resolve().name, self.manifest["version"])

    def test_corrupt_release_metadata_can_be_repaired(self):
        self.package()
        self.install()
        (self.share / "current/statusline-release.json").write_text("broken json")
        self.install()
        self.assertEqual(updater.installed_manifest(self.share / "current/statusline-release.json"), self.manifest)
        self.assertEqual((self.share / "previous").resolve(), self.old)

    def test_repairing_the_active_release_keeps_the_last_working_rollback(self):
        self.package()
        self.install()
        for attempt in range(2):
            (self.share / "current/bin/codex").unlink()
            self.install()
            self.assertTrue((self.share / "current/bin/codex").is_file())
            self.assertEqual((self.share / "previous").resolve(), self.old)

    def test_damaged_orphan_package_is_repaired(self):
        self.package()
        with patch.object(updater, "activate", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.install()
        (self.share / "releases" / self.manifest["version"] / "bin/codex").unlink()
        self.install()
        self.assertTrue((self.share / "current/bin/codex").is_file())

    def test_non_object_manifest_rejected(self):
        self.package()
        with self.assertRaisesRegex(ValueError, "must be an object"):
            updater.install_archive(self.archive, [], self.share, self.root / "bin")

    def test_validation_uses_a_complete_payload_for_the_real_renderer(self):
        self.package()
        package = self.root / "real-renderer"
        package.mkdir()
        updater.extract(self.archive, package)
        shutil.copy2(Path(__file__).parents[1] / "renderer/statusline.sh", package / "renderer/statusline.sh")
        updater.validate_package(package, self.manifest["cli_version"])

    def test_up_to_date_skips_archive_download(self):
        self.package()
        self.install()
        (self.root / "bin/codex-statusline").unlink()
        release = {"tag_name": self.manifest["tag"], "assets": [{
            "name": f"{updater.PLATFORM}.json",
            "browser_download_url": "manifest",
        }]}
        def download_manifest(url, path):
            self.assertEqual(url, "manifest")
            path.write_text(json.dumps(self.manifest))
        with patch.object(updater.platform, "system", return_value="Darwin"), \
             patch.object(updater.platform, "machine", return_value="arm64"), \
             patch.object(updater.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(release).encode())), \
             patch.object(updater, "download", side_effect=download_manifest) as download:
            updater.update(self.share, self.root / "bin")
        self.assertEqual(download.call_count, 1)
        self.assertTrue((self.root / "bin/codex-statusline").is_file())


if __name__ == "__main__":
    unittest.main()
