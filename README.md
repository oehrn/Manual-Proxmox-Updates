# Manual Proxmox Updates

A small, manually triggered update runner for a Proxmox VE host and explicitly selected running containers. Home Assistant can start the runner, while systemd owns the long-running process.

## Features

- No timer, cron job, or automatic reboot.
- Explicit host and container allowlist in a root-owned configuration file.
- Stops on the first update failure and records progress in the system journal.
- Reports which targets require an operator-controlled reboot.
- Rejects concurrent runs.

## Prerequisites

- A Proxmox VE host with Bash, `flock`, systemd, and `apt-get`.
- Selected Debian or Ubuntu containers with `apt-get`.
- Optional: Home Assistant with the Shell Command integration and SSH access to the Proxmox host.

## Quick start

Review the scripts before installing. On the intended Proxmox host, install `scripts/manual-proxmox-updates.sh` as `/usr/local/sbin/manual-proxmox-updates` and `systemd/manual-proxmox-updates.service` as `/etc/systemd/system/manual-proxmox-updates.service`. Copy `examples/targets.conf.example` to `/etc/manual-proxmox-updates/targets.conf`, set `EXPECTED_HOST`, `UPDATE_HOST`, and `CT_IDS`, then make that file root-owned and mode `0600`. Run `systemctl daemon-reload`.

The example selects no targets. It cannot install updates until the operator chooses at least one target. Use `systemctl start manual-proxmox-updates.service` for an operator-controlled first run. Inspect `systemctl status manual-proxmox-updates.service` and `journalctl -u manual-proxmox-updates.service -n 50 --no-pager` afterward.

## Home Assistant trigger

`examples/home-assistant.yaml` defines a script that can be placed on a dashboard button. It has no automation trigger or schedule. The SSH command returns quickly because the restricted key runs `systemctl start --no-block manual-proxmox-updates.service`; the update process continues under systemd. Home Assistant's `shell_command` has a 60-second limit, so it should not execute the update directly.

Create a dedicated SSH key for this action. On the Proxmox host, constrain its public key in `root`'s `authorized_keys`:

```text
command="/usr/bin/systemctl start --no-block manual-proxmox-updates.service",restrict ssh-ed25519 <PUBLIC_KEY>
```

Store the private key under Home Assistant's persistent `/config/.ssh/` directory. Verify the host fingerprint before adding it to `/config/.ssh/known_hosts`. Adjust the example hostname to the intended host. The network path from Home Assistant to the host must be checked before use.

## Operations

The runner applies `apt-get update` and `apt-get upgrade -y` in allowlist order. Package upgrades may restart services. It does not perform distribution upgrades, `autoremove`, host or container reboot, or power on a stopped container. Check backup freshness and choose a maintenance window before each run. Enable targets gradually after a small pilot.

The Home Assistant action confirms only that the service was asked to start. Read the systemd status and journal for the actual result. To stop future runs, remove the dashboard action and restricted SSH key. Removing the runner does not undo installed package updates.

## Security and privacy

Never commit the real target configuration, SSH keys, host fingerprints, logs, or infrastructure details. The provided examples contain placeholders only. The update key's forced command limits what that key can invoke; protect the host and Home Assistant configuration as privileged systems.

## License

No license has been selected yet.
