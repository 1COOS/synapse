"""Local Debug signing preflight. Uses only Python's standard library and Xcode.

Never print build-setting JSON, decoded profiles, certificates or the environment.
The shell entrypoint owns launching Flutter after this program succeeds.
"""

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import ssl
import subprocess
import sys
import tempfile
import time
from xml.parsers.expat import ExpatError


UTC = dt.timezone.utc
RENEW_WINDOW = dt.timedelta(hours=24)


class SigningError(Exception):
    pass


def announce(message):
    print("[macOS 签名] " + message, flush=True)


class Commands:
    def __init__(self, root):
        self.root = root
        log_dir = root / "build/macos/signing"
        log_dir.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix="preflight-", suffix=".log", dir=log_dir)
        self.log_path = Path(name)
        self.log = os.fdopen(fd, "w", encoding="utf-8")

    def record(self, message):
        self.log.write(message + "\n")
        self.log.flush()

    def run(self, args, stage, *, timeout=180, check=True, diagnostics=False,
            input_data=None):
        self.record(stage)
        try:
            process = subprocess.Popen(
                [str(a) for a in args], cwd=self.root, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
        except OSError as error:
            raise SigningError(stage + "：无法启动所需工具，请检查 Xcode 安装。") from error
        deadline = time.monotonic() + timeout
        first = True
        try:
            while True:
                try:
                    out, err = process.communicate(
                        input=input_data if first else None,
                        timeout=min(20, max(0.01, deadline - time.monotonic())),
                    )
                    break
                except subprocess.TimeoutExpired:
                    first = False
                    if time.monotonic() >= deadline:
                        raise SigningError(stage + "超时；请检查网络、Xcode 登录或构建进程。")
                    announce(stage + "仍在进行，请稍候……")
        except (SigningError, KeyboardInterrupt):
            # Only terminate the command group created by this invocation.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
            raise
        self.record("退出状态：" + str(process.returncode))
        if diagnostics:
            # Keep actionable diagnostics, not xcodebuild environment/settings dumps.
            diagnostic_bytes = err if diagnostics == "stderr" else out + b"\n" + err
            for line in diagnostic_bytes.decode("utf-8", "replace").splitlines():
                if re.search(r"error:|warning:|failed|error domain|no profiles|account|network", line, re.I):
                    if re.search(r"token|password|secret|api.?key|authorization|PRIVATE KEY", line, re.I):
                        self.record("[已隐藏可能包含凭据的诊断行]")
                    else:
                        self.record(line[:2000])
        if check and process.returncode:
            raise SigningError(
                stage + "失败。请在 Xcode → Settings → Accounts 检查登录和团队，"
                "并确认网络、证书及 Xcode 首次启动设置；不会绕过签名继续启动。"
            )
        return subprocess.CompletedProcess(args, process.returncode, out, err)


def utc(value):
    if not isinstance(value, dt.datetime):
        raise ValueError("Invalid profile date")
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def apple_pattern_matches(pattern, value):
    # Apple app identifiers allow only an exact value or a trailing wildcard.
    return isinstance(pattern, str) and (
        pattern == value or (pattern.endswith(".*") and value.startswith(pattern[:-1]))
    )


def profile_matches(profile, settings, identities, device, now):
    """Fail closed for malformed, expired, foreign or unusable profiles."""
    try:
        team = settings["DEVELOPMENT_TEAM"]
        entitlements = profile["Entitlements"]
        app_id = entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier"))
        if "OSX" not in profile["Platform"] or team not in profile["TeamIdentifier"]:
            return False
        if entitlements.get("com.apple.developer.team-identifier") != team:
            return False
        if not any(apple_pattern_matches(app_id, prefix + "." + settings["PRODUCT_BUNDLE_IDENTIFIER"])
                   for prefix in profile["ApplicationIdentifierPrefix"]):
            return False
        if not utc(profile["CreationDate"]) <= now < utc(profile["ExpirationDate"]):
            return False
        if not profile.get("ProvisionsAllDevices", False) and device.upper() not in {
            value.upper() for value in profile.get("ProvisionedDevices", [])
        }:
            return False
        return any(hashlib.sha1(cert).hexdigest().upper() in identities
                   for cert in profile["DeveloperCertificates"])
    except (KeyError, TypeError, ValueError, AttributeError):
        return False


class Preflight:
    def __init__(self, root, commands, *, home=None, environment=None, now=None):
        self.root = root
        self.commands = commands
        self.home = Path.home() if home is None else home
        self.environment = os.environ if environment is None else environment
        self.now = now or (lambda: dt.datetime.now(UTC))
        self.settings = {}
        self.identities = set()
        self.device = ""

    def xcode_args(self):
        build = self.root / "build/macos"
        return [
            "/usr/bin/xcrun", "xcodebuild", "-workspace", str(self.root / "macos/Runner.xcworkspace"),
            "-scheme", "Runner", "-configuration", "Debug", "-destination",
            "platform=macOS,arch=" + platform.machine(),
            "-derivedDataPath", str(build), "-clonedSourcePackagesDirPath", str(build / "SourcePackages"),
            "-disableAutomaticPackageResolution",
            "OBJROOT=" + str(build / "Build/Intermediates.noindex"),
            "SYMROOT=" + str(build / "Build/Products"), "COMPILER_INDEX_STORE_ENABLE=NO",
        ] + [key[len("FLUTTER_XCODE_"):] + "=" + value
             for key, value in self.environment.items() if key.startswith("FLUTTER_XCODE_")]

    def read_settings(self):
        announce("读取 Runner 的实际 Debug 签名配置。")
        result = self.commands.run(self.xcode_args() + ["-showBuildSettings", "-json"],
                                   "读取 Debug 配置", diagnostics="stderr")
        try:
            self.settings = next(row["buildSettings"] for row in json.loads(result.stdout)
                                 if row.get("target") == "Runner")
        except (ValueError, KeyError, TypeError, StopIteration) as error:
            raise SigningError("无法读取 Runner Debug 配置，请检查 Xcode 和项目依赖。") from error
        if not self.settings.get("DEVELOPMENT_TEAM") or self.settings["DEVELOPMENT_TEAM"] == "YOUR_TEAM_ID":
            raise SigningError("请先在 macos/Runner/Configs/Signing.local.xcconfig 填写本机 DEVELOPMENT_TEAM。")
        if (self.settings.get("CODE_SIGN_STYLE") != "Automatic"
                or not self.settings.get("PRODUCT_BUNDLE_IDENTIFIER")
                or self.settings.get("CODE_SIGN_IDENTITY") not in ("Apple Development", "Mac Developer")
                or self.settings.get("CODE_SIGNING_ALLOWED") == "NO"
                or self.settings.get("CODE_SIGNING_REQUIRED") != "YES"
                or self.settings.get("PROVISIONING_PROFILE_SPECIFIER")
                or self.settings.get("PROVISIONING_PROFILE")):
            raise SigningError("Runner Debug 必须使用 Apple Development 自动签名，不能关闭签名或固定描述文件。")

    def read_identities(self):
        result = self.commands.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                                   "检查有效签名身份")
        valid = set(re.findall(rb'\b([0-9A-Fa-f]{40}) "(?:Apple Development|Mac Developer):', result.stdout))
        certificates = self.commands.run(["/usr/bin/security", "find-certificate", "-a", "-p"],
                                         "检查签名证书团队").stdout
        for pem in re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.S):
            der = ssl.PEM_cert_to_DER_cert(pem.decode("ascii"))
            fingerprint = hashlib.sha1(der).hexdigest().upper()
            if fingerprint.encode("ascii") not in {value.upper() for value in valid}:
                continue
            subject = self.commands.run(
                ["/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "sep_multiline"],
                "确认签名证书团队", input_data=pem,
            ).stdout.decode("utf-8", "replace")
            team = re.search(r"^\s*OU\s*=\s*(\S+)\s*$", subject, re.M)
            if team and team[1] == self.settings["DEVELOPMENT_TEAM"]:
                self.identities.add(fingerprint)
        if not self.identities:
            raise SigningError("当前团队没有有效的 Apple Development 私钥及证书；请在 Xcode Accounts 管理证书，必要时解锁登录钥匙串。")

    def read_device(self):
        result = self.commands.run(["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"],
                                   "读取本机签名设备标识")
        try:
            hardware = json.loads(result.stdout)["SPHardwareDataType"][0]
            # Apple Silicon uses a provisioning UDID, NOT its platform UUID.
            self.device = hardware.get("provisioning_UDID") or hardware["platform_UUID"]
            if not isinstance(self.device, str) or not self.device:
                raise ValueError("Missing device ID")
        except (ValueError, KeyError, TypeError, IndexError) as error:
            raise SigningError("无法读取本机 Provisioning UDID，停止签名检查。") from error

    def decode(self, path):
        result = self.commands.run(["/usr/bin/security", "cms", "-D", "-i", str(path)],
                                   "读取描述文件", check=False, timeout=30)
        if result.returncode:
            return None
        try:
            profile = plistlib.loads(result.stdout)
            return profile if isinstance(profile, dict) else None
        except (ValueError, plistlib.InvalidFileException, ExpatError):
            return None

    def best_profile(self):
        candidates = []
        for relative in ("Library/Developer/Xcode/UserData/Provisioning Profiles",
                         "Library/MobileDevice/Provisioning Profiles"):
            directory = self.home / relative
            if not directory.is_dir():
                continue
            for path in sorted(directory.iterdir()):
                if not path.is_file() or path.suffix not in (".provisionprofile", ".mobileprovision"):
                    continue
                profile = self.decode(path)
                if profile and profile_matches(profile, self.settings, self.identities, self.device, self.now()):
                    candidates.append(profile)
        return max(candidates, key=lambda item: utc(item["ExpirationDate"]), default=None)

    def verify_app(self):
        app = Path(self.settings["TARGET_BUILD_DIR"]) / self.settings["FULL_PRODUCT_NAME"]
        profile = self.decode(app / "Contents/embedded.provisionprofile")
        if not profile or not profile_matches(profile, self.settings, self.identities, self.device, self.now()):
            raise SigningError("构建产物未包含匹配且有效的描述文件，停止启动。")
        self.commands.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                          "严格验证应用签名", diagnostics=True)
        details = self.commands.run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
                                    "核对应用签名标识").stderr.decode("utf-8", "replace")
        for key, value in (("Identifier", self.settings["PRODUCT_BUNDLE_IDENTIFIER"]),
                           ("TeamIdentifier", self.settings["DEVELOPMENT_TEAM"])):
            if not re.search(r"^" + key + "=" + re.escape(value) + r"$", details, re.M):
                raise SigningError("构建产物的应用标识或签名团队不匹配。")
        with tempfile.TemporaryDirectory(prefix="signer-", dir=self.root / "build/macos/signing") as folder:
            prefix = str(Path(folder) / "cert")
            # codesign treats this as an optional argument: use '=' or the prefix
            # is interpreted as the code object, even though its man page uses a space.
            self.commands.run(["/usr/bin/codesign", "-d", "--extract-certificates=" + prefix, str(app)],
                              "核对实际签名证书")
            fingerprint = hashlib.sha1(Path(prefix + "0").read_bytes()).hexdigest().upper()
            allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
            if fingerprint not in self.identities or fingerprint not in allowed:
                raise SigningError("应用实际签名证书与描述文件不匹配。")
        return profile

    def prepare(self):
        if not (self.root / ".dart_tool/package_config.json").is_file() or not (
            self.root / "macos/Flutter/ephemeral/Flutter-Generated.xcconfig"
        ).is_file():
            raise SigningError("缺少已解析的项目依赖；请先手动运行 flutter pub get，再使用此入口。脚本不会自动更新依赖。")
        self.read_settings()
        self.read_identities()
        self.read_device()
        profile = self.best_profile()
        if profile and utc(profile["ExpirationDate"]) - self.now() > RENEW_WINDOW:
            announce("描述文件有效，跳过续签；有效期至 " + str(utc(profile["ExpirationDate"]).astimezone()))
            return
        announce("描述文件缺失、不可用或将在 24 小时内过期，申请一次自动续签。")
        self.commands.run(self.xcode_args() + ["-allowProvisioningUpdates", "-quiet", "build"],
                          "Xcode 自动续签及 Debug 构建", timeout=1200, diagnostics=True)
        if not self.best_profile():
            raise SigningError("Xcode 构建后仍没有匹配且有效的本机描述文件；请检查 Accounts，不会重复续签。")
        profile = self.verify_app()
        remaining = utc(profile["ExpirationDate"]) - self.now()
        if remaining <= RENEW_WINDOW:
            announce("警告：Xcode 返回的描述文件仍临近过期，本次允许启动；未强制删除或重建。")
        announce("续签检查及应用签名验证通过；有效期至 " + str(utc(profile["ExpirationDate"]).astimezone()))


def main():
    root = Path(__file__).resolve().parent.parent
    commands = Commands(root)
    try:
        Preflight(root, commands).prepare()
        announce("检查通过，交由 Flutter 启动 Debug。")
        return 0
    except (SigningError, OSError) as error:
        announce(str(error))
        commands.record(str(error))
        announce("诊断日志：" + str(commands.log_path))
        return 1
    except KeyboardInterrupt:
        announce("已取消，不继续启动 Flutter。")
        return 130
    finally:
        commands.log.close()


if __name__ == "__main__":
    sys.exit(main())
