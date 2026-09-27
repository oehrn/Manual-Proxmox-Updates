"""Isolated behavior checks with a fake pct command; never touches Proxmox."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


RUNNER = Path(__file__).resolve().parents[1] / "scripts/manual-proxmox-updates.sh"


class RunnerTest(unittest.TestCase):
    def run_case(self, mode, start_stopped, fail_update=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "targets.json"
            config.write_text(json.dumps({"expected_host": "n5", "start_stopped": start_stopped}))
            script = root / "runner.sh"
            script.write_text(
                RUNNER.read_text()
                .replace("CONFIG=/etc/manual-proxmox-updates/targets.json", f"CONFIG={config}")
                .replace("LOCK=/run/manual-proxmox-updates.lock", f"LOCK={root / 'lock'}")
            )
            state = root / "state.json"
            state.write_text(json.dumps({"110": "running", "198": "stopped", "201": "stopped"}))
            calls = root / "calls.txt"
            fakebin = root / "bin"
            fakebin.mkdir()
            for name, body in {
                "id": 'echo 0',
                "hostname": 'echo n5',
                "stat": 'case "$2" in %u) echo 0;; %a) echo 600;; esac',
                "flock": 'exit 0',
            }.items():
                path = fakebin / name
                path.write_text(f"#!/bin/sh\n{body}\n")
                path.chmod(0o755)
            pct = fakebin / "pct"
            pct.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "state_path = Path(os.environ['FAKE_STATE'])\n"
                "calls = Path(os.environ['FAKE_CALLS'])\n"
                "state = json.loads(state_path.read_text())\n"
                "op, *args = sys.argv[1:]\n"
                "if op == 'list':\n"
                "    print('VMID Status Lock Name')\n"
                "    for ct, status in state.items(): print(ct, status, '', 'test')\n"
                "elif op == 'status': print('status:', state[args[0]])\n"
                "elif op == 'config': print('ostype: debian\\nnet0: name=eth0,bridge=vmbr0')\n"
                "else:\n"
                "    with calls.open('a') as log: log.write(op + ' ' + ' '.join(args) + '\\n')\n"
                "    if op == 'start': state[args[0]] = 'running'\n"
                "    if op == 'shutdown': state[args[0]] = 'stopped'\n"
                "    state_path.write_text(json.dumps(state))\n"
                "    if op == 'exec' and args[-1] == '/var/run/reboot-required': sys.exit(1)\n"
                "    if op == 'exec' and 'update' in args and os.environ.get('FAIL_UPDATE') == '1' and args[0] == '198': sys.exit(1)\n"
            )
            pct.chmod(0o755)
            environment = os.environ | {
                "PATH": str(fakebin) + os.pathsep + os.environ["PATH"],
                "FAKE_STATE": str(state),
                "FAKE_CALLS": str(calls),
                "FAIL_UPDATE": "1" if fail_update else "0",
            }
            result = subprocess.run(
                ["bash", str(script), mode],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            return result, json.loads(state.read_text()), calls.read_text() if calls.exists() else ""

    def test_discovery_skips_unapproved_stopped_containers(self):
        result, state, calls = self.run_case("--plan", [])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PLAN CT 110", result.stdout)
        self.assertIn("SKIP CT 198", result.stdout)
        self.assertEqual(state["198"], "stopped")
        self.assertEqual(calls, "")

    def test_removed_stopped_approval_does_not_block_other_updates(self):
        result, _, calls = self.run_case("--plan", [210])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SKIP CT 210: approved for stopped updates but no longer on this host", result.stdout)
        self.assertIn("PLAN CT 110", result.stdout)
        self.assertEqual(calls, "")

    def test_approved_stopped_container_is_shut_down_after_update(self):
        result, state, calls = self.run_case("--apply", [198])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("start 198", calls)
        self.assertIn("shutdown 198 --timeout 120", calls)
        self.assertNotIn("shutdown 110", calls)
        self.assertEqual(state["198"], "stopped")
        self.assertEqual(state["201"], "stopped")

    def test_update_failure_still_shuts_down_started_container(self):
        result, state, calls = self.run_case("--apply", [198], fail_update=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("package index update failed", result.stdout)
        self.assertIn("shutdown 198 --timeout 120", calls)
        self.assertEqual(state["198"], "stopped")


if __name__ == "__main__":
    unittest.main()
