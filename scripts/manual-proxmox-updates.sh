#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the Proxmox host. Home Assistant only starts the systemd service.
CONFIG=/etc/manual-proxmox-updates/targets.json
LOCK=/run/manual-proxmox-updates.lock

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

mode=${1:-}
[[ $mode == --plan || $mode == --apply ]] || die 'Use --plan or --apply.'
[[ $(id -u) == 0 ]] || die 'Root is required.'
[[ -f $CONFIG && ! -L $CONFIG ]] || die 'Target JSON is missing or a symlink.'
[[ $(stat -c %u "$CONFIG") == 0 ]] || die 'Target JSON must be owned by root.'
file_mode=$(stat -c %a "$CONFIG")
(( (8#$file_mode & 8#022) == 0 )) || die 'Target JSON must not be writable by group or others.'

# Validate JSON and emit only a hostname and approved stopped CT IDs.
config_lines=$(python3 - "$CONFIG" <<'PY'
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
    if not isinstance(config, dict) or set(config) != {"expected_host", "start_stopped"}:
        raise ValueError("expected exactly 'expected_host' and 'start_stopped'")
    host = config["expected_host"]
    ids = config["start_stopped"]
    if not isinstance(host, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]*", host):
        raise ValueError("invalid expected_host")
    if not isinstance(ids, list):
        raise ValueError("start_stopped must be a list")
    if any(type(item) is not int or not 100 <= item <= 999999999 for item in ids):
        raise ValueError("container IDs must be integers between 100 and 999999999")
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate container ID")
except (OSError, ValueError) as error:
    print(f"Invalid target JSON: {error}", file=sys.stderr)
    sys.exit(1)

print(host)
for item in ids:
    print(item)
PY
) || die 'Target JSON validation failed.'
config_items=()
while IFS= read -r item; do config_items+=("$item"); done <<< "$config_lines"
expected_host=${config_items[0]}
start_stopped=("${config_items[@]:1}")
[[ $(hostname -s) == "$expected_host" ]] || die 'Unexpected Proxmox host.'

# Discover current LXCs rather than maintaining a full copy of the host inventory.
contains_id() {
  local wanted=$1 item
  shift
  for item in "$@"; do [[ $item == "$wanted" ]] && return 0; done
  return 1
}
approved_for_start() {
  (( ${#start_stopped[@]} > 0 )) || return 1
  contains_id "$1" "${start_stopped[@]}"
}
targets=()
while read -r id _; do
  [[ $id =~ ^[0-9]+$ ]] || continue
  targets+=("$id")
done < <(pct list)
(( ${#targets[@]} > 0 )) || die 'No LXCs discovered on this host.'
if (( ${#start_stopped[@]} > 0 )); then
  for id in "${start_stopped[@]}"; do
    contains_id "$id" "${targets[@]}" || log "SKIP CT $id: approved for stopped updates but no longer on this host."
  done
fi

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
  if [[ $status == 'status: stopped' ]] && ! approved_for_start "$id"; then
    log "SKIP CT $id: stopped and not approved for temporary start."
    continue
  fi
  planned+=("$id")
  if [[ $status == 'status: stopped' ]]; then
    log "PLAN CT $id: start, update, then shut down."
  else
    log "PLAN CT $id: update while running."
  fi
done
if (( ${#planned[@]} == 0 )); then
  log 'No eligible LXCs; nothing to update.'
  exit 0
fi
[[ $mode == --apply ]] || exit 0

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
on_exit() {
  local result=$?
  shutdown_started || result=1
  exit "$result"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    if ! approved_for_start "$id"; then
      log "SKIP CT $id: stopped and not approved for temporary start."
      continue
    fi
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
  if [[ -n $started_id ]]; then
    shutdown_started || failures=$((failures + 1))
  fi
done

(( failures == 0 )) || die "$failures LXC update(s) failed."
log 'Manual LXC update run completed successfully.'
