#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import secrets
import shutil
import sys
import tempfile


def hash_dashboard_password(raw_password: str) -> str:
    iterations = 600000
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256",
        raw_password.encode("utf-8"),
        bytes.fromhex(salt),
        iterations,
    ).hex()
    return f"pbkdf2_sha256${iterations}${salt}${digest}"


def hash_md5_dashboard_password(raw_password: str) -> str:
    return hashlib.md5(raw_password.encode("utf-8")).hexdigest()


def decode_value(value_b64, label):
    try:
        return base64.b64decode(
            value_b64.encode("ascii"),
            validate=True,
        ).decode("utf-8")
    except Exception as exc:
        raise ValueError(f"invalid {label} payload: {exc}") from exc


def parse_options(arguments):
    options = {}
    index = 0
    while index < len(arguments):
        option = arguments[index]
        if option not in ("--username-b64", "--password-b64"):
            raise ValueError(f"unknown option: {option}")
        if index + 1 >= len(arguments):
            raise ValueError(f"missing value for {option}")
        options[option] = arguments[index + 1]
        index += 2
    return options


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: patch_astrbot_config.py <cmd_config.json> "
            "[--username-b64 <base64>] [--password-b64 <base64>]",
            file=sys.stderr,
        )
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        print(f"config not found: {path}", file=sys.stderr)
        return 3

    # AstrBot backups may carry a UTF-8 BOM; utf-8-sig accepts both forms.
    with open(path, encoding="utf-8-sig") as handle:
        config = json.load(handle)

    try:
        options = parse_options(sys.argv[2:])
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    providers = config.get("provider")
    if not isinstance(providers, list):
        providers = []

    providers = [
        item
        for item in providers
        if not (isinstance(item, dict) and item.get("id") == "local_minilm_embedding")
    ]
    providers.append(
        {
            "id": "local_minilm_embedding",
            "type": "openai_embedding",
            "provider": "openai",
            "provider_type": "embedding",
            "enable": True,
            "embedding_api_key": "local-minilm",
            "embedding_api_base": "http://127.0.0.1:8000/v1",
            "embedding_model": "paraphrase-multilingual-MiniLM-L12-v2",
            "embedding_dimensions": 384,
            "embedding_dimensions_mode": "always",
            "timeout": 60,
            "proxy": "",
        }
    )
    config["provider"] = providers

    password_b64 = options.get("--password-b64")
    if password_b64 is not None:
        try:
            raw_password = decode_value(password_b64, "dashboard password")
            raw_username = decode_value(
                options.get("--username-b64", ""),
                "dashboard username",
            ) if options.get("--username-b64") else "astrbot"
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 4
        if not raw_password:
            print("dashboard token cannot be empty", file=sys.stderr)
            return 5
        if not raw_username:
            print("dashboard username cannot be empty", file=sys.stderr)
            return 5
        dashboard = config.get("dashboard")
        if not isinstance(dashboard, dict):
            dashboard = {}
            config["dashboard"] = dashboard
        dashboard["username"] = raw_username
        dashboard["pbkdf2_password"] = hash_dashboard_password(raw_password)
        dashboard["password"] = hash_md5_dashboard_password(raw_password)
        dashboard["password_storage_upgraded"] = True
        dashboard["password_change_required"] = False
        print("Dashboard credentials updated", flush=True)

    backup = path + ".before-minilm"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)

    directory = os.path.dirname(path)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, delete=False
    ) as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = handle.name
    os.replace(temporary, path)
    print("MiniLM provider written: local_minilm_embedding")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
