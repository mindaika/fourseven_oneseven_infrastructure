#!/usr/bin/env bash
# Hide ephemeral Docker interfaces from Glances.
#
# WHY
# Glances reports every network interface it sees, and Home Assistant creates a
# sensor for each. Docker gives every container a `veth<random>` interface and
# every user-defined network a `br-<random>` one, and those names change on each
# container restart -- so the set never converges. On piberry5 this had produced
# 1,212 dead entities and ~92,000 orphaned long-term statistics rows before it
# was noticed, and it grows every time a container restarts.
#
# Excluding them in Home Assistant's recorder only stops the history; the
# entities still get created and clutter the UI. Hiding them here stops it at
# the source, so Home Assistant never sees them at all.
#
# WHERE TO RUN
# On every host running `glances -w`. As of 2026-08-12 that is:
#   piberry5   192.168.1.54    <- applied
#   pi4        192.168.1.96    <- not yet; reported no veth at the time
#   pi4lite    192.168.1.144   <- not yet; reported no veth at the time
# The two Pi4s run few containers, so they had none to hide when this was
# written. Run this there too if interface sensors ever appear.
#
# Idempotent: re-running when the patterns are already present changes nothing.
#
# Usage:  sudo ./glances-hide-veth.sh

set -euo pipefail

CONF=${GLANCES_CONF:-/etc/glances/glances.conf}
PATTERNS="veth.*,br-.*"

if [[ $EUID -ne 0 ]]; then
    echo "Error: must run as root (the config and service are root-owned)" >&2
    exit 1
fi

if [[ ! -f "$CONF" ]]; then
    echo "Error: $CONF not found -- is Glances installed here?" >&2
    exit 1
fi

current=$(grep -m1 '^hide=' "$CONF" | sed 's/^hide=//' || true)

if [[ "$current" == *"veth.*"* ]]; then
    echo "Already hiding veth interfaces: hide=$current"
    exit 0
fi

backup="$CONF.bak-$(date +%Y%m%d_%H%M%S)"
cp -a "$CONF" "$backup"
echo "Backed up to $backup"

# Append to the existing hide= line in [network] rather than replacing it, so
# whatever is already hidden (docker.*, lo) stays hidden.
awk -v pat="$PATTERNS" '
    /^\[network\]/ { in_net = 1 }
    /^\[/ && !/^\[network\]/ { in_net = 0 }
    in_net && /^hide=/ && !done { print $0 "," pat; done = 1; next }
    { print }
' "$CONF" > "$CONF.new"

mv "$CONF.new" "$CONF"
chmod --reference="$backup" "$CONF"
echo "Updated: $(grep -m1 '^hide=' "$CONF")"

systemctl restart glances
sleep 5
systemctl is-active --quiet glances && echo "glances restarted OK" || {
    echo "glances failed to restart; restoring $backup" >&2
    cp -a "$backup" "$CONF"
    systemctl restart glances
    exit 1
}

echo
echo "Interfaces now reported:"
curl -s -m 10 "http://127.0.0.1:61208/api/4/network" \
    | python3 -c "import json,sys; print(' ', [i['interface_name'] for i in json.load(sys.stdin)])" \
    2>/dev/null || echo "  (could not query the API; check manually)"
