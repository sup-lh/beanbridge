import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).with_name('doubao-chat.py')
spec = importlib.util.spec_from_file_location('doubao_chat', SCRIPT_PATH)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class DoubaoChatBridgeTests(unittest.TestCase):
    def test_validate_accepts_valid_id_and_rejects_traversal_or_invalid_chars(self):
        with patch.dict(os.environ, {'BEANBRIDGE_DOUBAO_BRIDGE_CMD': ''}, clear=False):
            target = helper.validate_chat('38492019482')
            self.assertEqual(target['id'], '38492019482')
            self.assertEqual(target['appID'], 'doubao')
            self.assertTrue(target['title'])

        for bad in ('', '   ', '.', '..', '../123', 'a..b', '123/456', '123\\456', 'new', 'NEW', 'a?b=1', 'a#b'):
            with self.assertRaises(ValueError, msg=bad):
                helper.validate_chat_id(bad)

    def test_existing_creation_claim_prevents_duplicate_side_effects(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = Path(root) / 'Creation' / 'receipt.json'
            receipt.parent.mkdir(parents=True)
            receipt.write_text('{"state":"creating"}', encoding='utf-8')
            with patch.object(helper.subprocess, 'run') as run_mock:
                with self.assertRaises(FileExistsError):
                    helper.create_chat(receipt)
                run_mock.assert_not_called()

    def test_failed_creation_leaves_private_creating_claim(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = Path(root) / 'Creation' / 'receipt.json'
            with patch.dict(os.environ, {'BEANBRIDGE_DOUBAO_BRIDGE_CMD': ''}, clear=False):
                with patch.object(helper, 'find_doubao_bundle', side_effect=RuntimeError('not installed')):
                    with self.assertRaises(RuntimeError):
                        helper.create_chat(receipt)
            self.assertEqual(json.loads(receipt.read_text(encoding='utf-8'))['state'], 'creating')
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
            self.assertEqual(receipt.parent.stat().st_mode & 0o777, 0o700)

    def test_create_with_native_bundle_persists_created_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = Path(root) / 'Creation' / 'receipt.json'
            completed = subprocess.CompletedProcess(args=['open'], returncode=0, stdout='', stderr='')
            with patch.dict(os.environ, {'BEANBRIDGE_DOUBAO_BRIDGE_CMD': ''}, clear=False):
                with patch.object(
                    helper,
                    'find_doubao_bundle',
                    return_value=('com.work.pc.doubao', Path('/Applications/DoubaoWork.app'), ['doubaowork']),
                ):
                    with patch.object(helper.subprocess, 'run', return_value=completed) as run_mock:
                        target = helper.create_chat(receipt)
            run_mock.assert_called_once()
            self.assertEqual(
                run_mock.call_args.args[0],
                ['/usr/bin/open', '-b', 'com.work.pc.doubao'],
            )
            self.assertEqual(target['appID'], 'doubao')
            stored = json.loads(receipt.read_text(encoding='utf-8'))
            self.assertEqual(stored['state'], 'created')
            self.assertEqual(stored['target'], target)
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)

    def test_submit_without_confirmed_bridge_exits_nonzero_and_marks_uncertain(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = Path(root) / 'Submissions' / 'sub.json'
            env = os.environ.copy()
            env.pop('BEANBRIDGE_DOUBAO_BRIDGE_CMD', None)
            env.pop('BEANBRIDGE_DOUBAO_AX_SUBMIT', None)
            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    '--action', 'submit',
                    '--id', 'chat_998877',
                    '--text', '测试未确认投递不丢字',
                    '--receipt', str(receipt),
                ],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn('未确认', proc.stderr)
            saved = json.loads(receipt.read_text(encoding='utf-8'))
            self.assertEqual(saved['state'], 'uncertain')
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)

    def test_submit_with_confirmed_external_bridge_succeeds_and_records_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            stub = Path(root) / 'bridge_stub.py'
            stub.write_text(
                '#!/usr/bin/env python3\n'
                'import json, os\n'
                'assert os.environ["BEANBRIDGE_DOUBAO_ACTION"] == "submit"\n'
                'assert os.environ["BEANBRIDGE_DOUBAO_CHAT_ID"] == "chat_123"\n'
                'assert "$(literal)" in os.environ["BEANBRIDGE_DOUBAO_TEXT"]\n'
                'print(json.dumps({"confirmed": True, "receipt": "豆包桥接已确认发送"}))\n',
                encoding='utf-8',
            )
            stub.chmod(0o700)
            receipt = Path(root) / 'Submissions' / 'ok.json'
            env = os.environ.copy()
            env['BEANBRIDGE_DOUBAO_BRIDGE_CMD'] = f'{sys.executable} {stub}'
            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    '--action', 'submit',
                    '--id', 'chat_123',
                    '--text', '包含换行\n与 $(literal) 的安全文本',
                    '--receipt', str(receipt),
                ],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            payload = json.loads(proc.stdout)
            self.assertEqual(payload['state'], 'submitted')
            self.assertEqual(payload['receipt'], '豆包桥接已确认发送')
            saved = json.loads(receipt.read_text(encoding='utf-8'))
            self.assertEqual(saved['state'], 'submitted')
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)

    def test_validate_doubaowork_active_returns_descriptive_title(self):
        with tempfile.TemporaryDirectory() as root:
            target = helper.validate_chat('doubaowork-active', support_dir=Path(root))
            self.assertEqual(target['id'], 'doubaowork-active')
            self.assertEqual(target['title'], '豆包工作 · 当前窗口')
            self.assertEqual(target['appID'], 'doubao')


if __name__ == '__main__':
    unittest.main()
