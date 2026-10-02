"""Isolated behavior checks with a fake pct command; never touches Proxmox."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


RUNNER = Path(__file__).resolve().parents[1] / "scripts/manual-proxmox-updates.sh"


class RunnerTest(unittest.TestCase):
    def run_case(self, mode, fail_update=False, failed_service=False, fail_host=False, reboot_host=False, sender_config=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "targets.json"
            config.write_text(json.dumps({"expected_host": "n5"}))
            mail_config = root / "mail.conf"
            mail_config.write_text('MAIL_TO=operator@example.test\n' + sender_config)
            mail_config.chmod(0o600)
            mail = root / "mail.txt"
            reboot_flag = root / "reboot-required"
            if reboot_host:
                reboot_flag.touch()
            script = root / "runner.sh"
            script.write_text(
                RUNNER.read_text()
                .replace("CONFIG=/etc/manual-proxmox-updates/targets.json", f"CONFIG={config}")
                .replace("MAIL_CONFIG=/etc/manual-proxmox-updates/mail.conf", f"MAIL_CONFIG={mail_config}")
                .replace("SENDMAIL_PATH=/usr/sbin/sendmail", f"SENDMAIL_PATH={root / 'sendmail'}")
                .replace("LOCK=/run/manual-proxmox-updates.lock", f"LOCK={root / 'lock'}")
                .replace("if [[ -e /var/run/reboot-required ]]; then", f"if [[ -e {reboot_flag} ]]; then")
            )
            sendmail = root / "sendmail"
            sendmail.write_text('#!/bin/sh\necho "sendmail $*" >> "$FAKE_CALLS"\ncat > "$FAKE_MAIL"\n')
            sendmail.chmod(0o755)
            state = root / "state.json"
            state.write_text(json.dumps({"110": "running", "198": "stopped", "201": "stopped", "261": "stopped"}))
            calls = root / "calls.txt"
            fakebin = root / "bin"
            fakebin.mkdir()
            for name, body in {
                "id": 'echo 0',
                "hostname": 'echo n5',
                "stat": 'case "$2" in %u) echo 0;; %a) echo 600;; esac',
                "flock": 'exit 0',
                "timeout": 'shift; exec "$@"',
                "apt-get": 'echo "host apt-get $*" >> "$FAKE_CALLS"; if [ "$FAIL_HOST" = 1 ] && [ "$*" = "-o DPkg::Lock::Timeout=60 update" ]; then exit 1; fi',
                "systemctl": 'echo "host systemctl $*" >> "$FAKE_CALLS"',
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
                "elif op == 'config': print('ostype: debian\\nnet0: name=eth0,bridge=vmbr0' + (',link_down=1' if args[0] == '261' else ''))\n"
                "else:\n"
                "    with calls.open('a') as log: log.write(op + ' ' + ' '.join(args) + '\\n')\n"
                "    if op == 'start': state[args[0]] = 'running'\n"
                "    if op == 'shutdown': state[args[0]] = 'stopped'\n"
                "    state_path.write_text(json.dumps(state))\n"
                "    if op == 'exec' and args[-1] == '/var/run/reboot-required': sys.exit(1)\n"
                "    if op == 'exec' and '--failed' in args and args[0] == '198' and os.environ.get('FAILED_SERVICE') == '1': print('example.service loaded failed failed Example')\n"
                "    if op == 'exec' and 'update' in args and os.environ.get('FAIL_UPDATE') == '1' and args[0] == '198': sys.exit(1)\n"
            )
            pct.chmod(0o755)
            environment = os.environ | {
                "PATH": str(fakebin) + os.pathsep + os.environ["PATH"],
                "FAKE_STATE": str(state),
                "FAKE_CALLS": str(calls),
                "FAIL_UPDATE": "1" if fail_update else "0",
                "FAILED_SERVICE": "1" if failed_service else "0",
                "FAIL_HOST": "1" if fail_host else "0",
                "FAKE_MAIL": str(mail),
            }
            result = subprocess.run(
                ["bash", str(script), mode],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            return result, json.loads(state.read_text()), calls.read_text() if calls.exists() else "", mail.read_text() if mail.exists() else ""

    def test_plan_includes_stopped_containers(self):
        result, state, calls, mail = self.run_case("--plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PLAN CT 110", result.stdout)
        self.assertIn("PLAN CT 198: start, update, then shut down", result.stdout)
        self.assertIn("PLAN CT 201: start, update, then shut down", result.stdout)
        self.assertIn("SKIP CT 261: no enabled network interface", result.stdout)
        self.assertEqual(state["198"], "stopped")
        self.assertEqual(calls, "")
        self.assertEqual(mail, "")

    def test_stopped_containers_are_shut_down_after_update(self):
        result, state, calls, mail = self.run_case("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("start 198", calls)
        self.assertIn("shutdown 198 --timeout 120", calls)
        self.assertIn("start 201", calls)
        self.assertIn("shutdown 201 --timeout 120", calls)
        self.assertIn("exec 198 -- systemctl --failed --type=service --no-legend --plain --no-pager", calls)
        self.assertIn("host apt-get -o DPkg::Lock::Timeout=60 update", calls)
        self.assertIn("host systemctl is-active --quiet pveproxy pvedaemon pvestatd", calls)
        self.assertLess(calls.index("host apt-get"), calls.index("exec 110 -- apt-get"))
        self.assertNotIn("start 261", calls)
        self.assertNotIn("shutdown 110", calls)
        self.assertEqual(state["198"], "stopped")
        self.assertEqual(state["201"], "stopped")
        self.assertEqual(mail, "")

    def test_update_failure_still_shuts_down_started_container(self):
        result, state, calls, mail = self.run_case("--apply", fail_update=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("package index update failed", result.stdout)
        self.assertIn("shutdown 198 --timeout 120", calls)
        self.assertEqual(state["198"], "stopped")
        self.assertIn("[Proxmox Updates] FAILED", mail)
        self.assertIn("host apt-get", calls)
        self.assertIn("CT 198 package index update failed", mail)

    def test_failed_service_is_reported_and_started_container_is_shut_down(self):
        result, state, calls, mail = self.run_case("--apply", failed_service=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CT 198 has failed service example.service", result.stdout)
        self.assertIn("shutdown 198 --timeout 120", calls)
        self.assertEqual(state["198"], "stopped")
        self.assertIn("CT 198 has failed service example.service", mail)

    def test_host_failure_stops_before_containers_and_sends_mail(self):
        result, state, calls, mail = self.run_case("--apply", fail_host=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("start 198", calls)
        self.assertNotIn("exec 110 -- apt-get", calls)
        self.assertIn("host apt-get -o DPkg::Lock::Timeout=60 update", calls)
        self.assertNotIn("host systemctl is-active", calls)
        self.assertIn("Host package index update failed", mail)

    def test_host_reboot_requirement_stops_before_containers_and_sends_mail(self):
        result, state, calls, mail = self.run_case("--apply", reboot_host=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("start 198", calls)
        self.assertNotIn("exec 110 -- apt-get", calls)
        self.assertIn("requires a reboot before LXC updates", mail)


    def test_named_sender_sets_header_and_envelope(self):
        result, state, calls, mail = self.run_case(
            "--apply", fail_host=True,
            sender_config='MAIL_FROM=error-PVE-N5@example.test\nMAIL_FROM_NAME="N5 PVE Error"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('From: "N5 PVE Error" <error-PVE-N5@example.test>\n', mail)
        self.assertIn('sendmail -f error-PVE-N5@example.test -t -oi', calls)
        self.assertIn('To: operator@example.test\n', mail)

    def test_address_only_sender(self):
        result, state, calls, mail = self.run_case(
            "--apply", fail_host=True, sender_config='MAIL_FROM=error-PVE-N5@example.test\n')
        self.assertIn('From: error-PVE-N5@example.test\n', mail)
        self.assertIn('sendmail -f error-PVE-N5@example.test -t -oi', calls)

    def test_legacy_mail_settings_keep_transport_defaults(self):
        result, state, calls, mail = self.run_case("--apply", fail_host=True)
        self.assertIn('sendmail -t -oi', calls)
        self.assertNotIn('From:', mail)
        self.assertNotIn('sendmail -f', calls)

    def test_header_injection_is_rejected_before_updates(self):
        result, state, calls, mail = self.run_case(
            "--apply", sender_config="MAIL_FROM=sender@example.test\nMAIL_FROM_NAME=$'bad\\nBcc: attacker@example.test'\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MAIL_FROM_NAME is invalid', result.stderr)
        self.assertEqual(calls, '')
        self.assertEqual(mail, '')

    def test_name_without_address_is_rejected(self):
        result, state, calls, mail = self.run_case("--apply", sender_config='MAIL_FROM_NAME="N5 PVE Error"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MAIL_FROM_NAME requires MAIL_FROM', result.stderr)
        self.assertEqual(calls, '')
        self.assertEqual(mail, '')


if __name__ == "__main__":
    unittest.main()
