import hashlib
import importlib.util
import contextlib
import io
import json
import shutil
import tarfile
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("updater", Path(__file__).parents[1] / "scripts/update.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        freshness = patch.object(updater, "latest_upstream_version", return_value=(0, 159, 3))
        freshness.start()
        self.addCleanup(freshness.stop)
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

    def test_stale_public_package_is_reported_instead_of_already_current(self):
        self.package()
        self.install()
        release = {"tag_name": self.manifest["tag"], "assets": [{
            "name": f"{updater.PLATFORM}.json", "browser_download_url": "manifest",
        }]}
        def download_manifest(url, path):
            path.write_text(json.dumps(self.manifest))
        with patch.object(updater.platform, "system", return_value="Darwin"), \
             patch.object(updater.platform, "machine", return_value="arm64"), \
             patch.object(updater.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(release).encode())), \
             patch.object(updater, "download", side_effect=download_manifest), \
             patch.object(updater, "latest_upstream_version", return_value=(0, 169, 0), create=True):
            with self.assertRaisesRegex(ValueError, "0.169.0.*release pipeline"):
                updater.update(self.share, self.root / "bin")
        self.assertEqual(updater.installed_manifest(self.share / "current/statusline-release.json"), self.manifest)

    def test_api_rate_limit_falls_back_to_public_release_downloads(self):
        self.package()
        self.install()
        def download_manifest(url, path):
            self.assertIn("/releases/download/v0.159.3%2Bstatusline.3.abcdef123456/", url)
            path.write_text(json.dumps(self.manifest))
        with patch.object(updater.platform, "system", return_value="Darwin"), \
             patch.object(updater.platform, "machine", return_value="arm64"), \
             patch.object(updater.urllib.request, "urlopen", side_effect=urllib.error.HTTPError(updater.API, 403, "rate limited", {}, None)), \
             patch.object(updater, "latest_tag", return_value=self.manifest["tag"]), \
             patch.object(updater, "download", side_effect=download_manifest):
            updater.update(self.share, self.root / "bin")

    def test_latest_tag_rejects_redirects_outside_the_requested_repository(self):
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value.geturl.return_value = "https://example.com/releases/tag/rust-v0.169.0"
        with patch.object(updater.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(ValueError, "Unexpected latest release URL"):
                updater.latest_tag("openai/codex")

    def test_newer_available_package_installs_even_when_upstream_is_ahead(self):
        self.package()
        release = {"tag_name": self.manifest["tag"], "assets": [
            {"name": f"{updater.PLATFORM}.json", "browser_download_url": "manifest"},
            {"name": f"codex-statusline-{updater.PLATFORM}.tar.gz", "browser_download_url": "archive"},
        ]}
        def download(url, path):
            if url == "manifest":
                path.write_text(json.dumps(self.manifest))
            else:
                shutil.copyfile(self.archive, path)
        with patch.object(updater.platform, "system", return_value="Darwin"), \
             patch.object(updater.platform, "machine", return_value="arm64"), \
             patch.object(updater.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(release).encode())), \
             patch.object(updater, "download", side_effect=download), \
             patch.object(updater, "latest_upstream_version", return_value=(0, 169, 0)):
            with self.assertRaisesRegex(ValueError, "release pipeline"):
                updater.update(self.share, self.root / "bin")
        self.assertEqual(updater.installed_manifest(self.share / "current/statusline-release.json"), self.manifest)
        self.assertEqual((self.share / "previous").resolve(), self.old)

    def test_one_new_upstream_release_has_a_bounded_build_grace_period(self):
        with patch.object(updater, "latest_upstream_version", return_value=(0, 160, 0)), \
             patch.object(updater.time, "time", return_value=100_000):
            self.assertFalse(updater.verify_upstream_freshness(self.manifest, self.share))
        self.assertEqual(json.loads((self.share / "update-health.json").read_text())["status"], "pending")
        with patch.object(updater, "latest_upstream_version", return_value=(0, 160, 0)), \
             patch.object(updater.time, "time", return_value=100_000 + 12 * 3600):
            with self.assertRaisesRegex(ValueError, "release pipeline"):
                updater.verify_upstream_freshness(self.manifest, self.share)
        self.assertEqual(json.loads((self.share / "update-health.json").read_text())["status"], "blocked")
        self.assertTrue(updater.verify_upstream_freshness(self.manifest, self.share))
        self.assertEqual(json.loads((self.share / "update-health.json").read_text())["status"], "current")

    def test_pending_pipeline_does_not_claim_already_current(self):
        self.package()
        self.install()
        release = {"tag_name": self.manifest["tag"], "assets": [{
            "name": f"{updater.PLATFORM}.json", "browser_download_url": "manifest",
        }]}
        def download_manifest(url, path):
            path.write_text(json.dumps(self.manifest))
        output = io.StringIO()
        with patch.object(updater.platform, "system", return_value="Darwin"), \
             patch.object(updater.platform, "machine", return_value="arm64"), \
             patch.object(updater.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(release).encode())), \
             patch.object(updater, "download", side_effect=download_manifest), \
             patch.object(updater, "latest_upstream_version", return_value=(0, 160, 0)), \
             contextlib.redirect_stdout(output):
            updater.update(self.share, self.root / "bin")
        self.assertNotIn("Already current", output.getvalue())
        self.assertEqual(json.loads((self.share / "update-health.json").read_text())["status"], "pending")

    def test_corrupt_health_file_does_not_prevent_detecting_a_large_version_gap(self):
        (self.share / "update-health.json").write_text("broken json")
        with patch.object(updater, "latest_upstream_version", return_value=(0, 169, 0)):
            with self.assertRaisesRegex(ValueError, "release pipeline"):
                updater.verify_upstream_freshness(self.manifest, self.share)
        self.assertEqual(json.loads((self.share / "update-health.json").read_text())["status"], "blocked")

    def test_patch_releases_after_a_minor_bump_do_not_restart_the_grace_period(self):
        with patch.object(updater, "latest_upstream_version", return_value=(0, 160, 0)), \
             patch.object(updater.time, "time", return_value=100_000):
            self.assertFalse(updater.verify_upstream_freshness(self.manifest, self.share))
        with patch.object(updater, "latest_upstream_version", return_value=(0, 160, 1)), \
             patch.object(updater.time, "time", return_value=100_001):
            with self.assertRaisesRegex(ValueError, "release pipeline"):
                updater.verify_upstream_freshness(self.manifest, self.share)

    def test_freshness_network_failure_is_distinct_from_package_failure(self):
        with patch.object(updater, "latest_upstream_version", side_effect=OSError("offline")):
            with self.assertRaisesRegex(updater.FreshnessError, "offline"):
                updater.check_installed_freshness(self.manifest, self.share)
        with patch.object(updater, "latest_upstream_version", side_effect=updater.http.client.IncompleteRead(b"")):
            with self.assertRaises(updater.FreshnessError):
                updater.check_installed_freshness(self.manifest, self.share)
        for error, expected in [(updater.FreshnessError("offline"), 75), (OSError("package failed"), 1)]:
            with patch.object(updater, "update", side_effect=error), \
                 patch.object(updater.sys, "argv", ["update.py"]), \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    updater.main()
            self.assertEqual(result.exception.code, expected)

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
