#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import secrets
import shutil
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


def decode(value):
    if not value:
        return ""
    return base64.b64decode(value).decode("utf-8")


def normalize_url(value):
    raw = str(value or "").strip()
    parsed = urlsplit(raw)
    if parsed.scheme.lower() not in ("ws", "wss"):
        raise ValueError("WebSocket URL 必须以 ws:// 或 wss:// 开头")
    if not parsed.hostname:
        raise ValueError("WebSocket URL 缺少主机名")

    host = parsed.hostname.lower()
    if host in ("localhost", "127.0.0.1", "::1"):
        host = "loopback"
    if ":" in host:
        host = f"[{host}]"

    port = parsed.port
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("WebSocket URL 端口无效")
    netloc = host if port is None else f"{host}:{port}"
    path = parsed.path.rstrip("/") or "/"
    return urlunsplit((parsed.scheme.lower(), netloc, path, "", ""))


def token_hash(token):
    return hashlib.sha256(str(token or "").encode("utf-8")).hexdigest()


def positive_int(value, fallback, minimum=1):
    try:
        number = int(value)
    except (TypeError, ValueError):
        return fallback
    return number if number >= minimum else fallback


def config_candidates(root):
    runtime_config = (
        root
        / "opt"
        / "QQ"
        / "resources"
        / "app"
        / "app_launcher"
        / "napcat"
        / "config"
    )
    directories = [
        runtime_config,
        Path("/root/.config/QQ/NapCat/config"),
        Path("/root/.config/QQ/NapCat"),
    ]
    for directory in directories:
        if not directory.is_dir():
            continue
        per_uin = sorted(
            directory.glob("onebot11_*.json"),
            key=lambda item: item.stat().st_mtime,
            reverse=True,
        )
        if per_uin:
            return per_uin[0]
        generic = directory / "onebot11.json"
        if generic.is_file():
            return generic
    return runtime_config / "onebot11.json"


def load_json(path, fallback):
    if not path.is_file():
        return fallback
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except Exception as exc:
        raise RuntimeError(f"配置文件不是有效 JSON：{path}（{exc}）") from exc


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=str(path.parent),
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.remove(temporary)
        except OSError:
            pass
        raise


def unique_name(preferred, clients):
    used = {str(item.get("name") or "") for item in clients if isinstance(item, dict)}
    if preferred not in used:
        return preferred
    candidate = f"{preferred}-zbs"
    if candidate not in used:
        return candidate
    index = 2
    while f"{candidate}-{index}" in used:
        index += 1
    return f"{candidate}-{index}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--name-b64", default="")
    parser.add_argument("--url-b64", required=True)
    parser.add_argument("--token-b64", default="")
    parser.add_argument("--message-format-b64", default="")
    parser.add_argument("--report-self-message", default="0")
    parser.add_argument("--heart-interval", default="30000")
    parser.add_argument("--reconnect-interval", default="5000")
    parser.add_argument("--debug", default="1")
    parser.add_argument("--enable", default="1")
    args = parser.parse_args()

    root = Path(args.root)
    state_path = Path(args.state)
    config_path = config_candidates(root)
    config = load_json(config_path, {})
    if not isinstance(config, dict):
        raise RuntimeError("OneBot 配置顶层必须是对象")

    name = decode(args.name_b64).strip() or "值班室-AstrBot"
    url = decode(args.url_b64).strip()
    token = decode(args.token_b64)
    message_format = decode(args.message_format_b64).strip().lower() or "array"
    if message_format not in ("array", "string"):
        raise ValueError("消息上报格式只能是 array 或 string")

    network = config.get("network")
    if not isinstance(network, dict):
        network = {}
        config["network"] = network
    clients = network.get("websocketClients")
    if not isinstance(clients, list):
        clients = []
        network["websocketClients"] = clients

    clients[:] = [item for item in clients if isinstance(item, dict)]
    normalized_url = normalize_url(url)
    state = load_json(state_path, {})
    if not isinstance(state, dict):
        state = {}
    managed = state.get("managed")
    if not isinstance(managed, list):
        managed = []

    previous = next(
        (
            item
            for item in managed
            if isinstance(item, dict)
            and item.get("configFile") == str(config_path)
        ),
        None,
    )
    exact_matches = []
    if previous:
        for item in clients:
            try:
                same_url = normalize_url(item.get("url")) == previous.get("url")
            except Exception:
                same_url = False
            same_name = str(item.get("name") or "") == str(previous.get("name") or "")
            same_token = token_hash(item.get("token")) == previous.get("tokenHash")
            if same_name and same_url and same_token:
                exact_matches.append(item)

    removed = 0
    if exact_matches:
        entry = exact_matches[0]
        for duplicate in exact_matches[1:]:
            clients.remove(duplicate)
            removed += 1
        if not token:
            token = str(entry.get("token") or "")
        current_name = str(entry.get("name") or name)
        if name != current_name:
            other_names = {
                str(item.get("name") or "")
                for item in clients
                if item is not entry
            }
            if name in other_names:
                name = unique_name(name, [item for item in clients if item is not entry])
            entry["name"] = name
    else:
        entry_name = unique_name(name, clients)
        entry = {"name": entry_name}
        clients.append(entry)

    if not token:
        token = secrets.token_urlsafe(32)

    entry.update(
        {
            "name": str(entry.get("name") or name),
            "enable": str(args.enable).lower() in ("1", "true", "yes", "on"),
            "url": url,
            "messagePostFormat": message_format,
            "reportSelfMessage": str(args.report_self_message).lower()
            in ("1", "true", "yes", "on"),
            "reconnectInterval": positive_int(args.reconnect_interval, 5000),
            "token": token,
            "debug": str(args.debug).lower() in ("1", "true", "yes", "on"),
            "heartInterval": positive_int(args.heart_interval, 30000),
        }
    )
    entry.setdefault("verifyCertificate", True)

    record = {
        "configFile": str(config_path),
        "name": str(entry.get("name") or name),
        "url": normalize_url(entry.get("url")),
        "tokenHash": token_hash(entry.get("token")),
    }
    managed = [
        item
        for item in managed
        if isinstance(item, dict) and item.get("configFile") != str(config_path)
    ]
    managed.append(record)
    state = {
        "version": 1,
        "updatedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "last": {
            "name": entry["name"],
            "url": entry["url"],
            "token": entry["token"],
            "messagePostFormat": entry["messagePostFormat"],
            "reportSelfMessage": entry["reportSelfMessage"],
            "heartInterval": entry["heartInterval"],
            "reconnectInterval": entry["reconnectInterval"],
            "debug": entry["debug"],
            "enable": entry["enable"],
        },
        "managed": managed,
    }

    if config_path.is_file():
        shutil.copy2(config_path, config_path.with_name(config_path.name + ".zbs.bak"))
    atomic_json(config_path, config)
    atomic_json(state_path, state)

    manual_count = max(0, len(clients) - 1)
    print(f"配置写入：{config_path}")
    print(f"连接名称：{entry['name']}")
    print(f"连接地址：{entry['url']}")
    print(f"清理值班室重复项：{removed}")
    print(f"保留其他/手动连接：{manual_count}")
    if exact_matches:
        print("写入方式：更新值班室管理的连接")
    else:
        print("写入方式：新增值班室管理的连接，未覆盖手动连接")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
