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

# Validate JSON and emit only a hostname and numeric CT IDs, one per line.
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
    if not isinstance(config, dict) or set(config) != {"expected_host", "containers"}:
        raise ValueError("expected exactly 'expected_host' and 'containers'")
    host = config["expected_host"]
    ids = config["containers"]
    if not isinstance(host, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]*", host):
        raise ValueError("invalid expected_host")
    if not isinstance(ids, list) or not ids:
        raise ValueError("containers must be a non-empty list")
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
mapfile -t config_items <<< "$config_lines"
expected_host=${config_items[0]}
targets=("${config_items[@]:1}")
[[ $(hostname -s) == "$expected_host" ]] || die 'Unexpected Proxmox host.'

# Fail closed if the host inventory and the approved JSON have drifted apart.
declare -A configured=() discovered=()
for id in "${targets[@]}"; do configured[$id]=1; done
while read -r id _; do
  [[ $id =~ ^[0-9]+$ ]] || continue
  discovered[$id]=1
  [[ ${configured[$id]+yes} ]] || die "CT $id is on this host but missing from the JSON."
done < <(pct list)
for id in "${targets[@]}"; do
  [[ ${discovered[$id]+yes} ]] || die "CT $id is in the JSON but absent from this host."
done

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
  config=$(pct config "$id") || die "Cannot read CT $id configuration."
  status=$(pct status "$id") || die "Cannot read CT $id status."
  [[ $status == 'status: running' || $status == 'status: stopped' ]] || die "Unexpected CT $id status: $status"
  if ! network_enabled "$config"; then
    log "SKIP CT $id: no enabled network interface ($status)."
    continue
  fi
  grep -Eq '^ostype: (debian|ubuntu)$' <<< "$config" || die "CT $id is not configured as Debian or Ubuntu."
  planned+=("$id")
  if [[ $status == 'status: stopped' ]]; then
    log "PLAN CT $id: start, update, shut down."
  else
    log "PLAN CT $id: update while running."
  fi
done
(( ${#planned[@]} > 0 )) || die 'No eligible LXCs.'
[[ $mode == --apply ]] || exit 0

exec 9>"$LOCK"
flock -n 9 || die 'Another update run is active.'

started_by_us=
on_exit() {
  local result=$?
  trap - EXIT
  if [[ -n $started_by_us ]]; then
    log "Shutting down CT $started_by_us after interrupted or failed run."
    if ! pct shutdown "$started_by_us" --timeout 120 || [[ $(pct status "$started_by_us") != 'status: stopped' ]]; then
      log "ERROR: CT $started_by_us could not be shut down; manual attention required."
      result=1
    fi
  fi
  exit "$result"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0
for id in "${planned[@]}"; do
  # Recheck the exclusion and initial state immediately before changing anything.
  config=$(pct config "$id") || die "Cannot read CT $id configuration."
  if ! network_enabled "$config"; then
    log "SKIP CT $id: network interface was disabled after planning."
    continue
  fi
  status=$(pct status "$id") || die "Cannot read CT $id status."
  if [[ $status == 'status: stopped' ]]; then
    log "Starting CT $id for its update."
    if ! pct start "$id"; then
      [[ $(pct status "$id") != 'status: running' ]] || started_by_us=$id
      die "Could not start CT $id."
    fi
    started_by_us=$id
  elif [[ $status != 'status: running' ]]; then
    die "Unexpected CT $id status: $status"
  fi

  log "Updating CT $id."
  apt_ready=0
  for attempt in {1..12}; do
    if pct exec "$id" -- test -x /usr/bin/apt-get >/dev/null 2>&1; then
      apt_ready=1
      break
    fi
    sleep 5
  done
  if (( apt_ready == 0 )); then
    log "ERROR: CT $id did not expose apt-get within 60 seconds."
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

  if [[ $started_by_us == "$id" ]]; then
    log "Returning CT $id to its stopped state."
    if ! pct shutdown "$id" --timeout 120 || [[ $(pct status "$id") != 'status: stopped' ]]; then
      die "CT $id could not be shut down; manual attention required."
    fi
    started_by_us=
  fi
done

(( failures == 0 )) || die "$failures LXC update(s) failed."
log 'Manual LXC update run completed successfully.'
