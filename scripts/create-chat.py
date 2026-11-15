#!/usr/bin/env python3
"""Create one durable projectless chat, recording its ID before closing the server."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import uuid


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, ensure_ascii=False)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def create_chat(executable, directory, receipt):
    # Never repeat a creation request after a crash or an unknown response.
    receipt.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump({'state': 'creating', 'cwd': str(directory)}, output)
        output.flush()
        os.fsync(output.fileno())
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    process = subprocess.Popen([executable, 'app-server', '--listen', 'stdio://'],
                               cwd=directory, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, bufsize=1)
    responses = queue.Queue()

    def read():
        for line in process.stdout:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if 'id' in message:
                responses.put(message)
        responses.put(None)

    def request(request_id, method, params):
        process.stdin.write(json.dumps({'id': request_id, 'method': method, 'params': params}) + '\n')
        process.stdin.flush()
        deadline = time.monotonic() + 20
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('创建会话超时，不会自动重试')
            message = responses.get(timeout=remaining)
            if message is None:
                raise RuntimeError('创建服务提前退出')
            if message.get('id') == request_id:
                if 'error' in message:
                    raise RuntimeError(message['error'].get('message', 'app-server error'))
                return message['result']

    try:
        threading.Thread(target=read, daemon=True).start()
        request(1, 'initialize', {'clientInfo': {'name': 'beanbridge', 'title': 'BeanBridge', 'version': '0.3'}})
        process.stdin.write('{"method":"initialized"}\n')
        process.stdin.flush()
        result = request(2, 'thread/start', {'cwd': str(directory), 'ephemeral': False})
        thread = result['thread']
        thread_id = str(uuid.UUID(thread['id']))
        if thread.get('projectId') is not None:
            raise RuntimeError('新会话意外绑定了项目')
        target = {'id': thread_id, 'title': '语音新对话'}
        # Persist immediately, before optional naming or any desktop action.
        atomic_json(receipt, {'state': 'created', 'target': target, 'cwd': str(directory)})
        request(3, 'thread/name/set', {'threadId': thread_id, 'name': '语音新对话'})
        return target
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--codex', required=True)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--receipt', required=True, type=Path)
    args = parser.parse_args()
    if not args.directory.is_absolute() or not args.receipt.is_absolute():
        parser.error('directory and receipt must be absolute')
    try:
        print(json.dumps(create_chat(args.codex, args.directory, args.receipt), ensure_ascii=False))
    except Exception as error:
        parser.exit(1, f'未确认创建完成，不会重试：{error}\n')


if __name__ == '__main__':
    main()
