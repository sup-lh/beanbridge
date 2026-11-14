#!/usr/bin/env python3
"""Bind BeanBridge to an explicitly chosen, locally readable Codex thread."""
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import uuid

SUPPORT = Path.home() / "Library/Application Support/AnkerVoiceBridge"
DESKTOP_CODEX = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")


def codex_executable():
    override = os.environ.get("BEANBRIDGE_CODEX")
    if override:
        return override
    return str(DESKTOP_CODEX) if DESKTOP_CODEX.is_file() else shutil.which("codex")


def validate_thread(executable, thread_id):
    process = subprocess.Popen([executable, "app-server", "--listen", "stdio://"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, bufsize=1)
    responses = queue.Queue()

    def read_responses():
        for line in process.stdout:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "id" in message:
                responses.put(message)

    def send(message):
        process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        process.stdin.flush()

    def expect(request_id):
        while True:
            response = responses.get(timeout=20)
            if response.get("id") == request_id:
                if "error" in response:
                    raise RuntimeError(response["error"].get("message", "app-server error"))
                return response.get("result", {})

    try:
        threading.Thread(target=read_responses, daemon=True).start()
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {
            "name": "beanbridge_setup", "title": "BeanBridge setup", "version": "0.1"}}})
        expect(1)
        send({"method": "initialized", "params": {}})
        send({"id": 2, "method": "thread/read", "params": {"threadId": thread_id, "includeTurns": False}})
        thread = expect(2).get("thread", {})
        if thread.get("id") != thread_id:
            raise RuntimeError("返回的会话与指定 ID 不一致")
        return thread.get("name") or "未命名对话"
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description="Set the exact Codex conversation for voice messages.")
    parser.add_argument("--thread-id", default=os.environ.get("CODEX_THREAD_ID"))
    parser.add_argument("--check", action="store_true", help="Validate only; do not change the target.")
    args = parser.parse_args()
    if not args.thread_id:
        parser.error("请在目标 Codex 对话中运行，或用 --thread-id 指定会话 UUID")
    try:
        thread_id = str(uuid.UUID(args.thread_id))
    except ValueError:
        parser.error("--thread-id 不是有效的 UUID")
    executable = codex_executable()
    if not executable or not os.access(executable, os.X_OK):
        parser.error("找不到 codex；可通过 BEANBRIDGE_CODEX 指定可执行文件")
    try:
        title = validate_thread(executable, thread_id)
    except (OSError, RuntimeError, queue.Empty) as error:
        parser.exit(1, f"无法验证会话，未修改目标：{error}\n")
    if args.check:
        print(f"会话可访问：{title}；目标文件未修改。")
        return
    SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(SUPPORT, 0o700)
    temporary = SUPPORT / f".target-thread.{uuid.uuid4().hex}.tmp"
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(thread_id + "\n")
        os.replace(temporary, SUPPORT / "target-thread")
    finally:
        temporary.unlink(missing_ok=True)
    print(f"已绑定 Codex 对话：{title}")
    print("如按键应用已运行，请关闭后重新打开；语音会自动进入这个会话的队列。")


if __name__ == "__main__":
    main()
