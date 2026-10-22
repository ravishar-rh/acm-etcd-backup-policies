#!/usr/bin/env python3
"""
Pre-merge guard for this GitOps repo.

The whole design assumes no credential ever needs to live in these manifests:
S3 access comes from the External Secrets Operator at runtime. This script
enforces that assumption instead of trusting it, and is wired into CI.

Checks:
  1. every YAML file parses
  2. no Secret object carries literal data (including Secrets nested inside
     ACM Policy object-templates, which a flat grep would read right past)
  3. no AWS access keys, private keys, or account IDs anywhere
  4. the shell embedded in CronJob containers is syntactically valid

Usage:  python3 scripts/verify.py [repo-root]
"""

import pathlib
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit("pyyaml is required:  pip install pyyaml")

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

# Placeholders are expected and fine; real values are not.
PLACEHOLDER = re.compile(r"CHANGEME|REPLACE_ME|^\s*$|_BUCKET|_KMS_KEY_ARN|ACCOUNT_ID|OIDC_PROVIDER")
TEMPLATED = re.compile(r"\{\{.*\}\}")

SECRET_PATTERNS = [
    (re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), "AWS access key ID"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    # Account IDs only matter in ARN position; a bare 12-digit number is
    # usually a timestamp or a byte count.
    (re.compile(r"arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:\d{12}:"), "AWS account ID in an ARN"),
    (re.compile(r"(?i)aws_secret_access_key\s*[:=]\s*['\"]?[A-Za-z0-9/+=]{40}"), "AWS secret access key"),
]

failures: list[str] = []
checked_yaml = 0
checked_scripts = 0


def fail(path: pathlib.Path, msg: str) -> None:
    failures.append(f"{path.relative_to(ROOT)}: {msg}")


def walk(node):
    """Yield every dict in a nested structure, however deeply buried."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)


def check_secrets_in_objects(path: pathlib.Path, docs) -> None:
    for doc in docs:
        for obj in walk(doc):
            if obj.get("kind") != "Secret":
                continue
            for field in ("data", "stringData"):
                block = obj.get(field)
                if not isinstance(block, dict):
                    continue
                for key, value in block.items():
                    text = "" if value is None else str(value)
                    if TEMPLATED.search(text) or PLACEHOLDER.search(text):
                        continue
                    fail(
                        path,
                        f"Secret/{obj.get('metadata', {}).get('name', '?')} has a literal "
                        f"value in {field}.{key} - this repo must not carry credentials; "
                        f"use an ExternalSecret instead",
                    )


def check_patterns(path: pathlib.Path) -> None:
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        for pattern, label in SECRET_PATTERNS:
            if pattern.search(line):
                fail(path, f"line {lineno}: looks like a {label}")


def check_embedded_shell(path: pathlib.Path, docs) -> None:
    global checked_scripts
    for doc in docs:
        for obj in walk(doc):
            if obj.get("kind") != "CronJob":
                continue
            spec = obj.get("spec", {}).get("jobTemplate", {}).get("spec", {})
            pod = spec.get("template", {}).get("spec", {})
            for c in list(pod.get("initContainers") or []) + list(pod.get("containers") or []):
                cmd = c.get("command") or []
                if len(cmd) < 2 or "bash" not in str(cmd[0]):
                    continue
                script = cmd[-1]
                with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
                    fh.write(script)
                    tmp = fh.name
                r = subprocess.run(["bash", "-n", tmp], capture_output=True, text=True)
                checked_scripts += 1
                if r.returncode != 0:
                    fail(path, f"container {c.get('name')}: shell syntax error: {r.stderr.strip()}")


for path in sorted(ROOT.rglob("*")):
    if ".git/" in str(path) or not path.is_file():
        continue
    if path.suffix in (".yaml", ".yml"):
        checked_yaml += 1
        try:
            docs = [d for d in yaml.safe_load_all(path.read_text()) if d]
        except yaml.YAMLError as exc:
            fail(path, f"does not parse: {exc}")
            continue
        check_secrets_in_objects(path, docs)
        check_embedded_shell(path, docs)
    if path.suffix in (".yaml", ".yml", ".json", ".sh", ".md"):
        check_patterns(path)

print(f"checked {checked_yaml} YAML files and {checked_scripts} embedded shell scripts")
if failures:
    print("\nFAILED:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("OK: no credentials, no literal Secret data, all manifests parse")
