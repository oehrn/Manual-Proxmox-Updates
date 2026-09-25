#!/usr/bin/env bash
set -Eeuo pipefail

# Started only by manual-proxmox-updates.service after an operator action.
CONFIG=/etc/manual-proxmox-updates/targets.conf
LOCK=/run/manual-proxmox-updates.lock

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ ${1:-} == --apply ]] || die 'Use --apply via the systemd service.'
[[ $(id -u) == 0 ]] || die 'Root is required.'
[[ -f $CONFIG && ! -L $CONFIG ]] || die 'Target configuration is missing or a symlink.'
[[ $(stat -c %u "$CONFIG") == 0 ]] || die 'Target configuration must be owned by root.'
mode=$(stat -c %a "$CONFIG")
(( (8#$mode & 8#022) == 0 )) || die 'Target configuration must not be writable by group or others.'

# The root-owned file contains only UPDATE_HOST=0|1 and CT_IDS="id id ...".
# shellcheck source=/dev/null
source "$CONFIG"
[[ -n ${EXPECTED_HOST:-} && $(hostname -s) == "$EXPECTED_HOST" ]] || die 'Unexpected Proxmox host.'
[[ ${UPDATE_HOST:-} == 0 || ${UPDATE_HOST:-} == 1 ]] || die 'UPDATE_HOST must be 0 or 1.'
read -r -a targets <<< "${CT_IDS:-}"
(( ${#targets[@]} > 0 )) || [[ $UPDATE_HOST == 1 ]] || die 'No targets selected.'

declare -A seen=()
for id in "${targets[@]}"; do
  [[ $id =~ ^[0-9]+$ ]] || die "Invalid CT ID: $id"
  [[ ! ${seen[$id]+yes} ]] || die "Duplicate CT ID: $id"
  seen[$id]=1
  pct config "$id" >/dev/null || die "CT $id is absent."
  [[ $(pct status "$id") == "status: running" ]] || die "CT $id is not running."
  pct exec "$id" -- test -x /usr/bin/apt-get || die "CT $id is not a supported apt guest."
done

exec 9>"$LOCK"
flock -n 9 || die 'Another update run is active.'
log "Starting manual update on ${EXPECTED_HOST}: host=$UPDATE_HOST; CTs=${targets[*]:-none}"

apt_update() {
  local label=$1
  shift
  log "Updating $label"
  "$@" apt-get -o DPkg::Lock::Timeout=60 update
  "$@" env DEBIAN_FRONTEND=noninteractive apt-get \
    -o DPkg::Lock::Timeout=60 -o Dpkg::Options::=--force-confold \
    upgrade -y
  log "Completed $label"
}

if [[ $UPDATE_HOST == 1 ]]; then
  apt_update "$EXPECTED_HOST"
  [[ ! -e /var/run/reboot-required ]] || log 'REBOOT REQUIRED: host; operator decides when.'
fi

for id in "${targets[@]}"; do
  apt_update "CT $id" pct exec "$id" --
  if pct exec "$id" -- test -e /var/run/reboot-required; then
    log "REBOOT REQUIRED: CT $id; operator decides when."
  fi
done

log 'Manual update run completed successfully.'
