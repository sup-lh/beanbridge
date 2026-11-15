#!/usr/bin/env python3
"""Offline unit tests for scripts/paseo-chat.py."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest


SCRIPT_PATH = Path(__file__).resolve().with_name("paseo-chat.py")
SPEC = importlib.util.spec_from_file_location("paseo_chat", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
PASEO_CHAT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PASEO_CHAT)


class PaseoChatTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmpdir.name)
        self.old_env = os.environ.copy()

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.tmpdir.cleanup()

    def _write_fake_cli(self, body: str) -> Path:
        cli = self.root / "fake-paseo.sh"
        cli.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        cli.chmod(0o755)
        os.environ["BEANBRIDGE_PASEO_CLI"] = str(cli)
        return cli

    def test_validate_paseo_id_rejects_traversal_and_bad_chars(self) -> None:
        self.assertEqual(
            PASEO_CHAT.validate_paseo_id("3a45eaca-18bf-43a2-94f1-d6bd227d5225"),
            "3a45eaca-18bf-43a2-94f1-d6bd227d5225",
        )
        for bad in ["../etc", "a/b", "abc", ".hidden", "agent with space", "id?x=1", "id#frag"]:
            with self.assertRaises(PASEO_CHAT.BridgeError):
                PASEO_CHAT.validate_paseo_id(bad)

    def test_validate_parses_inspect_json_and_rejects_archived(self) -> None:
        log_file = self.root / "args.log"
        self._write_fake_cli(
            f'''echo "$@" > "{log_file}"
cat <<'JSON'
{{"Id": "3a45eaca-18bf-43a2-94f1-d6bd227d5225", "Name": "修复语音路由", "Archived": false}}
JSON'''
        )
        res = PASEO_CHAT.action_validate("3a45eaca-18bf-43a2-94f1-d6bd227d5225")
        self.assertEqual(
            res,
            {"id": "3a45eaca-18bf-43a2-94f1-d6bd227d5225", "title": "修复语音路由", "appID": "paseo"},
        )
        self.assertIn("inspect 3a45eaca-18bf-43a2-94f1-d6bd227d5225 --json", log_file.read_text(encoding="utf-8"))

        self._write_fake_cli(
            'echo \'{"Id": "3a45eaca-18bf-43a2-94f1-d6bd227d5225", "Name": "Old", "Archived": true}\''
        )
        with self.assertRaises(PASEO_CHAT.BridgeError):
            PASEO_CHAT.action_validate("3a45eaca-18bf-43a2-94f1-d6bd227d5225")

    def test_create_idempotent_receipt_permissions_and_failure_cleanup(self) -> None:
        helper = self.root / "fake-helper.py"
        helper_log = self.root / "helper-calls.log"
        helper.write_text(
            f'''#!/usr/bin/env python3
import json, sys
with open("{helper_log}", "a", encoding="utf-8") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
print(json.dumps({{"id": "agent-created-001", "title": "新 Paseo 对话", "appID": "paseo"}}))
''',
            encoding="utf-8",
        )
        helper.chmod(0o755)
        os.environ["BEANBRIDGE_PASEO_HELPER_CMD"] = str(helper)

        receipt = self.root / "Creation" / "msg-123.json"
        workspace_dir = self.root / "PaseoVoice"
        first = PASEO_CHAT.action_create(str(receipt), str(workspace_dir), "msg-123")
        self.assertEqual(first["id"], "agent-created-001")
        self.assertEqual(first["appID"], "paseo")
        self.assertTrue(receipt.exists())
        mode = stat.S_IMODE(receipt.stat().st_mode)
        self.assertEqual(mode, 0o600)
        dir_mode = stat.S_IMODE(receipt.parent.stat().st_mode)
        self.assertEqual(dir_mode, 0o700)

        # Second call with same receipt returns stored target without invoking helper again
        second = PASEO_CHAT.action_create(str(receipt), str(workspace_dir), "msg-123")
        self.assertEqual(second, first)
        self.assertEqual(len(helper_log.read_text(encoding="utf-8").strip().splitlines()), 1)

        # Failure cleans up initial creating receipt so user can retry
        failing_helper = self.root / "fail-helper.sh"
        failing_helper.write_text("#!/bin/sh\necho 'daemon down' >&2\nexit 1\n", encoding="utf-8")
        failing_helper.chmod(0o755)
        os.environ["BEANBRIDGE_PASEO_HELPER_CMD"] = str(failing_helper)
        fail_receipt = self.root / "Creation" / "msg-fail.json"
        with self.assertRaises(PASEO_CHAT.BridgeError):
            PASEO_CHAT.action_create(str(fail_receipt), str(workspace_dir), "msg-fail")
        self.assertFalse(fail_receipt.exists())

    def test_submit_uses_prompt_file_steer_and_prevents_duplicate_send(self) -> None:
        captured_prompt = self.root / "captured-prompt.txt"
        captured_cmd = self.root / "captured-cmd.txt"
        cli = self.root / "fake-send.sh"
        cli.write_text(
            f'''#!/bin/sh
echo "$@" > "{captured_cmd}"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--prompt-file" ]; then
    cp "$2" "{captured_prompt}"
  fi
  shift
done
echo '{{"agentId": "3a45eaca-18bf-43a2-94f1-d6bd227d5225", "status": "sent", "message": "ok"}}'
''',
            encoding="utf-8",
        )
        cli.chmod(0o755)
        os.environ["BEANBRIDGE_PASEO_CLI"] = str(cli)

        receipt = self.root / "Submissions" / "paseo-1.json"
        res = PASEO_CHAT.action_submit("3a45eaca-18bf-43a2-94f1-d6bd227d5225", "你好 Paseo 测试", str(receipt))
        self.assertEqual(res["status"], "sent")
        self.assertEqual(captured_prompt.read_text(encoding="utf-8"), "你好 Paseo 测试")
        cmd_text = captured_cmd.read_text(encoding="utf-8")
        self.assertIn("--no-wait", cmd_text)
        self.assertIn("--behavior steer", cmd_text)
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)

        saved = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(saved["state"], "submitted")
        self.assertNotIn("你好", json.dumps(saved, ensure_ascii=False))

        # Re-submitting with the same receipt MUST fail closed
        with self.assertRaises(PASEO_CHAT.ReceiptAlreadyExistsError):
            PASEO_CHAT.action_submit("3a45eaca-18bf-43a2-94f1-d6bd227d5225", "你好 Paseo 测试", str(receipt))

    def test_submit_failure_marks_receipt_uncertain(self) -> None:
        self._write_fake_cli("echo 'connection reset' >&2\nexit 1")
        receipt = self.root / "Submissions" / "paseo-err.json"
        with self.assertRaises(PASEO_CHAT.BridgeError):
            PASEO_CHAT.action_submit("3a45eaca-18bf-43a2-94f1-d6bd227d5225", "测试失败保留", str(receipt))
        saved = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(saved["state"], "uncertain")
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)

    def test_resolve_workspace_tab_fail_closed_cases(self) -> None:
        snapshot = {
            "workspace": {"id": "wks_735bf72fbd477bdc", "name": "orchestrator"},
            "agents": [
                {"id": "3a45eaca-18bf-43a2-94f1-d6bd227d5225", "title": "同时我要开发   针对paseo的输入"},
                {"id": "6d4a63e8-ea75-465a-b808-31f5a6334682", "title": "重复标题对话"},
                {"id": "48701701-6d86-4e88-becc-044bfea08650", "title": "重复标题对话"},
                {"id": "14a2b96a-7759-4c90-a1f4-88565c0848e7", "title": "另一个独立对话"},
            ],
        }

        # Unique agent match even when sidebar/toolbar label is also selected
        res = PASEO_CHAT.resolve_workspace_tab_from_snapshot(
            snapshot, ["orchestrator", "Files", "同时我要开发 针对paseo的输入"]
        )
        self.assertEqual(res["kind"], "agent")
        self.assertEqual(res["id"], "3a45eaca-18bf-43a2-94f1-d6bd227d5225")

        # Blank New tab / Draft New Agent -> blank
        for blank_lbl in ["New tab", "New Agent", "新建 Agent", "新建标签页", "新建标签"]:
            res_blank = PASEO_CHAT.resolve_workspace_tab_from_snapshot(snapshot, ["orchestrator", blank_lbl])
            self.assertEqual(res_blank, {"kind": "blank"})

        # Duplicate titles in same workspace -> fail closed
        with self.assertRaises(PASEO_CHAT.BridgeError):
            PASEO_CHAT.resolve_workspace_tab_from_snapshot(snapshot, ["重复标题对话"])

        # Multiple distinct agents selected (split pane) -> fail closed
        with self.assertRaises(PASEO_CHAT.BridgeError):
            PASEO_CHAT.resolve_workspace_tab_from_snapshot(
                snapshot, ["同时我要开发 针对paseo的输入", "另一个独立对话"]
            )

        # Agent + blank tab simultaneously -> fail closed
        with self.assertRaises(PASEO_CHAT.BridgeError):
            PASEO_CHAT.resolve_workspace_tab_from_snapshot(
                snapshot, ["同时我要开发 针对paseo的输入", "New tab"]
            )

        # Terminal + New tab -> fail closed
        with self.assertRaises(PASEO_CHAT.BridgeError):
            PASEO_CHAT.resolve_workspace_tab_from_snapshot(snapshot, ["Terminal", "New tab"])

        # Generic loading label -> fail closed
        with self.assertRaises(PASEO_CHAT.BridgeError):
            PASEO_CHAT.resolve_workspace_tab_from_snapshot(snapshot, ["Antigravity agent"])

        # End-to-end action_resolve_workspace_tab via helper override
        helper = self.root / "fake-ws-helper.py"
        helper.write_text(
            f"""#!/usr/bin/env python3
import json, sys
print(json.dumps({json.dumps(snapshot, ensure_ascii=False)}, ensure_ascii=False))
""",
            encoding="utf-8",
        )
        helper.chmod(0o755)
        os.environ["BEANBRIDGE_PASEO_HELPER_CMD"] = str(helper)
        res_action = PASEO_CHAT.action_resolve_workspace_tab(
            "wks_735bf72fbd477bdc", json.dumps(["同时我要开发 针对paseo的输入"])
        )
        self.assertEqual(res_action["id"], "3a45eaca-18bf-43a2-94f1-d6bd227d5225")


if __name__ == "__main__":
    unittest.main()
