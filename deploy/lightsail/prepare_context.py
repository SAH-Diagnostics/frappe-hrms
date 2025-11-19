#!/usr/bin/env python3
"""
Helper invoked by .github/workflows/build-deploy.yml.
Reads the deployment payload from AWS Secrets Manager (passed via SECRET_JSON),
materialises the SSH key + env file, and emits GitHub Action outputs.
"""

from __future__ import annotations

import binascii
import base64
import json
import os
import pathlib
import sys


def fail(message: str) -> None:
    print(f"[prepare_context] {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    secret_json = os.environ.get("SECRET_JSON")
    if not secret_json:
        fail("SECRET_JSON environment variable is empty")

    try:
        secret = json.loads(secret_json)
    except json.JSONDecodeError as exc:
        fail(f"Unable to parse SECRET_JSON: {exc}")

    required_fields = [
        "lightsail_host",
        "lightsail_user",
        "lightsail_private_key_b64",
        "remote_project_path",
    ]
    missing = [field for field in required_fields if not secret.get(field)]
    if missing:
        fail(f"Missing required keys in AWS secret: {', '.join(missing)}")

    ssh_dir = pathlib.Path.home() / ".ssh"
    ssh_dir.mkdir(parents=True, exist_ok=True)
    ssh_dir.chmod(0o700)

    key_path = ssh_dir / "lightsail"
    b64_value = secret["lightsail_private_key_b64"]
    try:
        key_bytes = base64.b64decode(b64_value)
    except (ValueError, binascii.Error):
        fail("lightsail_private_key_b64 is not valid base64 data")

    key_path.write_bytes(key_bytes)
    key_path.chmod(0o600)

    env_content = secret.get("env_file_content", "")
    env_path = pathlib.Path("deploy/lightsail/.env.remote")
    env_path.parent.mkdir(parents=True, exist_ok=True)
    env_path.write_text(env_content, encoding="utf-8")

    compose_file = secret.get("docker_compose_file", "docker/docker-compose.yml")
    lightsail_port = str(secret.get("lightsail_port", "22"))

    outputs = {
        "host": secret["lightsail_host"],
        "user": secret["lightsail_user"],
        "ssh_key_path": str(key_path),
        "remote_path": secret["remote_project_path"],
        "port": lightsail_port,
        "compose_file": compose_file,
        "env_file": "deploy/lightsail/.env.remote",
    }

    output_file = os.environ.get("GITHUB_OUTPUT")
    if not output_file:
        fail("GITHUB_OUTPUT is not defined")

    with open(output_file, "a", encoding="utf-8") as fh:
        for key, value in outputs.items():
            fh.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()

