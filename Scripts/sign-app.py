#!/usr/bin/env python3
"""Sign with a persistent certificate; ad-hoc signing must be explicitly requested."""
import argparse
import base64
import fcntl
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import tempfile


class SigningError(Exception):
    pass


secret_values = []


def run(arguments, check=True):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if check and result.returncode:
        message = (result.stderr or result.stdout).strip()
        for value in secret_values:
            if value:
                message = message.replace(value, "[redacted]")
        raise SigningError(f"{Path(arguments[0]).name}: {message}")
    return result


def local_certificate():
    directory = Path(os.environ.get("MAC_REMOTE_SIGNING_DIR", Path.home() / "Library/Application Support/Mac Remote/Signing"))
    certificate = directory / "certificate.p12"
    password_file = directory / "password.txt"
    if not directory.exists():
        directory.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.TemporaryDirectory(prefix=".signing-", dir=directory.parent) as temporary:
            payload = Path(temporary) / "identity"
            payload.mkdir(mode=0o700)
            password = secrets.token_urlsafe(32)
            secret_values.append(password)
            (payload / "password.txt").write_text(password)
            config = payload / "certificate.cnf"
            config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Mac Remote Local Development
O = Mac Remote
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
""")
            run(["openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", "3650",
                 "-config", str(config), "-keyout", str(payload / "key.pem"), "-out", str(payload / "certificate.pem")])
            run(["openssl", "pkcs12", "-export", "-inkey", str(payload / "key.pem"), "-in", str(payload / "certificate.pem"),
                 "-name", "Mac Remote Local Development", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                 "-macalg", "sha1", "-passout", "file:" + str(payload / "password.txt"), "-out", str(payload / "certificate.p12")])
            (payload / "key.pem").unlink()
            config.unlink()
            try:
                payload.rename(directory)
            except OSError:
                if not certificate.is_file() or not password_file.is_file():
                    raise
    if not certificate.is_file() or not password_file.is_file():
        raise SigningError(f"固定签名资料不完整，请从备份恢复 {directory}；不会自动换一份新证书。")
    password = password_file.read_text()
    if not password:
        raise SigningError("签名证书密码文件为空")
    secret_values.append(password)
    return certificate, password


def keychain_list():
    return shlex.split(run(["security", "list-keychains", "-d", "user"]).stdout)


def sign_with_certificate(app, certificate, password):
    secret_values.append(password)
    lock_path = Path(tempfile.gettempdir()) / f"mac-remote-signing-{os.getuid()}.lock"
    with lock_path.open("a") as lock, tempfile.TemporaryDirectory(prefix="mac-remote-signing-") as temporary:
        fcntl.flock(lock, fcntl.LOCK_EX)
        keychain = str(Path(temporary) / "signing.keychain-db")
        keychain_password = secrets.token_urlsafe(32)
        secret_values.append(keychain_password)
        try:
            run(["security", "create-keychain", "-p", keychain_password, keychain])
            others = [item for item in keychain_list() if item != keychain]
            run(["security", "list-keychains", "-d", "user", "-s", keychain, *others])
            run(["security", "unlock-keychain", "-p", keychain_password, keychain])
            run(["security", "import", str(certificate), "-k", keychain, "-P", password, "-T", "/usr/bin/codesign"])
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychain_password, keychain])
            # Self-signed local certificates need not be trusted by the system to provide a stable DR.
            identities = run(["security", "find-identity", "-p", "codesigning", keychain]).stdout
            fingerprints = set(re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"', identities, re.MULTILINE))
            if len(fingerprints) != 1:
                raise SigningError("P12 必须包含且仅包含一个代码签名身份及其私钥")
            run(["codesign", "--force", "--deep", "--keychain", keychain, "--sign", fingerprints.pop(), str(app)])
        finally:
            current = keychain_list()
            if keychain in current:
                run(["security", "list-keychains", "-d", "user", "-s", *[item for item in current if item != keychain]])
            run(["security", "delete-keychain", keychain], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path)
    parser.add_argument("--export-ci", action="store_true", help="export the persistent local certificate as private CI secret files")
    args = parser.parse_args()
    os.umask(0o077)
    if args.export_ci:
        certificate, _ = local_certificate()
        output = certificate.with_suffix(".base64")
        output.write_text(base64.b64encode(certificate.read_bytes()).decode("ascii"))
        print(f"证书 Secret 文件：{output}\n密码 Secret 文件：{certificate.parent / 'password.txt'}")
        return
    if args.app is None or not args.app.is_dir():
        parser.error("请指定要签名的 .app 路径")
    identity = os.environ.get("CODE_SIGN_IDENTITY", "")
    certificate_path = os.environ.get("MAC_REMOTE_SIGNING_P12", "")
    if identity:
        arguments = ["codesign", "--force", "--deep", "--sign", identity]
        if os.environ.get("CODE_SIGN_KEYCHAIN"):
            arguments += ["--keychain", os.environ["CODE_SIGN_KEYCHAIN"]]
        run(arguments + [str(args.app)])
    elif certificate_path:
        password = os.environ.get("MAC_REMOTE_SIGNING_PASSWORD", "")
        if not password:
            raise SigningError("缺少 MAC_REMOTE_SIGNING_PASSWORD")
        sign_with_certificate(args.app, Path(certificate_path), password)
    elif os.environ.get("CI") == "true" or os.environ.get("GITHUB_ACTIONS") == "true":
        raise SigningError("CI 必须提供固定签名证书 MAC_REMOTE_SIGNING_P12 和密码；仅测试时可显式设置 CODE_SIGN_IDENTITY=-。")
    else:
        certificate, password = local_certificate()
        sign_with_certificate(args.app, certificate, password)
    run(["codesign", "--verify", "--deep", "--strict", str(args.app)])
    if identity == "-":
        print("已使用临时签名：仅供测试，更新后可能需要重新授权。")
    else:
        display = run(["codesign", "-d", "-r-", str(args.app)])
        if re.search(r"designated =>\s*cdhash\b", display.stdout + display.stderr):
            raise SigningError("签名身份仍绑定代码哈希，无法保留更新后的授权")
        print("已使用固定证书签名并通过校验。")


if __name__ == "__main__":
    try:
        main()
    except (SigningError, OSError) as error:
        print(f"签名失败：{error}", file=sys.stderr)
        sys.exit(1)
