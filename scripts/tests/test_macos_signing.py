import copy
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import ssl
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("macos_signing", SCRIPTS / "macos_signing.py")
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)
NOW = dt.datetime(2026, 10, 8, 4, tzinfo=signing.UTC)
CERT = b"mock development certificate"
FINGERPRINT = hashlib.sha1(CERT).hexdigest().upper()
DEVICE = "PROVISIONING-UDID"


def profile(days=7):
    return {
        "Platform": ["OSX"], "TeamIdentifier": ["TESTTEAM"],
        "ApplicationIdentifierPrefix": ["TESTTEAM"],
        "CreationDate": (NOW - dt.timedelta(days=1)).replace(tzinfo=None),
        "ExpirationDate": (NOW + dt.timedelta(days=days)).replace(tzinfo=None),
        "ProvisionedDevices": [DEVICE], "DeveloperCertificates": [CERT],
        "Entitlements": {
            "com.apple.application-identifier": "TESTTEAM.co.test.app",
            "com.apple.developer.team-identifier": "TESTTEAM",
        },
    }


class FakeCommands:
    def __init__(self, root):
        self.root = root
        self.calls = []
        self.settings = {
            "DEVELOPMENT_TEAM": "TESTTEAM", "PRODUCT_BUNDLE_IDENTIFIER": "co.test.app",
            "CODE_SIGN_STYLE": "Automatic", "CODE_SIGN_IDENTITY": "Apple Development",
            "CODE_SIGNING_REQUIRED": "YES", "TARGET_BUILD_DIR": str(root / "build/macos/Debug"),
            "FULL_PRODUCT_NAME": "Test App.app",
        }
        self.renew = None
        self.identity_team = "TESTTEAM"
        self.signature_team = "TESTTEAM"
        self.signer = CERT
        self.has_identity = True
        self.fail_codesign = False
        self.platform_only = False

    def run(self, args, stage, **kwargs):
        self.calls.append(list(args))
        stdout, stderr, code = b"", b"", 0
        if "-showBuildSettings" in args:
            stdout = json.dumps([{"target": "Runner", "buildSettings": self.settings}]).encode()
        elif "-allowProvisioningUpdates" in args:
            if self.renew:
                self.renew()
        elif "find-identity" in args:
            stdout = ('1) ' + FINGERPRINT + ' "Apple Development: Test"').encode() if self.has_identity else b""
        elif "find-certificate" in args:
            stdout = ssl.DER_cert_to_PEM_cert(CERT).encode()
        elif "x509" in args:
            stdout = ("subject=\n    OU=" + self.identity_team + "\n").encode()
        elif "SPHardwareDataType" in args:
            hardware = {"platform_UUID": "WRONG-HARDWARE-UUID"}
            if not self.platform_only:
                hardware["provisioning_UDID"] = DEVICE
            stdout = json.dumps({"SPHardwareDataType": [hardware]}).encode()
        elif "cms" in args:
            try:
                stdout = Path(args[-1]).read_bytes()
            except FileNotFoundError:
                code = 1
        elif "--verify" in args:
            if self.fail_codesign:
                raise signing.SigningError("strict signature check failed")
        elif "--verbose=4" in args:
            stderr = ("Identifier=co.test.app\nTeamIdentifier=" + self.signature_team + "\n").encode()
        elif any(arg.startswith("--extract-certificates=") for arg in args):
            prefix = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--extract-certificates="))
            Path(prefix + "0").write_bytes(self.signer)
        else:
            raise AssertionError(args)
        return subprocess.CompletedProcess(args, code, stdout, stderr)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="signing test with spaces ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        for relative in (".dart_tool/package_config.json", "macos/Flutter/ephemeral/Flutter-Generated.xcconfig"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        (self.root / "build/macos/signing").mkdir(parents=True)
        self.commands = FakeCommands(self.root)
        self.check = signing.Preflight(self.root, self.commands, home=self.home,
                                       environment={}, now=lambda: NOW)
        quiet = patch.object(signing, "announce")
        self.announce = quiet.start()
        self.addCleanup(quiet.stop)

    def save(self, data, *, name="test.provisionprofile", legacy=False):
        directory = self.home / ("Library/MobileDevice/Provisioning Profiles" if legacy else
                                 "Library/Developer/Xcode/UserData/Provisioning Profiles")
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        path.write_bytes(data if isinstance(data, bytes) else plistlib.dumps(data))
        return path

    def renewed(self, data=None):
        data = profile() if data is None else data
        self.save(data)
        app = Path(self.commands.settings["TARGET_BUILD_DIR"]) / self.commands.settings["FULL_PRODUCT_NAME"]
        path = app / "Contents/embedded.provisionprofile"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(data))

    def renewal_count(self):
        return sum("-allowProvisioningUpdates" in args for args in self.commands.calls)

    def test_valid_skips_renewal_in_both_locations(self):
        for legacy in (False, True):
            self.save(profile(), legacy=legacy, name="valid.mobileprovision")
        self.check.prepare()
        self.assertEqual(self.renewal_count(), 0)
        self.assertEqual(self.check.device, DEVICE)

    def test_missing_renews_once_and_verifies(self):
        self.commands.renew = self.renewed
        self.check.prepare()
        self.assertEqual(self.renewal_count(), 1)
        self.assertTrue(any("--strict" in args for args in self.commands.calls))

    def test_expired_and_near_expiry_renew_once(self):
        for days in (-1, 0, 0.5, 1):
            with self.subTest(days=days):
                self.commands.calls.clear()
                self.save(profile(days))
                self.commands.renew = self.renewed
                self.check.prepare()
                self.assertEqual(self.renewal_count(), 1)

    def test_unchanged_near_expiry_warns_without_retry(self):
        self.save(profile(0.5))
        self.commands.renew = lambda: self.renewed(profile(0.5))
        self.check.prepare()
        self.assertEqual(self.renewal_count(), 1)
        self.assertTrue(any("仍临近过期" in call.args[0] for call in self.announce.call_args_list))

    def test_corrupt_files_and_multiple_candidates(self):
        self.save(b"not a plist", name="broken.mobileprovision")
        self.save(b"<plist><dict>", name="truncated.provisionprofile")
        self.save(profile(-2), name="old.provisionprofile")
        self.save(profile(0.5), name="near.provisionprofile")
        self.save(profile(7), name="fresh.provisionprofile", legacy=True)
        self.check.prepare()
        self.assertEqual(self.renewal_count(), 0)

    def test_failed_renewal_stops_without_retry(self):
        for reason in ("account login expired", "network unavailable"):
            with self.subTest(reason=reason):
                self.commands.calls.clear()
                def fail():
                    raise signing.SigningError(reason)
                self.commands.renew = fail
                with self.assertRaisesRegex(signing.SigningError, reason):
                    self.check.prepare()
                self.assertEqual(self.renewal_count(), 1)
                self.assertFalse(any("--verify" in args for args in self.commands.calls))

    def test_build_success_without_profile_is_failure(self):
        with self.assertRaisesRegex(signing.SigningError, "仍没有"):
            self.check.prepare()
        self.assertEqual(self.renewal_count(), 1)

    def test_embedded_profile_must_match(self):
        self.commands.renew = lambda: self.save(profile())
        with self.assertRaisesRegex(signing.SigningError, "构建产物"):
            self.check.prepare()

    def test_signature_failure_blocks(self):
        self.commands.renew = self.renewed
        self.commands.fail_codesign = True
        with self.assertRaisesRegex(signing.SigningError, "signature"):
            self.check.prepare()

    def test_actual_team_and_certificate_must_match(self):
        for attribute, value in (("signature_team", "OTHERTEAM"), ("signer", b"other cert")):
            with self.subTest(attribute=attribute):
                self.save(profile(-1))
                self.commands.signature_team = "TESTTEAM"
                self.commands.signer = CERT
                setattr(self.commands, attribute, value)
                self.commands.renew = self.renewed
                with self.assertRaises(signing.SigningError):
                    self.check.prepare()

    def test_missing_or_foreign_identity_blocks_before_renewal(self):
        for has_identity, team in ((False, "TESTTEAM"), (True, "FOREIGN")):
            with self.subTest(team=team, has_identity=has_identity):
                self.commands.has_identity = has_identity
                self.commands.identity_team = team
                with self.assertRaisesRegex(signing.SigningError, "证书"):
                    self.check.prepare()
                self.assertEqual(self.renewal_count(), 0)

    def test_missing_team_or_disabled_signing_blocks(self):
        original = copy.deepcopy(self.commands.settings)
        for key, value in (("DEVELOPMENT_TEAM", ""), ("DEVELOPMENT_TEAM", "YOUR_TEAM_ID"),
                           ("CODE_SIGN_STYLE", "Manual"), ("CODE_SIGN_IDENTITY", "-"),
                           ("CODE_SIGNING_ALLOWED", "NO"), ("CODE_SIGNING_REQUIRED", "NO"),
                           ("PROVISIONING_PROFILE_SPECIFIER", "fixed")):
            with self.subTest(key=key, value=value):
                self.commands.settings = dict(original, **{key: value})
                with self.assertRaises(signing.SigningError):
                    self.check.prepare()
                self.assertEqual(self.renewal_count(), 0)

    def test_missing_dependencies_never_runs_pub(self):
        (self.root / ".dart_tool/package_config.json").unlink()
        with self.assertRaisesRegex(signing.SigningError, "flutter pub get"):
            self.check.prepare()
        self.assertEqual(self.commands.calls, [])

    def test_intel_device_falls_back_to_platform_uuid(self):
        self.commands.platform_only = True
        data = profile()
        data["ProvisionedDevices"] = ["WRONG-HARDWARE-UUID"]
        self.save(data)
        self.check.prepare()
        self.assertEqual(self.renewal_count(), 0)

    def test_environment_forwarded_as_arguments_not_shell_code(self):
        self.check.environment = {"FLUTTER_XCODE_CC": "/compiler with spaces/clang",
                                  "FLUTTER_XCODE_XROS_DEPLOYMENT_TARGET": "", "IGNORED": "secret"}
        self.commands.renew = self.renewed
        self.check.prepare()
        for args in self.commands.calls:
            if "xcodebuild" in args:
                self.assertIn("CC=/compiler with spaces/clang", args)
                self.assertIn("XROS_DEPLOYMENT_TARGET=", args)
                self.assertIn("-disableAutomaticPackageResolution", args)
                self.assertNotIn("-skipPackageSignatureValidation", args)
                self.assertNotIn("secret", " ".join(args))
                self.assertIn(str(self.root / "macos/Runner.xcworkspace"), args)


class ProfileTests(unittest.TestCase):
    def test_foreign_and_invalid_profiles_rejected(self):
        changes = [
            {"TeamIdentifier": ["OTHERTEAM"]}, {"Platform": ["iOS"]},
            {"ProvisionedDevices": ["OTHERDEVICE"]}, {"DeveloperCertificates": [b"wrong"]},
            {"ExpirationDate": NOW.replace(tzinfo=None)}, {"ExpirationDate": "invalid"},
            {"CreationDate": (NOW + dt.timedelta(days=1)).replace(tzinfo=None)},
            {"Entitlements": {"com.apple.application-identifier": "TESTTEAM.co.other.app",
                              "com.apple.developer.team-identifier": "TESTTEAM"}},
        ]
        settings = {"DEVELOPMENT_TEAM": "TESTTEAM", "PRODUCT_BUNDLE_IDENTIFIER": "co.test.app"}
        for change in changes:
            with self.subTest(change=list(change)):
                self.assertFalse(signing.profile_matches(dict(profile(), **change), settings,
                                                         {FINGERPRINT}, DEVICE, NOW))
        self.assertFalse(signing.profile_matches({}, settings, {FINGERPRINT}, DEVICE, NOW))

    def test_only_apple_trailing_wildcards_supported(self):
        self.assertTrue(signing.apple_pattern_matches("TEAM.co.test.*", "TEAM.co.test.app"))
        self.assertFalse(signing.apple_pattern_matches("TEAM.co.test.*", "TEAM.co.testing.app"))
        self.assertFalse(signing.apple_pattern_matches("TEAM.*.app", "TEAM.co.app"))


class CommandTests(unittest.TestCase):
    def test_logs_redact_secrets_and_do_not_dump_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = signing.Commands(Path(directory))
            try:
                commands.run([sys.executable, "-c", "import sys; print('FULL_SETTINGS'); "
                              "print('error: API_KEY=private-value', file=sys.stderr); "
                              "print('error: No profiles found', file=sys.stderr)"],
                             "test", diagnostics="stderr")
                log = commands.log_path.read_text()
                self.assertNotIn("private-value", log)
                self.assertNotIn("FULL_SETTINGS", log)
                self.assertIn("No profiles", log)
                self.assertEqual(commands.log_path.stat().st_mode & 0o777, 0o600)
            finally:
                commands.log.close()

    def test_failure_raises_and_timeout_terminates_owned_child(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = signing.Commands(Path(directory))
            try:
                with self.assertRaises(signing.SigningError):
                    commands.run([sys.executable, "-c", "raise SystemExit(1)"], "failure")
                with self.assertRaisesRegex(signing.SigningError, "超时"):
                    commands.run([sys.executable, "-c", "import time; time.sleep(10)"], "timeout", timeout=0.05)
            finally:
                commands.log.close()


class LauncherTests(unittest.TestCase):
    def test_shell_launches_only_after_success_and_from_project_root(self):
        with tempfile.TemporaryDirectory(prefix="launcher with spaces ") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copyfile(SCRIPTS / "run_macos.sh", root / "scripts/run_macos.sh")
            fake_bin = root / "bin"
            fake_bin.mkdir()
            scripts = {
                "uname": "#!/bin/sh\necho Darwin\n",
                "xcrun": '#!/bin/sh\nprintf "%s\\n" "$FAKE_PYTHON"\n',
                "preflight": '#!/bin/sh\nexit "$PREFLIGHT_STATUS"\n',
                "flutter": '#!/bin/sh\npwd > "$LAUNCH_RECORD"\nprintf "%s\\n" "$@" >> "$LAUNCH_RECORD"\nexit 7\n',
            }
            for name, source in scripts.items():
                script = fake_bin / name
                script.write_text(source)
                script.chmod(0o755)
            record = root / "launch.txt"
            env = dict(os.environ, PATH=str(fake_bin) + ":/usr/bin:/bin",
                       FAKE_PYTHON=str(fake_bin / "preflight"), LAUNCH_RECORD=str(record))
            for failure in ("1", "130"):
                result = subprocess.run(["/bin/bash", str(root / "scripts/run_macos.sh")], cwd="/",
                                        env=dict(env, PREFLIGHT_STATUS=failure), capture_output=True)
                self.assertEqual(result.returncode, int(failure))
                self.assertFalse(record.exists())
            result = subprocess.run(["/bin/bash", str(root / "scripts/run_macos.sh")], cwd="/",
                                    env=dict(env, PREFLIGHT_STATUS="0"), capture_output=True)
            self.assertEqual(result.returncode, 7)
            recorded = record.read_text().splitlines()
            self.assertEqual(Path(recorded[0]).resolve(), root.resolve())
            self.assertEqual(recorded[1:], ["run", "-d", "macos", "--debug", "--no-pub"])
            rejected = subprocess.run(["/bin/bash", str(root / "scripts/run_macos.sh"), "--release"],
                                      env=env, capture_output=True)
            self.assertEqual(rejected.returncode, 2)


if __name__ == "__main__":
    unittest.main()
