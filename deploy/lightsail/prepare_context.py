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
        # Parse the secret JSON
        secret = json.loads(secret_json)
        # If it's a dict with 'SecretString' key (AWS Secrets Manager JSON format)
        if isinstance(secret, dict) and "SecretString" in secret:
            secret = json.loads(secret["SecretString"])
    except json.JSONDecodeError as exc:
        fail(f"Unable to parse SECRET_JSON: {exc}")

    # Handle AWS Secrets Manager key-value format
    # Keys from the image: LIGHTSAIL_IP, lightsail_host, lightsail_user, etc.
    # Map AWS secret keys to our expected keys
    secret_mapped = {}
    
    # Direct mappings (if keys match exactly)
    for key in ["lightsail_host", "lightsail_user", "lightsail_port", "lightsail_private_key_b64", 
                "remote_project_path", "docker_compose_file", "env_file_content"]:
        if key in secret:
            secret_mapped[key] = secret[key]
    
    # Handle LIGHTSAIL_IP -> lightsail_host mapping
    if "LIGHTSAIL_IP" in secret and "lightsail_host" not in secret_mapped:
        secret_mapped["lightsail_host"] = secret["LIGHTSAIL_IP"]
    if "lightsail_host" in secret and "lightsail_host" not in secret_mapped:
        secret_mapped["lightsail_host"] = secret["lightsail_host"]
    
    # Handle lightsail_user
    if "lightsail_user" in secret:
        secret_mapped["lightsail_user"] = secret["lightsail_user"]
    elif "LIGHTSAIL_USER" in secret:
        secret_mapped["lightsail_user"] = secret["LIGHTSAIL_USER"]
    
    # Handle lightsail_port
    if "lightsail_port" in secret:
        secret_mapped["lightsail_port"] = secret["lightsail_port"]
    elif "LIGHTSAIL_PORT" in secret:
        secret_mapped["lightsail_port"] = secret["LIGHTSAIL_PORT"]
    
    # Handle private key
    if "lightsail_private_key_b64" in secret:
        secret_mapped["lightsail_private_key_b64"] = secret["lightsail_private_key_b64"]
    
    # Build env_file_content from database credentials
    # Note: Frappe uses MariaDB/MySQL, not PostgreSQL
    # If using Lightsail database, ensure it's MariaDB/MySQL compatible
    env_parts = []
    if "DATABASE_ENDPOINT" in secret:
        env_parts.append(f"DB_HOST={secret['DATABASE_ENDPOINT']}")
    if "DATABASE_NAME" in secret:
        env_parts.append(f"DB_NAME={secret['DATABASE_NAME']}")
    if "DATABASE_USERNAME" in secret:
        env_parts.append(f"DB_USER={secret['DATABASE_USERNAME']}")
    if "DATABASE_PASSWORD" in secret:
        env_parts.append(f"DB_PASSWORD={secret['DATABASE_PASSWORD']}")
    if "DATABASE_PORT" in secret:
        env_parts.append(f"DB_PORT={secret['DATABASE_PORT']}")
    elif "DATABASE_ENDPOINT" in secret:
        # Default to 3306 for MariaDB/MySQL (Frappe's default)
        env_parts.append("DB_PORT=3306")
    
    # Add site name and URL
    # Use SITE_NAME from secrets if available, otherwise use domain without www
    if "SITE_NAME" in secret:
        env_parts.append(f"SITE_NAME={secret['SITE_NAME']}")
    elif "LIGHTSAIL_IP" in secret:
        # Fallback: Use the IP as site name, replacing dots with underscores
        site_name = secret['LIGHTSAIL_IP'].replace('.', '_')
        env_parts.append(f"SITE_NAME={site_name}")
    elif "lightsail_host" in secret_mapped:
        # Fallback to host if IP not available
        site_name = secret_mapped['lightsail_host'].replace('.', '_')
        env_parts.append(f"SITE_NAME={site_name}")
    
    # Add SITE_URL for proper host_name configuration
    if "SITE_URL" in secret:
        env_parts.append(f"SITE_URL={secret['SITE_URL']}")
    
    # Add any existing env_file_content or use the built one
    if "env_file_content" in secret:
        secret_mapped["env_file_content"] = secret["env_file_content"]
    elif env_parts:
        secret_mapped["env_file_content"] = "\n".join(env_parts) + "\n"
    
    # Set default remote path if not provided
    if "remote_project_path" not in secret_mapped:
        secret_mapped["remote_project_path"] = "/opt/frappe-hrms"
    
    # Set default compose file if not provided
    if "docker_compose_file" not in secret_mapped:
        secret_mapped["docker_compose_file"] = "docker/docker-compose.yml"
    
    secret = secret_mapped

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
        "env_content": env_content,
    }

    output_file = os.environ.get("GITHUB_OUTPUT")
    if not output_file:
        fail("GITHUB_OUTPUT is not defined")

    with open(output_file, "a", encoding="utf-8") as fh:
        for key, value in outputs.items():
            if key == "env_content":
                # Use multiline format for env_content
                fh.write(f"{key}<<EOF\n")
                fh.write(value)
                fh.write("\nEOF\n")
            else:
                fh.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()

