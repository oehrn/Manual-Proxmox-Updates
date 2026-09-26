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
  status=$(pct status "$id") || die "Cannot read CT $id status."
  [[ $status == 'status: running' || $status == 'status: stopped' ]] || die "Unexpected CT $id status: $status"
  # A stopped LXC is never started by this runner.
  if [[ $status == 'status: stopped' ]]; then
    log "SKIP CT $id: stopped; it will remain stopped."
    continue
  fi
  config=$(pct config "$id") || die "Cannot read CT $id configuration."
  if ! network_enabled "$config"; then
    log "SKIP CT $id: no enabled network interface."
    continue
  fi
  grep -Eq '^ostype: (debian|ubuntu)$' <<< "$config" || die "CT $id is not configured as Debian or Ubuntu."
  planned+=("$id")
  log "PLAN CT $id: update while running."
done
if (( ${#planned[@]} == 0 )); then
  log 'No eligible LXCs; nothing to update.'
  exit 0
fi
[[ $mode == --apply ]] || exit 0

exec 9>"$LOCK"
flock -n 9 || die 'Another update run is active.'

failures=0
for id in "${planned[@]}"; do
  # Recheck state and network immediately before the update.
  status=$(pct status "$id") || die "Cannot read CT $id status."
  if [[ $status == 'status: stopped' ]]; then
    log "SKIP CT $id: it was stopped after planning."
    continue
  fi
  [[ $status == 'status: running' ]] || die "Unexpected CT $id status: $status"
  config=$(pct config "$id") || die "Cannot read CT $id configuration."
  if ! network_enabled "$config"; then
    log "SKIP CT $id: network interface was disabled after planning."
    continue
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

done

(( failures == 0 )) || die "$failures LXC update(s) failed."
log 'Manual LXC update run completed successfully.'
