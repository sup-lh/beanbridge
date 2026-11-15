#!/usr/bin/env python3
"""Validate, create, and submit Doubao desktop conversations with atomic receipts."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import uuid

APP_ID = 'doubao'
DEFAULT_BUNDLE_IDS = (
    'com.bot.pc.doubao',
    'com.work.pc.doubao',
    'com.bytedance.doubao',
)
VALID_ID_RE = re.compile(r'^[A-Za-z0-9._-]{1,128}$')
SUPPORT = Path.home() / 'Library/Application Support/AnkerVoiceBridge'


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(value, output, ensure_ascii=False)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def claim_exclusive_receipt(receipt: Path, payload: dict) -> None:
    if not receipt.is_absolute():
        raise ValueError('receipt must be an absolute path')
    receipt.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(receipt.parent, 0o700)
    fd = os.open(receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        json.dump(payload, output, ensure_ascii=False)
        output.flush()
        os.fsync(output.fileno())


def validate_chat_id(raw_id: str) -> str:
    if not isinstance(raw_id, str):
        raise ValueError('必须提供有效的豆包会话 ID')
    chat_id = raw_id.strip()
    if (
        not chat_id
        or chat_id in ('.', '..')
        or '..' in chat_id
        or '/' in chat_id
        or '\\' in chat_id
        or chat_id.lower() == 'new'
        or not VALID_ID_RE.match(chat_id)
    ):
        raise ValueError('豆包会话 ID 格式无效')
    return chat_id


def candidate_bundle_ids(explicit_bundle_id: str | None = None) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for source in (explicit_bundle_id, os.environ.get('BEANBRIDGE_DOUBAO_BUNDLE_ID')):
        if source:
            for item in source.split(','):
                trimmed = item.strip()
                if trimmed and trimmed not in seen:
                    seen.add(trimmed)
                    ordered.append(trimmed)
    for builtin in DEFAULT_BUNDLE_IDS:
        if builtin not in seen:
            seen.add(builtin)
            ordered.append(builtin)
    return ordered


def _read_bundle_info(app_path: Path) -> tuple[str | None, list[str]]:
    info_plist = app_path / 'Contents/Info.plist'
    if not info_plist.is_file():
        return None, []
    try:
        with info_plist.open('rb') as handle:
            info = plistlib.load(handle)
    except Exception:
        return None, []
    bundle_id = info.get('CFBundleIdentifier')
    schemes: list[str] = []
    for entry in info.get('CFBundleURLTypes') or []:
        if isinstance(entry, dict):
            for scheme in entry.get('CFBundleURLSchemes') or []:
                if isinstance(scheme, str) and scheme not in schemes:
                    schemes.append(scheme)
    return (bundle_id if isinstance(bundle_id, str) else None), schemes


def find_doubao_bundle(preferred_bundle_id: str | None = None) -> tuple[str, Path, list[str]]:
    candidates = candidate_bundle_ids(preferred_bundle_id)
    app_roots = [Path('/Applications'), Path.home() / 'Applications']
    discovered: dict[str, tuple[Path, list[str]]] = {}
    for root in app_roots:
        if not root.is_dir():
            continue
        try:
            entries = list(root.iterdir())
        except OSError:
            continue
        for entry in entries:
            if entry.suffix == '.app':
                bid, schemes = _read_bundle_info(entry)
                if bid and bid not in discovered:
                    discovered[bid] = (entry, schemes)

    for bid in candidates:
        if bid in discovered:
            app_path, schemes = discovered[bid]
            return bid, app_path, schemes

    for bid in candidates:
        try:
            proc = subprocess.run(
                ['/usr/bin/mdfind', f"kMDItemCFBundleIdentifier == '{bid}'"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except OSError:
            proc = None
        if proc and proc.returncode == 0:
            for line in proc.stdout.splitlines():
                candidate_path = Path(line.strip())
                if candidate_path.is_dir():
                    _, schemes = _read_bundle_info(candidate_path)
                    return bid, candidate_path, schemes

    raise RuntimeError(
        '未找到已安装的豆包 macOS 客户端（支持 com.bot.pc.doubao / com.work.pc.doubao / com.bytedance.doubao）'
    )


def run_external_bridge(
    bridge_cmd: str,
    action: str,
    chat_id: str | None = None,
    text: str | None = None,
    receipt: Path | None = None,
    bundle_id: str | None = None,
) -> str:
    argv = shlex.split(bridge_cmd)
    if not argv:
        raise RuntimeError('BEANBRIDGE_DOUBAO_BRIDGE_CMD 配置为空')
    argv.extend(['--action', action])
    if chat_id is not None:
        argv.extend(['--id', chat_id])
    if text is not None:
        argv.extend(['--text', text])
    if receipt is not None:
        argv.extend(['--receipt', str(receipt)])
    if bundle_id:
        argv.extend(['--bundle-id', bundle_id])

    env = os.environ.copy()
    env['BEANBRIDGE_DOUBAO_ACTION'] = action
    if chat_id is not None:
        env['BEANBRIDGE_DOUBAO_CHAT_ID'] = chat_id
    if text is not None:
        env['BEANBRIDGE_DOUBAO_TEXT'] = text
    if receipt is not None:
        env['BEANBRIDGE_DOUBAO_RECEIPT'] = str(receipt)
    if bundle_id:
        env['BEANBRIDGE_DOUBAO_BUNDLE_ID'] = bundle_id

    result = subprocess.run(
        argv,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f'状态码 {result.returncode}'
        raise RuntimeError(f'豆包外部桥接失败：{detail}')
    return result.stdout


def validate_chat(raw_id: str, bundle_id: str | None = None, support_dir: Path = SUPPORT) -> dict:
    chat_id = validate_chat_id(raw_id)
    bridge_cmd = os.environ.get('BEANBRIDGE_DOUBAO_BRIDGE_CMD', '').strip()
    if bridge_cmd:
        stdout = run_external_bridge(
            bridge_cmd,
            action='validate',
            chat_id=chat_id,
            bundle_id=bundle_id,
        ).strip()
        if stdout:
            try:
                data = json.loads(stdout)
            except json.JSONDecodeError:
                return {'id': chat_id, 'title': stdout, 'appID': APP_ID}
            if isinstance(data, dict):
                returned_id = validate_chat_id(str(data.get('id', chat_id)))
                if returned_id != chat_id:
                    raise RuntimeError('外部桥接返回的会话 ID 与请求不一致')
                title = str(data.get('title') or '').strip() or f'豆包对话 {chat_id[:12]}'
                return {'id': chat_id, 'title': title, 'appID': APP_ID}

    metadata_file = support_dir / 'Chats' / f'doubao-{chat_id}.json'
    if metadata_file.is_file():
        try:
            saved = json.loads(metadata_file.read_text(encoding='utf-8'))
            if isinstance(saved, dict) and saved.get('id') == chat_id and saved.get('title'):
                return {'id': chat_id, 'title': str(saved['title']), 'appID': APP_ID}
        except Exception:
            pass

    if chat_id == 'doubaowork-active':
        return {'id': chat_id, 'title': '豆包工作 · 当前窗口', 'appID': APP_ID}

    short_id = chat_id if len(chat_id) <= 12 else chat_id[:12]
    return {'id': chat_id, 'title': f'豆包对话 {short_id}', 'appID': APP_ID}


def create_chat(
    receipt: Path,
    bundle_id: str | None = None,
    chat_id: str | None = None,
) -> dict:
    # Never repeat a creation request after a crash or an unknown response.
    claim_exclusive_receipt(receipt, {'state': 'creating', 'appID': APP_ID})

    bridge_cmd = os.environ.get('BEANBRIDGE_DOUBAO_BRIDGE_CMD', '').strip()
    if bridge_cmd:
        stdout = run_external_bridge(
            bridge_cmd,
            action='create',
            chat_id=chat_id,
            receipt=receipt,
            bundle_id=bundle_id,
        ).strip()
        if not stdout:
            raise RuntimeError('外部桥接未返回新建会话回执')
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError('外部桥接返回的创建结果不是合法 JSON') from exc
        if not isinstance(payload, dict):
            raise RuntimeError('外部桥接返回的创建结果格式无效')
        target_info = payload.get('target') if isinstance(payload.get('target'), dict) else payload
        created_id = validate_chat_id(str(target_info.get('id') or ''))
        title = str(target_info.get('title') or '豆包语音新对话').strip() or '豆包语音新对话'
        target = {'id': created_id, 'title': title, 'appID': APP_ID}
        atomic_json(receipt, {'state': 'created', 'target': target, 'appID': APP_ID})
        _persist_chat_metadata(receipt.parent.parent, target)
        return target

    resolved_bundle_id, _, schemes = find_doubao_bundle(bundle_id)
    preferred_scheme = None
    for scheme_candidate in ('doubaowork', 'doubao'):
        if scheme_candidate in schemes:
            preferred_scheme = scheme_candidate
            break

    launched = False
    if preferred_scheme and preferred_scheme != 'doubaowork':
        # Note: passing doubaowork:// to /usr/bin/open spawns an extra Chrome-framed DoubaoWork Browser
        # window (--saman-launched-by-url). For com.work.pc.doubao, activate/launch the app directly
        # and let in-process AX trigger "新工作任务" inside the single native window.
        deep_link = f'{preferred_scheme}://chat/new'
        res = subprocess.run(
            ['/usr/bin/open', '-b', resolved_bundle_id, deep_link],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        launched = res.returncode == 0

    if not launched:
        res = subprocess.run(
            ['/usr/bin/open', '-b', resolved_bundle_id],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if res.returncode != 0:
            detail = res.stderr.strip() or f'open 退出码 {res.returncode}'
            raise RuntimeError(f'无法唤起豆包客户端（{resolved_bundle_id}）：{detail}')

    created_id = validate_chat_id(chat_id) if chat_id else f'doubao-{uuid.uuid4()}'
    target = {'id': created_id, 'title': '豆包语音新对话', 'appID': APP_ID}
    atomic_json(
        receipt,
        {
            'state': 'created',
            'target': target,
            'appID': APP_ID,
            'bundleID': resolved_bundle_id,
            'scheme': preferred_scheme,
        },
    )
    _persist_chat_metadata(receipt.parent.parent, target)
    return target


def _persist_chat_metadata(support_dir: Path, target: dict) -> None:
    try:
        chats_dir = support_dir / 'Chats'
        atomic_json(chats_dir / f"doubao-{target['id']}.json", target)
    except OSError:
        pass


def _try_verified_ax_submit(chat_id: str, text: str, bundle_id: str | None) -> str:
    candidates = candidate_bundle_ids(bundle_id)
    script = r'''
ObjC.import('stdlib');
const se = Application('System Events');
const front = se.applicationProcesses.whose({ frontmost: true });
if (front.length !== 1) { throw new Error('前台应用不唯一'); }
const proc = front[0];
const bid = proc.bundleIdentifier();
const allowed = JSON.parse($.getenv('BEANBRIDGE_AX_ALLOWED_BUNDLES'));
if (!allowed.includes(bid)) { throw new Error('豆包不在前台，拒绝盲发'); }
const wins = proc.windows();
if (wins.length !== 1) { throw new Error('豆包窗口不唯一'); }
const win = wins[0];
const chatId = $.getenv('BEANBRIDGE_AX_CHAT_ID');
let doc = '';
try { doc = String(win.attributes.byName('AXDocument').value() || ''); } catch (_) {}
const matchesDoc = doc && (doc.endsWith('/chat/' + chatId) || doc.endsWith('/thread/' + chatId));

function collectMatches(root, predicate, limit) {
    const queue = [root];
    const out = [];
    let visited = 0;
    while (queue.length > 0 && visited < 1500) {
        const node = queue.shift();
        visited++;
        try {
            if (predicate(node)) {
                out.push(node);
                if (limit && out.length >= limit) break;
            }
            const children = node.uiElements ? node.uiElements() : [];
            for (let i = 0; i < children.length; i++) queue.push(children[i]);
        } catch (_) {}
    }
    return out;
}

let matchesURL = matchesDoc;
if (!matchesURL && (chatId === 'doubaowork-active' || chatId.startsWith('doubao-'))) {
    const webAreas = collectMatches(win, (n) => {
        try {
            if (String(n.role()) !== 'AXWebArea') return false;
            const u = String(n.attributes.byName('AXURL').value() || '');
            return u.startsWith('chrome://doubaowork-chat') || u.startsWith('doubaowork://doubaowork-chat');
        } catch (_) { return false; }
    }, 1);
    matchesURL = webAreas.length > 0;
}
if (!matchesURL) {
    throw new Error('无法通过 AX 校验当前窗口对应目标会话 ID');
}
let targetInput = null;
try {
    const focused = se.attributes.byName('AXFocusedUIElement').value();
    if (focused && String(focused.role()) === 'AXTextArea') targetInput = focused;
} catch (_) {}
if (!targetInput) {
    const areas = collectMatches(win, (n) => {
        try { return String(n.role()) === 'AXTextArea'; } catch (_) { return false; }
    }, 1);
    if (areas.length > 0) targetInput = areas[0];
}
if (!targetInput) {
    throw new Error('焦点或窗口中未找到可验证的输入框');
}
const message = $.getenv('BEANBRIDGE_AX_TEXT');
targetInput.value = message;
if (String(targetInput.value() || '') !== message) {
    throw new Error('输入框内容校验不一致，已中止发送');
}
se.keyCode(36);
delay(0.4);
if (String(targetInput.value() || '').trim() !== '') {
    throw new Error('回车后输入框未清空，无法确认消息已真实发送');
}
JSON.stringify({ receipt: '已通过可验证 AX 发送至豆包会话 ' + chatId });
'''
    env = os.environ.copy()
    env['BEANBRIDGE_AX_ALLOWED_BUNDLES'] = json.dumps(candidates)
    env['BEANBRIDGE_AX_CHAT_ID'] = chat_id
    env['BEANBRIDGE_AX_TEXT'] = text
    res = subprocess.run(
        ['/usr/bin/osascript', '-l', 'JavaScript', '-e', script],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
        check=False,
    )
    if res.returncode != 0:
        detail = res.stderr.strip() or res.stdout.strip() or f'osascript 状态码 {res.returncode}'
        raise RuntimeError(f'UI/AX 投递未确认：{detail}')
    parsed = json.loads(res.stdout.strip())
    receipt_text = str(parsed.get('receipt') or '').strip()
    if not receipt_text:
        raise RuntimeError('UI/AX 未返回有效投递确认回执')
    return receipt_text


def submit_chat(
    raw_id: str,
    text: str,
    receipt: Path | None = None,
    bundle_id: str | None = None,
) -> dict:
    chat_id = validate_chat_id(raw_id)
    if not isinstance(text, str) or not text.strip():
        raise ValueError('投递文字不能为空')

    if receipt is not None:
        claim_exclusive_receipt(
            receipt,
            {'state': 'submitting', 'appID': APP_ID, 'id': chat_id},
        )

    bridge_cmd = os.environ.get('BEANBRIDGE_DOUBAO_BRIDGE_CMD', '').strip()
    try:
        if bridge_cmd:
            stdout = run_external_bridge(
                bridge_cmd,
                action='submit',
                chat_id=chat_id,
                text=text,
                receipt=receipt,
                bundle_id=bundle_id,
            ).strip()
            if not stdout:
                raise RuntimeError('外部桥接未返回投递确认回执')
            try:
                data = json.loads(stdout)
            except json.JSONDecodeError:
                note = stdout
            else:
                if not isinstance(data, dict):
                    raise RuntimeError('外部桥接投递回执格式无效')
                if data.get('confirmed') is False or data.get('ok') is False or data.get('error'):
                    raise RuntimeError(str(data.get('error') or '外部桥接报告消息投递未确认'))
                note = str(
                    data.get('receipt')
                    or data.get('message')
                    or data.get('note')
                    or f'已投递至豆包会话 {chat_id}'
                ).strip()
                if not note:
                    raise RuntimeError('外部桥接返回的投递回执为空')
        elif os.environ.get('BEANBRIDGE_DOUBAO_AX_SUBMIT') == '1':
            note = _try_verified_ax_submit(chat_id, text, bundle_id)
        else:
            raise RuntimeError(
                f'无法确认豆包会话（{chat_id}）的消息已真实发送成功：'
                '未配置可确认回执的外部桥接（BEANBRIDGE_DOUBAO_BRIDGE_CMD）或可验证的 UI/AX 发送路径；'
                '消息已保留为待核对状态，绝不静默丢弃或误报成功'
            )
    except Exception as error:
        if receipt is not None and receipt.exists():
            try:
                atomic_json(
                    receipt,
                    {
                        'state': 'uncertain',
                        'appID': APP_ID,
                        'id': chat_id,
                        'error': str(error),
                    },
                )
            except OSError:
                pass
        raise

    result = {
        'state': 'submitted',
        'id': chat_id,
        'appID': APP_ID,
        'receipt': note,
    }
    if receipt is not None:
        atomic_json(receipt, result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description='Doubao desktop conversation bridge for BeanBridge.')
    parser.add_argument('--action', required=True, choices=('validate', 'create', 'submit'))
    parser.add_argument('--id', dest='chat_id')
    parser.add_argument('--text')
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--bundle-id', default=os.environ.get('BEANBRIDGE_DOUBAO_BUNDLE_ID'))
    args = parser.parse_args()

    if args.receipt is not None and not args.receipt.is_absolute():
        parser.error('--receipt must be an absolute path')

    if args.action == 'validate':
        if not args.chat_id:
            parser.error('--action validate 需要提供 --id')
        try:
            print(json.dumps(validate_chat(args.chat_id, args.bundle_id), ensure_ascii=False))
        except Exception as error:
            parser.exit(1, f'豆包会话校验失败：{error}\n')
        return

    if args.action == 'create':
        if args.receipt is None:
            parser.error('--action create 需要提供绝对路径 --receipt')
        try:
            target = create_chat(args.receipt, bundle_id=args.bundle_id, chat_id=args.chat_id)
            print(json.dumps(target, ensure_ascii=False))
        except Exception as error:
            parser.exit(1, f'未确认豆包新会话创建完成，不会重试：{error}\n')
        return

    if args.action == 'submit':
        if not args.chat_id:
            parser.error('--action submit 需要提供 --id')
        if args.text is None or not args.text.strip():
            parser.error('--action submit 需要提供非空 --text')
        try:
            result = submit_chat(
                args.chat_id,
                args.text,
                receipt=args.receipt,
                bundle_id=args.bundle_id,
            )
            print(json.dumps(result, ensure_ascii=False))
        except Exception as error:
            parser.exit(1, f'未确认豆包消息投递成功，请人工核对：{error}\n')


if __name__ == '__main__':
    main()
