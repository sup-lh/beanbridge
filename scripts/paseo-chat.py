#!/usr/bin/env python3
"""Paseo Desktop/Daemon bridge for BeanBridge VoiceRouting."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import errno
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


PASEO_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{3,127}$")

BLANK_TAB_LABELS = {
    "new tab",
    "new agent",
    "draft",
    "新建 agent",
    "新建标签页",
    "新建标签",
    "新对话",
    "nueva pestaña",
    "nuevo agente",
    "nouvel onglet",
    "nouvel agent",
    "nova aba",
    "novo agente",
    "новая вкладка",
    "новый агент",
    "新しいタブ",
    "新しいエージェント",
    "새 탭",
    "새 에이전트",
    "علامة تبويب جديدة",
    "وكيل جديد",
}

GENERIC_AGENT_LOADING_LABELS = {
    "agent",
    "claude agent",
    "codex agent",
    "antigravity agent",
    "gemini agent",
    "opencode agent",
    "loading",
    "loading...",
    "loading…",
    "加载中",
    "加载中...",
    "加载中…",
    "正在加载",
    "正在加载...",
    "正在加载…",
}

NON_AGENT_BLOCKING_PANEL_LABELS = {
    "terminal",
    "browser",
    "终端",
    "浏览器",
}


def normalize_tab_label(raw: str) -> str:
    return re.sub(r"\s+", " ", raw).strip()


class BridgeError(RuntimeError):
    """Fail-closed operational error with a clear user-facing message."""


class ReceiptAlreadyExistsError(BridgeError):
    """Raised when an idempotent receipt file already exists."""


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def validate_paseo_id(raw: str) -> str:
    value = raw.strip()
    if ".." in value or value.startswith(".") or not PASEO_ID_PATTERN.match(value):
        raise BridgeError("无效的 Paseo 对话 ID。")
    return value


def validate_receipt_path(raw: str) -> Path:
    if not raw or not os.path.isabs(raw):
        raise BridgeError("凭据路径必须是绝对路径。")
    normalized = os.path.normpath(raw)
    if not normalized.endswith(".json"):
        raise BridgeError("凭据路径必须是 .json 文件。")
    return Path(normalized)


def ensure_private_dir(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)


def write_atomic_json(path: Path, payload: dict) -> None:
    ensure_private_dir(path.parent)
    data = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".json")
    try:
        os.chmod(tmp_name, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def claim_receipt(path: Path, initial_payload: dict) -> None:
    ensure_private_dir(path.parent)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    try:
        fd = os.open(str(path), flags, 0o600)
    except OSError as exc:
        if exc.errno == errno.EEXIST:
            raise ReceiptAlreadyExistsError("已存在该条目的处理凭据，不会重复执行。") from exc
        raise BridgeError(f"无法创建凭据文件：{exc}") from exc
    try:
        os.chmod(path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(initial_payload, ensure_ascii=False, indent=2) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise


def read_json_file(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def resolve_paseo_cli() -> list[str]:
    override = os.environ.get("BEANBRIDGE_PASEO_CLI", "").strip()
    if override:
        parts = shlex.split(override)
        if parts:
            return parts

    candidates = [
        "/Applications/Paseo.app/Contents/Resources/bin/paseo",
        str(Path.home() / "Applications" / "Paseo.app" / "Contents" / "Resources" / "bin" / "paseo"),
        str(Path.home() / ".local" / "bin" / "paseo"),
        "/usr/local/bin/paseo",
        "/opt/homebrew/bin/paseo",
    ]
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return [candidate]

    found = shutil.which("paseo")
    if found:
        return [found]
    raise BridgeError("未找到 Paseo 命令行工具（paseo），请确认已安装 Paseo.app。")


def resolve_paseo_node_runner() -> tuple[list[str], dict[str, str]]:
    override = os.environ.get("BEANBRIDGE_PASEO_HELPER_CMD", "").strip()
    if override:
        parts = shlex.split(override)
        if not parts:
            raise BridgeError("BEANBRIDGE_PASEO_HELPER_CMD 为空。")
        return parts, os.environ.copy()

    app_candidates = [
        Path(os.environ.get("BEANBRIDGE_PASEO_APP", "").strip() or "/Applications/Paseo.app"),
        Path("/Applications/Paseo.app"),
        Path.home() / "Applications" / "Paseo.app",
    ]
    for app_path in app_candidates:
        helper = app_path / "Contents" / "Frameworks" / "Paseo Helper.app" / "Contents" / "MacOS" / "Paseo Helper"
        runner = app_path / "Contents" / "Resources" / "app.asar.unpacked" / "dist" / "daemon" / "node-entrypoint-runner.js"
        mjs_path = Path(__file__).resolve().with_name("paseo-daemon-helper.mjs")
        if helper.is_file() and os.access(helper, os.X_OK) and runner.is_file() and mjs_path.is_file():
            env = os.environ.copy()
            env["ELECTRON_RUN_AS_NODE"] = "1"
            env["PASEO_NODE_ENV"] = "production"
            asar_path = app_path / "Contents" / "Resources" / "app.asar"
            if asar_path.exists():
                env.setdefault("BEANBRIDGE_PASEO_ASAR", str(asar_path))
            return [str(helper), "--disable-warning=DEP0040", str(runner), "node-script", str(mjs_path)], env

    raise BridgeError("未找到 Paseo 内置运行时（Paseo Helper），请确认已安装 Paseo.app。")


def paseo_daemon_args() -> list[str]:
    args: list[str] = []
    host = os.environ.get("BEANBRIDGE_PASEO_HOST", "").strip()
    home = os.environ.get("BEANBRIDGE_PASEO_HOME", "").strip()
    if host:
        args.extend(["--host", host])
    elif home:
        args.extend(["--home", home])
    return args


def extract_json_object(raw: str) -> dict:
    stripped = raw.strip()
    if not stripped:
        raise BridgeError("Paseo 返回了空输出。")
    try:
        parsed = json.loads(stripped)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    for line in reversed(stripped.splitlines()):
        candidate = line.strip()
        if candidate.startswith("{") and candidate.endswith("}"):
            try:
                parsed = json.loads(candidate)
                if isinstance(parsed, dict):
                    return parsed
            except json.JSONDecodeError:
                continue
    raise BridgeError(f"无法解析 Paseo 返回的 JSON：{stripped[:200]}")


def ensure_daemon_started(cli: list[str]) -> None:
    if os.environ.get("BEANBRIDGE_PASEO_HOST", "").strip():
        return
    common = paseo_daemon_args()
    status_proc = subprocess.run(
        cli + ["daemon", "status", "--json"] + common,
        capture_output=True,
        text=True,
        timeout=8,
        check=False,
    )
    if status_proc.returncode == 0:
        return
    start_proc = subprocess.run(
        cli + ["daemon", "start"] + common,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if start_proc.returncode != 0:
        detail = (start_proc.stderr or start_proc.stdout or "").strip()
        raise BridgeError(f"无法启动 Paseo 后台服务：{detail or '未知错误'}")


def action_validate(agent_id_raw: str) -> dict:
    agent_id = validate_paseo_id(agent_id_raw)
    cli = resolve_paseo_cli()
    cmd = cli + ["inspect", agent_id, "--json"] + paseo_daemon_args()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False)
    except subprocess.TimeoutExpired as exc:
        raise BridgeError("校验 Paseo 对话超时，请确认 Paseo 服务响应正常。") from exc
    except OSError as exc:
        raise BridgeError(f"无法执行 paseo 命令：{exc}") from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise BridgeError(f"未找到该 Paseo 对话或无法访问：{detail or agent_id}")

    data = extract_json_object(proc.stdout)
    resolved_id = str(data.get("Id") or data.get("id") or "").strip()
    if not resolved_id:
        raise BridgeError("Paseo 返回的对话详情缺少 Id。")
    resolved_id = validate_paseo_id(resolved_id)
    if data.get("Archived") is True:
        raise BridgeError("该 Paseo 对话已归档，请新建对话或选择未归档的对话。")
    title_raw = str(data.get("Name") or data.get("Title") or data.get("title") or "").strip()
    title = title_raw or "Paseo 对话"
    return {"id": resolved_id, "title": title, "appID": "paseo"}


def action_create(receipt_raw: str, directory_raw: str | None, idempotency_key_raw: str | None) -> dict:
    receipt_path = validate_receipt_path(receipt_raw)
    existing = read_json_file(receipt_path)
    if isinstance(existing, dict):
        if existing.get("state") == "created":
            target = existing.get("target")
            if isinstance(target, dict) and isinstance(target.get("id"), str):
                target_id = validate_paseo_id(target["id"])
                return {
                    "id": target_id,
                    "title": str(target.get("title") or "新 Paseo 对话"),
                    "appID": "paseo",
                }
        raise ReceiptAlreadyExistsError("已存在未完成或异常的 Paseo 新建凭据，为防重复新建不会覆盖，请先检查或重连。")

    default_cwd = Path.home() / "Library" / "Application Support" / "AnkerVoiceBridge" / "PaseoVoice"
    cwd = Path(directory_raw).expanduser() if directory_raw else Path(os.environ.get("BEANBRIDGE_PASEO_CWD", "") or default_cwd)
    if not cwd.is_absolute():
        raise BridgeError("新建 Paseo 对话的工作目录必须是绝对路径。")
    ensure_private_dir(cwd)

    idempotency_key = (idempotency_key_raw or receipt_path.stem).strip() or receipt_path.stem
    idempotency_key = f"beanbridge-{idempotency_key}"

    claim_receipt(
        receipt_path,
        {
            "state": "creating",
            "appID": "paseo",
            "idempotencyKey": idempotency_key,
            "cwd": str(cwd),
            "createdAt": iso_now(),
        },
    )

    try:
        if not os.environ.get("BEANBRIDGE_PASEO_HELPER_CMD", "").strip():
            cli = resolve_paseo_cli()
            ensure_daemon_started(cli)
        runner_cmd, runner_env = resolve_paseo_node_runner()
        cmd = runner_cmd + [
            "create",
            "--cwd",
            str(cwd),
            "--idempotency-key",
            idempotency_key,
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=25, check=False, env=runner_env)
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "").strip()
            raise BridgeError(detail or "调用 Paseo 新建对话失败。")
        data = extract_json_object(proc.stdout)
        agent_id = validate_paseo_id(str(data.get("id") or ""))
        title = str(data.get("title") or "").strip() or "新 Paseo 对话"
        target = {"id": agent_id, "title": title, "appID": "paseo"}
        write_atomic_json(
            receipt_path,
            {
                "state": "created",
                "appID": "paseo",
                "idempotencyKey": idempotency_key,
                "target": target,
                "updatedAt": iso_now(),
            },
        )
        return target
    except subprocess.TimeoutExpired as exc:
        write_atomic_json(
            receipt_path,
            {
                "state": "uncertain",
                "appID": "paseo",
                "idempotencyKey": idempotency_key,
                "error": "新建 Paseo 对话请求超时，可能已在后台创建。",
                "updatedAt": iso_now(),
            },
        )
        raise BridgeError("新建 Paseo 对话超时，请打开 Paseo 检查是否已创建成功。") from exc
    except Exception:
        current = read_json_file(receipt_path)
        if isinstance(current, dict) and current.get("state") == "creating":
            try:
                receipt_path.unlink()
            except OSError:
                pass
        raise


def action_submit(agent_id_raw: str, text_raw: str, receipt_raw: str) -> dict:
    agent_id = validate_paseo_id(agent_id_raw)
    receipt_path = validate_receipt_path(receipt_raw)
    text = text_raw.strip()
    if not text:
        raise BridgeError("待发送语音内容为空。")

    claim_receipt(
        receipt_path,
        {
            "state": "submitting",
            "appID": "paseo",
            "targetID": agent_id,
            "createdAt": iso_now(),
        },
    )

    prompt_tmp_path: Path | None = None
    try:
        cli = resolve_paseo_cli()
        fd, tmp_name = tempfile.mkstemp(prefix="beanbridge-paseo-", suffix=".txt")
        prompt_tmp_path = Path(tmp_name)
        os.chmod(prompt_tmp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()

        cmd = cli + [
            "send",
            "--no-wait",
            "--json",
            "--behavior",
            "steer",
            "--prompt-file",
            str(prompt_tmp_path),
            agent_id,
        ] + paseo_daemon_args()

        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=20, check=False)
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "").strip()
            raise BridgeError(f"发送给 Paseo 失败：{detail or f'exit {proc.returncode}'}")

        data = extract_json_object(proc.stdout)
        status = str(data.get("status") or "").strip().lower()
        if status not in {"sent", "queued"}:
            raise BridgeError(f"Paseo 返回了未知投递状态：{status or 'empty'}")

        write_atomic_json(
            receipt_path,
            {
                "state": "submitted",
                "appID": "paseo",
                "targetID": agent_id,
                "deliveryStatus": status,
                "submittedAt": iso_now(),
            },
        )
        return {"receipt": str(receipt_path), "status": status}
    except subprocess.TimeoutExpired as exc:
        write_atomic_json(
            receipt_path,
            {
                "state": "uncertain",
                "appID": "paseo",
                "targetID": agent_id,
                "error": "发送 Paseo 消息超时，可能已投递到对话。",
                "updatedAt": iso_now(),
            },
        )
        raise BridgeError("发送 Paseo 消息超时（可能已送达），已保留在待发箱供核对。") from exc
    except Exception as exc:
        write_atomic_json(
            receipt_path,
            {
                "state": "uncertain",
                "appID": "paseo",
                "targetID": agent_id,
                "error": str(exc),
                "updatedAt": iso_now(),
            },
        )
        raise
    finally:
        if prompt_tmp_path is not None:
            try:
                prompt_tmp_path.unlink()
            except OSError:
                pass


def resolve_workspace_tab_from_snapshot(snapshot: dict, selected_labels: list[str]) -> dict:
    raw_agents = snapshot.get("agents")
    if not isinstance(raw_agents, list):
        raise BridgeError("Paseo 返回的工作区对话列表格式无效。")

    normalized_agents: list[dict[str, str]] = []
    for item in raw_agents:
        if not isinstance(item, dict):
            continue
        raw_id = str(item.get("id") or "").strip()
        if not raw_id:
            continue
        agent_id = validate_paseo_id(raw_id)
        title_candidate = normalize_tab_label(str(item.get("title") or ""))
        if not title_candidate:
            title_candidate = normalize_tab_label(str(item.get("name") or ""))
        if not title_candidate or title_candidate.lower() == "new agent":
            continue
        normalized_agents.append(
            {
                "id": agent_id,
                "title": title_candidate,
            }
        )

    seen_labels: set[str] = set()
    norm_labels: list[str] = []
    for raw in selected_labels:
        if not isinstance(raw, str):
            continue
        cleaned = normalize_tab_label(raw)
        if cleaned and cleaned not in seen_labels:
            seen_labels.add(cleaned)
            norm_labels.append(cleaned)

    if not norm_labels:
        raise BridgeError("已识别 Paseo 工作区页面，但未读取到已选中的标签文本。")

    matched_by_id: dict[str, dict[str, str]] = {}
    duplicate_title_labels: list[str] = []
    for label in norm_labels:
        hits = [agent for agent in normalized_agents if agent["title"] == label]
        if len(hits) > 1:
            duplicate_title_labels.append(label)
        elif len(hits) == 1:
            hit = hits[0]
            matched_by_id[hit["id"]] = hit

    if duplicate_title_labels:
        sample = duplicate_title_labels[0][:40]
        raise BridgeError(f"当前 Paseo 工作区存在多个同名对话（{sample}），无法仅凭标签唯一确认，请手动复制该对话链接后再试。")

    if len(matched_by_id) > 1:
        raise BridgeError(f"当前 Paseo 工作区同时选中了多个对话标签（{len(matched_by_id)} 个），无法自动判断目标，请关闭分屏或手动指定链接。")

    lower_labels = {lbl.lower() for lbl in norm_labels}
    has_blank_label = any(lbl in BLANK_TAB_LABELS for lbl in lower_labels)
    has_loading_label = any(lbl in GENERIC_AGENT_LOADING_LABELS for lbl in lower_labels)
    has_blocking_panel = any(lbl in NON_AGENT_BLOCKING_PANEL_LABELS for lbl in lower_labels)

    if len(matched_by_id) == 1:
        if has_blank_label or has_loading_label:
            raise BridgeError("检测到 Paseo 工作区同时存在已激活对话与新建/加载中标签，无法自动判断，请选定唯一对话后再试。")
        agent = next(iter(matched_by_id.values()))
        return {
            "kind": "agent",
            "id": agent["id"],
            "title": agent["title"],
            "appID": "paseo",
        }

    if has_loading_label:
        raise BridgeError("检测到 Paseo 对话标签仍在加载或尚未生成标题，无法自动区分；请等待标题加载完成后重试，或切到新建标签页。")

    if has_blank_label and not has_blocking_panel:
        return {"kind": "blank"}

    preview = " / ".join(lbl[:32] for lbl in norm_labels[:4])
    raise BridgeError(f"已识别 Paseo 工作区页面，但未从选中元素中匹配到唯一的对话标签（选中：{preview}）。")


def action_resolve_workspace_tab(workspace_id_raw: str, labels_json_raw: str) -> dict:
    workspace_id = validate_paseo_id(workspace_id_raw)
    try:
        parsed_labels = json.loads(labels_json_raw)
    except Exception as exc:
        raise BridgeError("无效的工作区选中标签参数（--labels-json）。") from exc
    if not isinstance(parsed_labels, list) or not all(isinstance(item, str) for item in parsed_labels):
        raise BridgeError("工作区选中标签参数必须是字符串数组。")

    if not os.environ.get("BEANBRIDGE_PASEO_HELPER_CMD", "").strip():
        cli = resolve_paseo_cli()
        ensure_daemon_started(cli)

    runner_cmd, runner_env = resolve_paseo_node_runner()
    cmd = runner_cmd + ["workspace-agents", "--workspace-id", workspace_id]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15, check=False, env=runner_env)
    except subprocess.TimeoutExpired as exc:
        raise BridgeError("查询 Paseo 工作区对话列表超时，请确认 Paseo 服务响应正常。") from exc
    except OSError as exc:
        raise BridgeError(f"无法执行 Paseo 内置运行时：{exc}") from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise BridgeError(detail or "查询 Paseo 工作区对话列表失败。")

    snapshot = extract_json_object(proc.stdout)
    return resolve_workspace_tab_from_snapshot(snapshot, parsed_labels)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Paseo bridge for BeanBridge")
    parser.add_argument(
        "--action",
        required=True,
        choices=["validate", "create", "submit", "resolve-workspace-tab"],
    )
    parser.add_argument("--id", help="Target Paseo agent ID")
    parser.add_argument("--text", help="Prompt text to send")
    parser.add_argument("--receipt", help="Absolute path to idempotency receipt JSON")
    parser.add_argument("--directory", help="Workspace directory when creating a new agent")
    parser.add_argument("--idempotency-key", help="Optional idempotency key for creation")
    parser.add_argument("--workspace-id", help="Workspace ID when resolving active workspace tab")
    parser.add_argument("--labels-json", help="JSON array of selected accessibility labels in the workspace window")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.action == "validate":
            if not args.id:
                raise BridgeError("validate 需要提供 --id。")
            result = action_validate(args.id)
        elif args.action == "create":
            if not args.receipt:
                raise BridgeError("create 需要提供 --receipt。")
            result = action_create(args.receipt, args.directory, args.idempotency_key)
        elif args.action == "submit":
            if not args.id or not args.receipt or args.text is None:
                raise BridgeError("submit 需要提供 --id、--text 和 --receipt。")
            result = action_submit(args.id, args.text, args.receipt)
        elif args.action == "resolve-workspace-tab":
            if not args.workspace_id or args.labels_json is None:
                raise BridgeError("resolve-workspace-tab 需要提供 --workspace-id 和 --labels-json。")
            result = action_resolve_workspace_tab(args.workspace_id, args.labels_json)
        else:
            raise BridgeError(f"不支持的 action：{args.action}")
        sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
        return 0
    except BridgeError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
