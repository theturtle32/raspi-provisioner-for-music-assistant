#!/bin/bash
# ════════════════════════════════════════════════════════════════
# reprovision.sh — re-run provisioning on a live player, no re-imaging
#
#   ./reprovision.sh snapplayer-primary-bedroom.local
#
# Re-imaging a card to pick up a provision.sh change means pulling the card,
# writing ~2.7 GB, and waiting on a verify pass. Nothing about that is necessary:
# provision.sh is idempotent and the only thing standing in its way is the RAM
# overlay, which discards everything it writes.
#
# So: turn the overlay off, reboot, run the current provision.sh, let it turn the
# overlay back on, reboot. Two reboots, no card handling, no image write.
#
# What this CANNOT change (they are applied by patch-userdata.py at image time,
# not by provision.sh):
#   HAT_OVERLAY   — writes dtoverlay= into config.txt
#   the pinned SSH host key, hostname, and cloud-init user-data
#
# And note WIFI_MODE: switching it changes which NIC is used, therefore the MAC,
# therefore the Snapcast client ID — the player will need re-associating in
# Music Assistant. Everything else is safe to change.
#
# Requires: SSH access and passwordless sudo (both set up by provision.sh).
# ════════════════════════════════════════════════════════════════
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

[ -n "$TARGET" ] || die "usage: $(basename "$0") <host>
       e.g. $(basename "$0") snapplayer-primary-bedroom.local"

sshq() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# Wait for the host to answer SSH again. Bounded; returns 1 on timeout.
wait_for_host() {
    local label="$1" limit="${2:-180}" elapsed=0
    printf '    waiting for %s ' "$label"
    while [ "$elapsed" -lt "$limit" ]; do
        if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=4 "$TARGET" true 2>/dev/null; then
            printf ' up (%ds)\n' "$elapsed"
            return 0
        fi
        printf '.'
        sleep 5
        elapsed=$((elapsed + 5))
    done
    printf ' TIMEOUT\n'
    return 1
}

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

[ -f "${SCRIPT_DIR}/provision.sh" ] || die "provision.sh not found beside this script"

sshq true 2>/dev/null || die "cannot reach ${TARGET} over SSH"
sshq "sudo -n true" 2>/dev/null || die "passwordless sudo is not available on ${TARGET}"

REMOTE_HOST=$(sshq "hostname")
info "target:  ${TARGET} (${REMOTE_HOST})"

sshq "test -f /boot/firmware/player.env" 2>/dev/null \
    || die "no /boot/firmware/player.env on ${TARGET} — this does not look like a provisioned player"

OLD_VERSION=$(sshq "grep -s '^version:' /etc/provisioner-version | awk '{print \$2}'" || true)
info "currently:  ${OLD_VERSION:-unknown}"

NEW_VERSION=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]; then
    NEW_VERSION="${NEW_VERSION}-dirty"
    info "WARNING: working tree is dirty; this player will be stamped ${NEW_VERSION}"
fi
info "deploying:  ${NEW_VERSION}"

# ── Push config ───────────────────────────────────────────────────────────────
# player.env lives on the boot partition, so it survives every reboot below and
# can be written even while the overlay is still active.
step "Updating player.env on the boot partition"

ARCHIVE="${SCRIPT_DIR}/players/${REMOTE_HOST}.env"
if [ -f "$ARCHIVE" ]; then
    info "pushing archived config: players/${REMOTE_HOST}.env"
    scp "${SSH_OPTS[@]}" -q "$ARCHIVE" "${TARGET}:/tmp/player.env.new"
    sshq "sudo cp /tmp/player.env.new /boot/firmware/player.env && rm -f /tmp/player.env.new"
else
    info "no local archive for ${REMOTE_HOST}; keeping the player.env already on the card"
fi

# Without this the stamp would still report the revision the card was imaged
# with, which is the whole thing the stamp exists to prevent.
sshq "sudo sed -i '/^PROVISIONER_VERSION=/d' /boot/firmware/player.env \
      && echo 'PROVISIONER_VERSION=${NEW_VERSION}' | sudo tee -a /boot/firmware/player.env >/dev/null"
info "PROVISIONER_VERSION set to ${NEW_VERSION}"

# ── Disable the overlay ───────────────────────────────────────────────────────
step "Disabling the overlay filesystem (reboot 1 of 2)"

if sshq "sudo raspi-config nonint get_overlay_now" | grep -q '^0$'; then
    sshq "sudo raspi-config nonint disable_overlayfs"
    info "overlay disabled; rebooting"
    sshq "sudo systemctl reboot" 2>/dev/null || true
    sleep 15
    wait_for_host "${TARGET}" 240 || die "${TARGET} did not come back after reboot 1"
else
    info "overlay was already off; no reboot needed"
fi

sshq "sudo raspi-config nonint get_overlay_now" | grep -q '^1$' \
    || die "overlay is still active after reboot — refusing to continue, as changes would be discarded"
info "confirmed: root filesystem is writable"

# ── Deploy and run ────────────────────────────────────────────────────────────
step "Running provision.sh ${NEW_VERSION}"

scp "${SSH_OPTS[@]}" -q "${SCRIPT_DIR}/provision.sh" "${TARGET}:/tmp/provision.sh"
sshq "sudo install -m 0755 /tmp/provision.sh /usr/local/bin/provision.sh && rm -f /tmp/provision.sh"

# provision.sh re-enables the overlay as its final step. If it fails, its ERR
# trap writes provision-failed.txt and leaves the overlay off — which is exactly
# the state we want for debugging, so surface it rather than pressing on.
if ! sshq "sudo /usr/local/bin/provision.sh"; then
    printf '\n'
    sshq "sudo cat /boot/firmware/provision-failed.txt 2>/dev/null | head -40" || true
    die "provisioning failed on ${TARGET}. The overlay is still OFF and the card is
       writable, so you can investigate directly. See the report above and
       /var/log/cloud-init-output.log."
fi

# ── Reboot into the overlay ───────────────────────────────────────────────────
step "Rebooting into the overlay (reboot 2 of 2)"

sshq "sudo systemctl reboot" 2>/dev/null || true
sleep 15
wait_for_host "${TARGET}" 240 || die "${TARGET} did not come back after reboot 2"

# ── Let the player settle ─────────────────────────────────────────────────────
# The TIMESYNC_WAIT gate holds the player in "activating" until the clock syncs,
# so a snapshot taken straight after boot reports a transient state as if it were
# the final one — indistinguishable from a player that genuinely failed to start.
step "Waiting for the player to finish starting"

settle_elapsed=0
while [ "$settle_elapsed" -lt 120 ]; do
    pending=$(sshq "systemctl list-units --no-legend --state=activating 'snapclient*' 'shairport-sync*' 2>/dev/null | awk '{print \$1}' | tr '\n' ' '" 2>/dev/null || true)
    pending=$(printf '%s' "$pending" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')
    [ -z "$pending" ] && break
    info "still activating: ${pending} (clock gate holds until NTP syncs)"
    sleep 5
    settle_elapsed=$((settle_elapsed + 5))
done
[ "$settle_elapsed" -ge 120 ] && info "WARNING: still activating after 120s — check the gate"
info "settled after ${settle_elapsed}s"

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verifying"

sshq "
    printf '    overlay:  %s\n' \"\$(grep -o 'overlayroot=[a-z]*' /proc/cmdline || echo 'NOT ACTIVE')\"
    printf '    version:  %s\n' \"\$(grep -s '^version:' /etc/provisioner-version | awk '{print \$2}')\"
    printf '    wifi:     %s\n' \"\$(ip -br addr show wlan0 2>/dev/null | awk '{print \$1, \$2, \$3}')\"
    for s in snapclient shairport-sync player-netwatch; do
        st=\$(systemctl is-active \$s 2>/dev/null)
        [ \"\$st\" = inactive ] && continue
        printf '    %-16s %s\n' \"\$s\" \"\$st\"
    done
    if sudo test -f /boot/firmware/provision-failed.txt; then
        echo '    WARNING: provision-failed.txt is present'
    fi
"

printf '\n\033[1mDone.\033[0m %s is running %s\n\n' "$REMOTE_HOST" "$NEW_VERSION"
