import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('create_chat', Path(__file__).with_name('create-chat.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class CreationTests(unittest.TestCase):
    def test_existing_claim_cannot_start_another_process(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = Path(root) / 'receipt.json'
            receipt.write_text('{"state":"creating"}')
            with patch.object(helper.subprocess, 'Popen') as popen:
                with self.assertRaises(FileExistsError):
                    helper.create_chat('/unused', Path(root) / 'chat', receipt)
                popen.assert_not_called()

    def test_start_failure_leaves_creation_claim(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = Path(root) / 'receipt.json'
            with patch.object(helper.subprocess, 'Popen', side_effect=OSError('unavailable')):
                with self.assertRaises(OSError):
                    helper.create_chat('/unused', Path(root) / 'chat', receipt)
            self.assertEqual(json.loads(receipt.read_text())['state'], 'creating')
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)

    def test_acknowledgement_replaces_claim_atomically(self):
        with tempfile.TemporaryDirectory() as root:
            receipt = Path(root) / 'receipt.json'
            receipt.write_text('{"state":"creating"}')
            result = {'state': 'created', 'target': {'id': 'acknowledged'}}
            helper.atomic_json(receipt, result)
            self.assertEqual(json.loads(receipt.read_text()), result)
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(list(Path(root).iterdir())), 1)


if __name__ == '__main__':
    unittest.main()
