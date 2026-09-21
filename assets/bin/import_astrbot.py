#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


EXPECTED_ASTRBOT_VERSION = os.environ.get("ASTRBOT_VERSION", "4.27.3")


class HttpStatusError(RuntimeError):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body}")
        self.status = status
        self.body = body


def request_json(url, method="GET", body=None, token=""):
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        raise HttpStatusError(exc.code, raw) from exc
    parsed = json.loads(raw)
    if not isinstance(parsed, dict):
        raise RuntimeError(f"unexpected response: {raw[:500]}")
    return parsed


def request_first(candidates, operation, token=""):
    last_error = None
    for method, url, body in candidates:
        try:
            return request_json(url, method=method, body=body, token=token), url
        except HttpStatusError as exc:
            if exc.status in (404, 405):
                last_error = exc
                continue
            raise RuntimeError(str(exc)) from exc
    raise RuntimeError(f"{operation}接口不可用：{last_error or '未找到兼容接口'}")


def require_ok(payload, operation):
    if payload.get("status") != "ok":
        raise RuntimeError(f"{operation}失败: {payload.get('message', payload)}")
    data = payload.get("data", {})
    if not isinstance(data, dict):
        raise RuntimeError(f"{operation}响应格式异常: {payload}")
    return data


def main():
    if len(sys.argv) != 5:
        print(
            "usage: import_astrbot.py <base_url> <username> <password> <filename>",
            file=sys.stderr,
        )
        return 2
    base_url = sys.argv[1].rstrip("/")
    username = sys.argv[2]
    password = sys.argv[3]
    filename = sys.argv[4]
    quoted = urllib.parse.quote(filename, safe="")

    print(f"[导入] 连接 AstrBot：{base_url}", flush=True)
    try:
        versions, _ = request_first(
            [
                ("GET", f"{base_url}/api/stat/versions", None),
                ("GET", f"{base_url}/api/v1/stats/versions", None),
            ],
            "版本检查",
        )
    except RuntimeError as exc:
        print(f"[导入] 版本检查未完成，继续尝试登录：{exc}", flush=True)
    else:
        version_data = require_ok(versions, "版本检查")
        actual_version = version_data.get("astrbot_version")
        if actual_version and actual_version != EXPECTED_ASTRBOT_VERSION:
            raise RuntimeError(
                f"AstrBot 版本不匹配：期望 {EXPECTED_ASTRBOT_VERSION}，"
                f"实际 {actual_version}"
            )
        print(f"[导入] AstrBot 版本：{actual_version or '未知'}", flush=True)

    print("[导入] 登录实例", flush=True)
    login, _ = request_first(
        [
            (
                "POST",
                f"{base_url}/api/auth/login",
                {"username": username, "password": password},
            ),
            (
                "POST",
                f"{base_url}/api/v1/auth/login",
                {"username": username, "password": password},
            ),
        ],
        "登录",
    )
    login_data = require_ok(login, "登录")
    jwt = login_data.get("token")
    if not jwt:
        raise RuntimeError(f"登录响应缺少 token：{login}")

    print("[导入] 预检查备份包", flush=True)
    check, check_route = request_first(
        [
            ("POST", f"{base_url}/api/backup/check?filename={quoted}", {}),
            ("POST", f"{base_url}/api/v1/backups/{quoted}/check", {}),
        ],
        "备份预检查",
        token=jwt,
    )
    check_data = require_ok(check, "备份预检查")
    if not check_data.get("can_import"):
        raise RuntimeError(
            "备份包不允许导入："
            + str(check_data.get("error") or check_data.get("version_status") or check_data)
        )
    print(
        "[导入] 预检查通过，"
        f"备份版本 {check_data.get('backup_version', '未知')}，"
        f"状态 {check_data.get('version_status', '未知')}",
        flush=True,
    )
    print(f"[导入] 使用接口：{check_route}", flush=True)

    print("[导入] 创建导入任务（replace 模式）", flush=True)
    started, import_route = request_first(
        [
            (
                "POST",
                f"{base_url}/api/backup/import?filename={quoted}",
                {"confirmed": True},
            ),
            (
                "POST",
                f"{base_url}/api/v1/backups/{quoted}/import",
                {"confirmed": True},
            ),
        ],
        "启动导入",
        token=jwt,
    )
    started_data = require_ok(started, "启动导入")
    task_id = started_data.get("task_id")
    if not task_id:
        raise RuntimeError(f"导入响应缺少 task_id：{started}")
    print(f"[导入] 任务号：{task_id}", flush=True)
    print(f"[导入] 使用接口：{import_route}", flush=True)

    last_line = ""
    deadline = time.time() + 6 * 60 * 60
    while time.time() < deadline:
        progress, _ = request_first(
            [
                (
                    "GET",
                    f"{base_url}/api/backup/progress"
                    f"?task_id={urllib.parse.quote(str(task_id), safe='')}",
                    None,
                ),
                (
                    "GET",
                    f"{base_url}/api/v1/backups/tasks/"
                    f"{urllib.parse.quote(str(task_id), safe='')}",
                    None,
                ),
            ],
            "查询导入进度",
            token=jwt,
        )
        data = require_ok(progress, "查询导入进度")
        status = data.get("status")
        detail = data.get("progress") or {}
        message = detail.get("message") or data.get("message") or status
        current = detail.get("current")
        total = detail.get("total")
        line = f"[{status}] {message}"
        if current is not None and total is not None:
            line += f" ({current}/{total})"
        if line != last_line:
            print(line, flush=True)
            last_line = line
        if status == "completed":
            result = data.get("result") or {}
            if result.get("success") is not True:
                raise RuntimeError(f"导入完成但 success 不是 true：{result}")
            print("[导入] 数据导入完成，官方接口已确认 success=true", flush=True)
            print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
            return 0
        if status == "failed":
            raise RuntimeError(f"导入失败：{data.get('error') or data}")
        time.sleep(2)
    raise RuntimeError("导入等待超时")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
