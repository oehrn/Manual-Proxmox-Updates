#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the Proxmox host. Home Assistant only starts the systemd service.
CONFIG=/etc/manual-proxmox-updates/targets.json
MAIL_CONFIG=/etc/manual-proxmox-updates/mail.conf
SENDMAIL_PATH=/usr/sbin/sendmail
LOCK=/run/manual-proxmox-updates.lock
RUN_ID=$(date +%Y%m%dT%H%M%S%z)
issues=()

log() {
  printf '%s %s\n' "$(date -Is)" "$*"
  [[ $1 == ERROR:* ]] && issues+=("$*")
  return 0
}
die() { log "ERROR: $*" >&2; exit 1; }

mode=${1:-}
[[ $mode == --plan || $mode == --apply ]] || die 'Use --plan or --apply.'
[[ $(id -u) == 0 ]] || die 'Root is required.'
[[ -f $CONFIG && ! -L $CONFIG ]] || die 'Target JSON is missing or a symlink.'
[[ $(stat -c %u "$CONFIG") == 0 ]] || die 'Target JSON must be owned by root.'
file_mode=$(stat -c %a "$CONFIG")
(( (8#$file_mode & 8#022) == 0 )) || die 'Target JSON must not be writable by group or others.'

# Validate JSON and emit the expected hostname.
expected_host=$(python3 - "$CONFIG" <<'PY'
import json
import re
import sys

def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        config = json.load(stream, object_pairs_hook=unique_pairs)
    if not isinstance(config, dict) or set(config) != {"expected_host"}:
        raise ValueError("expected exactly 'expected_host'")
    host = config["expected_host"]
    if not isinstance(host, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]*", host):
        raise ValueError("invalid expected_host")
except (OSError, ValueError) as error:
    print(f"Invalid target JSON: {error}", file=sys.stderr)
    sys.exit(1)

print(host)
PY
) || die 'Target JSON validation failed.'
[[ $(hostname -s) == "$expected_host" ]] || die 'Unexpected Proxmox host.'

# Discover current LXCs rather than maintaining a full copy of the host inventory.
targets=()
while read -r id _; do
  [[ $id =~ ^[0-9]+$ ]] || continue
  targets+=("$id")
done < <(pct list)
(( ${#targets[@]} > 0 )) || die 'No LXCs discovered on this host.'

network_enabled() {
  local line
  while IFS= read -r line; do
    [[ $line =~ ^net[0-9]+: ]] || continue
    [[ $line =~ (^|,)link_down=1(,|$) ]] && continue
    return 0
  done <<< "$1"
  return 1
}

planned=()
for id in "${targets[@]}"; do
  status=$(pct status "$id") || die "Cannot read CT $id status."
  [[ $status == 'status: running' || $status == 'status: stopped' ]] || die "Unexpected CT $id status: $status"
  config=$(pct config "$id") || die "Cannot read CT $id configuration."
  if ! network_enabled "$config"; then
    log "SKIP CT $id: no enabled network interface."
    continue
  fi
  if ! grep -Eq '^ostype: (debian|ubuntu)$' <<< "$config"; then
    log "SKIP CT $id: not configured as Debian or Ubuntu."
    continue
  fi
  planned+=("$id")
  if [[ $status == 'status: stopped' ]]; then
    log "PLAN CT $id: start, update, then shut down."
  else
    log "PLAN CT $id: update while running."
  fi
done
(( ${#planned[@]} > 0 )) || log 'No eligible LXCs; host update remains planned.'
log "PLAN host $(hostname -s): update before eligible LXCs; no automatic reboot."
[[ $mode == --apply ]] || exit 0

[[ -f $MAIL_CONFIG && ! -L $MAIL_CONFIG ]] || die 'Mail configuration is missing or a symlink.'
[[ $(stat -c %u "$MAIL_CONFIG") == 0 ]] || die 'Mail configuration must be owned by root.'
mail_mode=$(stat -c %a "$MAIL_CONFIG")
(( (8#$mail_mode & 8#077) == 0 )) || die 'Mail configuration must not be accessible by group or others.'
# This trusted, root-owned file contains mail recipient and optional sender settings.
# shellcheck source=/dev/null
source "$MAIL_CONFIG"
[[ ${MAIL_TO:-} == *@* && $MAIL_TO != *$'\n'* && $MAIL_TO != *$'\r'* ]] || die 'MAIL_TO is missing or invalid.'

# Optional settings preserve existing installations until the operator opts in.
MAIL_FROM=${MAIL_FROM:-}
MAIL_FROM_NAME=${MAIL_FROM_NAME:-}
[[ -z $MAIL_FROM || $MAIL_FROM =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || die 'MAIL_FROM is invalid.'
[[ $MAIL_FROM_NAME != *$'\n'* && $MAIL_FROM_NAME != *$'\r'* && $MAIL_FROM_NAME != *'"'* && $MAIL_FROM_NAME != *'\'* ]] || die 'MAIL_FROM_NAME is invalid.'
[[ -z $MAIL_FROM_NAME || -n $MAIL_FROM ]] || die 'MAIL_FROM_NAME requires MAIL_FROM.'
mail_sender_args=()
[[ -z $MAIL_FROM ]] || mail_sender_args=(-f "$MAIL_FROM")

exec 9>"$LOCK"
flock -n 9 || die 'Another update run is active.'

# Never leave a container running solely because this runner was interrupted.
started_id=
shutdown_started() {
  local id=$started_id status
  [[ -n $id ]] || return 0
  if pct shutdown "$id" --timeout 120 &&
      status=$(pct status "$id") && [[ $status == 'status: stopped' ]]; then
    log "Stopped CT $id after update."
    started_id=
    return 0
  fi
  log "ERROR: Could not confirm shutdown of CT $id; operator check required."
  started_id=
  return 1
}
check_container_health() {
  local id=$1 status failed_units unit remainder
  status=$(pct status "$id") || { log "ERROR: Cannot read CT $id status after update."; return 1; }
  if [[ $status != 'status: running' ]]; then
    log "ERROR: CT $id is not running after update ($status)."
    return 1
  fi
  if ! failed_units=$(pct exec "$id" -- systemctl --failed --type=service --no-legend --plain --no-pager); then
    log "ERROR: Could not check failed systemd services in CT $id."
    return 1
  fi
  if [[ -n $failed_units ]]; then
    while read -r unit remainder; do
      [[ -n $unit ]] && log "ERROR: CT $id has failed service $unit."
    done <<< "$failed_units"
    return 1
  fi
  log "CHECK CT $id: running; no failed systemd services."
}
send_failure_email() {
  {
    printf 'To: %s\n' "$MAIL_TO"
    if [[ -n $MAIL_FROM_NAME ]]; then
      printf 'From: "%s" <%s>\n' "$MAIL_FROM_NAME" "$MAIL_FROM"
    elif [[ -n $MAIL_FROM ]]; then
      printf 'From: %s\n' "$MAIL_FROM"
    fi
    printf 'Subject: [Proxmox Updates] FAILED %s\n' "$RUN_ID"
    printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n'
    printf 'Proxmox update failed on %s. Run: %s. Exit status: %s.\n\n' "$(hostname -s)" "$RUN_ID" "$1"
    if (( ${#issues[@]} > 0 )); then
      printf 'Errors:\n'
      printf '%s\n' "${issues[@]}"
    else
      printf 'No detailed error was captured.\n'
    fi
    printf '\nFull host log: journalctl -u manual-proxmox-updates.service -n 100 --no-pager\n'
  } | timeout 30 "$SENDMAIL_PATH" "${mail_sender_args[@]}" -t -oi
}
on_exit() {
  local result=$?
  shutdown_started || result=1
  if (( result != 0 )); then
    if send_failure_email "$result"; then
      log 'Failure email submitted to local mail transport.'
    else
      log 'ERROR: Failure email could not be submitted; inspect the journal.'
    fi
  fi
  exit "$result"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Updating host $(hostname -s)."
if ! apt-get -o DPkg::Lock::Timeout=60 update; then
  die 'Host package index update failed.'
fi
if ! env DEBIAN_FRONTEND=noninteractive apt-get \
    -o DPkg::Lock::Timeout=60 -o Dpkg::Options::=--force-confold upgrade -y; then
  die 'Host package upgrade failed.'
fi
log 'Updated Proxmox host packages.'
if [[ -e /var/run/reboot-required ]]; then
  die "Host $(hostname -s) requires a reboot before LXC updates; operator decides when."
fi
if ! failed_units=$(systemctl --failed --type=service --no-legend --plain --no-pager); then
  die 'Could not check failed host services.'
fi
if [[ -n $failed_units ]]; then
  while read -r unit remainder; do
    [[ -n $unit ]] && log "ERROR: Host has failed service $unit."
  done <<< "$failed_units"
  die 'Host service check failed before LXC updates.'
fi
systemctl is-active --quiet pveproxy pvedaemon pvestatd || die 'A core Proxmox service is inactive before LXC updates.'
log 'CHECK host: core Proxmox services active; no failed systemd services.'

failures=0
for id in "${planned[@]}"; do
  # Recheck state and network immediately before a possible start or update.
  status=$(pct status "$id") || die "Cannot read CT $id status."
  [[ $status == 'status: running' || $status == 'status: stopped' ]] || die "Unexpected CT $id status: $status"
  config=$(pct config "$id") || die "Cannot read CT $id configuration."
  if ! network_enabled "$config"; then
    log "SKIP CT $id: network interface was disabled after planning."
    continue
  fi
  if ! grep -Eq '^ostype: (debian|ubuntu)$' <<< "$config"; then
    log "SKIP CT $id: operating system changed after planning."
    continue
  fi
  if [[ $status == 'status: stopped' ]]; then
    log "Starting CT $id for update."
    if ! pct start "$id"; then
      log "ERROR: CT $id could not be started; operator check required."
      failures=$((failures + 1))
      continue
    fi
    started_id=$id
    status=$(pct status "$id") || die "Cannot read CT $id status after start."
    [[ $status == 'status: running' ]] || die "CT $id did not reach running state."
  fi

  log "Updating CT $id."
  if ! pct exec "$id" -- test -x /usr/bin/apt-get; then
    log "ERROR: CT $id does not have apt-get."
    failures=$((failures + 1))
  elif ! pct exec "$id" -- apt-get -o DPkg::Lock::Timeout=60 update; then
    log "ERROR: CT $id package index update failed."
    failures=$((failures + 1))
  elif ! pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive apt-get \
      -o DPkg::Lock::Timeout=60 -o Dpkg::Options::=--force-confold upgrade -y; then
    log "ERROR: CT $id package upgrade failed."
    failures=$((failures + 1))
  else
    log "Updated CT $id."
    if pct exec "$id" -- test -e /var/run/reboot-required; then
      log "REBOOT REQUIRED: CT $id; operator decides when."
    fi
  fi
  check_container_health "$id" || failures=$((failures + 1))
  if [[ -n $started_id ]]; then
    shutdown_started || failures=$((failures + 1))
  fi
done

(( failures == 0 )) || die "$failures LXC update(s) failed."
log 'Manual LXC and host update run completed successfully.'
