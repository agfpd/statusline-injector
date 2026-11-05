"""Offline regression suite; Python is a test dependency, not a plugin dependency."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Hooks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sli-test-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.project = self.home / "project with spaces"
        self.project.mkdir()
        self.state = self.home / "state"
        self.env = dict(os.environ, HOME=str(self.home),
                        STATUSLINE_STATE_DIR=str(self.state),
                        STATUSLINE_ACTIVATE_TRIES="0", LC_ALL="C")
        for key in ("CLAUDE_PLUGIN_ROOT", "CLAUDE_PROJECT_DIR", "PLUGIN_ROOT",
                    "CODEX_HOME", "SL_SHOW_PCT", "STATUSLINE_DEBUG"):
            self.env.pop(key, None)

    def run_script(self, name, data=None, args=(), env=None):
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "scripts" / name), *map(str, args)],
            input=json.dumps(data or {}), text=True, capture_output=True,
            env=env or self.env, cwd=self.project, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def inject(self, data, runtime="codex"):
        self.env["PLUGIN_ROOT" if runtime == "codex" else "CLAUDE_PLUGIN_ROOT"] = str(ROOT)
        output = json.loads(self.run_script("statusline-inject.sh", data))
        hook = output["hookSpecificOutput"]
        self.assertEqual(hook["hookEventName"], "UserPromptSubmit")
        return hook["additionalContext"]

    def rollout(self, events, partial=False):
        path = self.home / "custom codex home" / "sessions" / "rollout-test.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(map(json.dumps, events)) + ("\n{" if partial else "\n"))
        return path

    def token(self, used=150000, limits=None):
        return {"type": "event_msg", "payload": {"type": "token_count", "info": {
            "last_token_usage": {"input_tokens": used}, "model_context_window": 200000},
            "rate_limits": limits}}

    def test_render_boundaries(self):
        for used, pct, visible in [(100000, 50, False), (100001, 50.1, True), (0, 0, False)]:
            with self.subTest(used=used):
                ro = self.rollout([self.token(used, {"primary": {
                    "window_minutes": 300, "used_percent": pct}})])
                line = self.inject({"transcript_path": str(ro)})
                self.assertEqual("ctx " in line, visible)
                self.assertEqual("5h " in line, visible)
                self.assertNotIn("⚠", line)

    def test_codex_null_events_and_partial_write(self):
        first = self.token(limits={"primary": {"window_minutes": 10080, "used_percent": 79}})
        rate_only = {"type": "event_msg", "payload": {"type": "token_count", "info": None,
            "rate_limits": {"secondary": {"window_minutes": 300, "used_percent": 88}}}}
        ro = self.rollout([first, rate_only, {"type": "event_msg", "payload": {
            "type": "token_count", "info": None, "rate_limits": None}},
            {"type": "response_item", "payload": {"rate_limits": None}}], partial=True)
        line = self.inject({"transcript_path": str(ro)})
        self.assertIn("ctx 150k/200k", line)
        self.assertIn("5h 88%", line)

    def test_codex_context_event_does_not_erase_limits(self):
        ro = self.rollout([self.token(limits={"primary": {
            "window_minutes": 10080, "used_percent": 79}}), self.token(170000)])
        line = self.inject({"transcript_path": str(ro)})
        self.assertIn("7d 79%", line)
        self.assertIn("ctx 170k/200k", line)

    def test_codex_custom_home_and_spaces(self):
        ro = self.rollout([{"type": "session_meta", "payload": {"cwd": str(self.project)}},
                           self.token()])
        self.env["CODEX_HOME"] = str(ro.parent.parent)
        self.assertIn("ctx 150k/200k", self.inject({"cwd": str(self.project)}))

    def test_codex_unknown_window_is_not_mislabeled(self):
        ro = self.rollout([self.token(limits={"primary": {
            "window_minutes": 60, "used_percent": 99}, "secondary": {
            "window_minutes": 43200, "used_percent": 99}})])
        line = self.inject({"transcript_path": str(ro)})
        self.assertNotIn("5h ", line)
        self.assertNotIn("7d ", line)

    def test_claude_wrapper_passthrough_and_injection(self):
        blob = {"session_id": "S", "context_window": {
            "total_input_tokens": 650000, "context_window_size": 1000000},
            "rate_limits": {"five_hour": {"used_percentage": 81}}}
        self.assertEqual(self.run_script("statusline-wrapper.sh", blob,
                                         args=("printf USERLINE",)), "USERLINE")
        self.assertEqual(json.loads((self.state / "state-S.json").read_text()), blob)
        line = self.inject({"session_id": "S"}, "claude")
        self.assertIn("ctx 650k/1m", line)
        self.assertIn("5h 81%", line)

    def test_claude_transcript_malformed_usage(self):
        path = self.project / "transcript.jsonl"
        for value in ["bad", {}, [], -1, 2.5]:
            with self.subTest(value=value):
                path.write_text(json.dumps({"message": {"usage": {"input_tokens": value}}}))
                line = self.inject({"transcript_path": str(path)}, "claude")
                self.assertNotIn("ctx ", line)

    def test_claude_transcript_partial_write(self):
        path = self.project / "transcript.jsonl"
        path.write_text(json.dumps({"message": {"usage": {"input_tokens": 1000,
            "cache_read_input_tokens": 120000, "cache_creation_input_tokens": 3000}}})
            + '\n{"type":"user"}\n{')
        self.assertIn("ctx 124k/200k", self.inject({"transcript_path": str(path)}, "claude"))

    def start(self):
        self.env.update(CLAUDE_PROJECT_DIR=str(self.project), CLAUDE_PLUGIN_ROOT=str(ROOT))
        self.run_script("statusline-session-start.sh", {"cwd": str(self.project)})
        return self.project / ".claude" / "settings.json"

    def test_wrap_idempotent_and_uninstall(self):
        for source in ("none", "user", "project"):
            with self.subTest(source=source):
                settings = self.project / ".claude" / "settings.json"
                user = self.home / ".claude" / "settings.json"
                original = {"type": "command", "command": "printf 'ORIGINAL'", "padding": 2}
                settings.parent.mkdir(exist_ok=True)
                user.parent.mkdir(exist_ok=True)
                settings.write_text(json.dumps({"statusLine": original} if source == "project" else {}))
                user.write_text(json.dumps({"statusLine": original} if source == "user" else {}))
                self.start()
                before = settings.read_bytes()
                for _ in range(5):
                    self.start()
                    self.assertEqual(settings.read_bytes(), before)
                self.run_script("statusline-uninstall.sh", args=(settings,))
                restored = json.loads(settings.read_text()).get("statusLine")
                self.assertEqual(restored, original if source == "project" else None)

    def test_markerless_and_poisoned_stash(self):
        settings = self.project / ".claude" / "settings.json"
        settings.parent.mkdir()
        original = {"type": "command", "command": "printf ORIGINAL"}
        settings.write_text(json.dumps({"statusLine": original}))
        self.start()
        wrapped = json.loads(settings.read_text())["statusLine"]
        poisoned = dict(wrapped, _statuslineInjectorOriginal=wrapped)
        settings.write_text(json.dumps({"statusLine": poisoned}))
        self.start()
        self.assertEqual(json.loads(settings.read_text())["statusLine"]["_statuslineInjectorOriginal"], original)
        stripped = {k: v for k, v in wrapped.items() if not k.startswith("_statusline")}
        settings.write_text(json.dumps({"statusLine": stripped}))
        self.start()
        self.run_script("statusline-uninstall.sh", args=(settings,))
        self.assertEqual(json.loads(settings.read_text())["statusLine"], original)

    def test_missing_state_and_ru_locale(self):
        self.env["LC_ALL"] = "ru_RU.UTF-8"
        line = self.inject({})
        self.assertRegex(line, r"^\[st \d\d:\d\d[+-]\d+(?:\d\d)?\]$")

    def test_invalid_percentages_and_threshold(self):
        for pct in ("99oops", "99\nINSTRUCTION", {}, [], -4):
            with self.subTest(pct=pct):
                ro = self.rollout([self.token(limits={"primary": {
                    "window_minutes": 300, "used_percent": pct}})])
                self.assertNotIn("5h ", self.inject({"transcript_path": str(ro)}))
        for threshold in ("bad", "-1", "101"):
            self.env["SL_SHOW_PCT"] = threshold
            ro = self.rollout([self.token(100000)])
            self.assertNotIn("ctx ", self.inject({"transcript_path": str(ro)}))

    def test_retention_and_stable_materialization(self):
        self.state.mkdir()
        old = self.state / "state-old.json"
        fresh = self.state / "state-fresh.json"
        fragment = self.state / ".state.abandoned"
        for p in (old, fresh, fragment):
            p.write_text("{}")
        for p in (old, fragment):
            os.utime(p, (time.time() - 10 * 86400,) * 2)
        self.start()
        self.assertFalse(old.exists())
        self.assertFalse(fragment.exists())
        self.assertTrue(fresh.exists())
        wrapper = self.state / "wrapper.sh"
        before = wrapper.stat().st_mtime_ns
        self.start()
        self.assertEqual(wrapper.stat().st_mtime_ns, before)
        self.assertEqual(wrapper.read_bytes(), (ROOT / "scripts/statusline-wrapper.sh").read_bytes())

    def test_retention_disabled_and_invalid(self):
        self.state.mkdir()
        old = self.state / "state-old.json"
        old.write_text("{}")
        os.utime(old, (time.time() - 10 * 86400,) * 2)
        for ttl in ("0", "bad"):
            self.env["STATUSLINE_STATE_TTL_DAYS"] = ttl
            self.start()
            self.assertTrue(old.exists())

    def test_invalid_settings_preserved(self):
        settings = self.project / ".claude" / "settings.json"
        settings.parent.mkdir()
        settings.write_text("{invalid")
        self.start()
        self.assertEqual(settings.read_text(), "{invalid")
        self.assertEqual(list(settings.parent.glob(".settings.*")), [])

    def test_user_scope_original_tracks_changes(self):
        user = self.home / ".claude" / "settings.json"
        user.parent.mkdir()
        for command in ("printf FIRST", "printf SECOND"):
            user.write_text(json.dumps({"statusLine": {"type": "command", "command": command}}))
            settings = self.start()
            wrapped = json.loads(settings.read_text())["statusLine"]["command"]
            self.assertIn(command, wrapped)

    def test_reset_date_portability(self):
        result = subprocess.run(["/bin/bash", "-c",
            '. "$1/scripts/statusline-lib.sh"; sl_fmt_reset 1799999999', "test", str(ROOT)],
            env=dict(self.env, TZ="UTC"), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "07:59")

    def test_missing_jq(self):
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        for name in ("dirname", "cat", "mkdir", "mktemp", "mv", "rm"):
            target = shutil.which(name)
            if target:
                (bin_dir / name).symlink_to(target)
        self.env["PATH"] = str(bin_dir)
        for name in ("inject", "wrapper", "session-start", "uninstall"):
            self.run_script("statusline-" + name + ".sh")

    def test_codex_sessionstart_noop(self):
        self.env["CLAUDE_PLUGIN_ROOT"] = str(ROOT)
        self.run_script("statusline-session-start.sh", {"transcript_path": "rollout-test.jsonl"})
        self.assertFalse((self.project / ".claude").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
