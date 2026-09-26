# Manual Proxmox LXC Updates

A manually triggered update runner for the Debian and Ubuntu containers on one Proxmox VE host. Home Assistant can start it; systemd owns the long-running process. VMs and the Proxmox host itself are outside this runner.

## Behavior

- The root-owned JSON lists every LXC ID on the host. The runner refuses to start if the host inventory and JSON differ.
- A container is skipped when it has no configured network interface or every interface has `link_down=1`. Disconnecting a network interface is an operator decision and may affect the container's service.
- Running containers stay running. Stopped containers are started for the update and gracefully shut down afterward, including after an update failure where possible. A failed shutdown is reported and needs operator attention; there is no forced stop.
- Updates are sequential: `apt-get update`, then `apt-get upgrade -y`. Failures are logged, and remaining containers are still attempted unless a lifecycle or inventory error makes it unsafe to continue.
- Package upgrades may restart services inside an LXC; choose a maintenance window.
- There is no timer, cron job, distribution upgrade, automatic VM or host update, or automatic reboot of a previously running container.

## Prerequisites

- Proxmox VE host with Bash, Python 3, `flock`, systemd, and `pct`.
- Debian or Ubuntu LXCs with `apt-get` and a working package repository connection.
- Optional Home Assistant Shell Command integration and SSH access to the Proxmox host.

## Installation and first review

Review the scripts before installing. On the intended Proxmox host, install `scripts/manual-proxmox-updates.sh` as `/usr/local/sbin/manual-proxmox-updates` and `systemd/manual-proxmox-updates.service` as `/etc/systemd/system/manual-proxmox-updates.service`. Copy `examples/targets.json.example` to `/etc/manual-proxmox-updates/targets.json`, set the real host name, and list **every** LXC ID on that host. Keep this real JSON out of the public repository. Set root ownership and mode `0600`, then run `systemctl daemon-reload`.

Run `/usr/local/sbin/manual-proxmox-updates --plan` first. It is read-only and shows which LXCs would be skipped, updated while running, or started and shut down. Recheck the plan after changing any network settings. Disabling a network interface can interrupt a service, so make that choice separately. Check backup freshness and choose a maintenance window before starting an update.

For a manual first run, use `systemctl start manual-proxmox-updates.service`. Inspect `systemctl status manual-proxmox-updates.service` and `journalctl -u manual-proxmox-updates.service -n 50 --no-pager` afterward. The service invokes `--apply`; the operator performs practical testing.

## Home Assistant trigger

`examples/home-assistant.yaml` defines a dashboard script, with no automation trigger or schedule. The restricted SSH key runs `systemctl start --no-block manual-proxmox-updates.service`, so the update continues under systemd. Home Assistant's Shell Command has a 60-second limit and must not execute the update itself.

Create a dedicated SSH key for this action. On the Proxmox host, constrain its public key in `root`'s `authorized_keys`:

```text
command="/usr/bin/systemctl start --no-block manual-proxmox-updates.service",restrict ssh-ed25519 <PUBLIC_KEY>
```

Store the private key under Home Assistant's persistent `/config/.ssh/` directory. Verify the host fingerprint before adding it to `/config/.ssh/known_hosts`. Adjust the example hostname to the intended host. Check the network path from Home Assistant before use.

The Home Assistant action confirms only that the service was asked to start. Read the systemd status and journal for the actual result. To prevent future runs, remove the dashboard action and restricted SSH key. Removing the runner does not undo installed package updates.

## Security and privacy

Never commit the real target JSON, SSH keys, host fingerprints, logs, or infrastructure details. The example has placeholders only. The key's forced command limits what that key can invoke; protect the host and Home Assistant configuration as privileged systems.

## License

No license has been selected yet.
