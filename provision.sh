#!/bin/bash
# ════════════════════════════════════════════════════════════════
# provision.sh — Snapcast/AirPlay player audio provisioning
#
# Called by cloud-init on first boot (via user-data runcmd).
# cloud-init handles: hostname, /etc/hosts, run-once semantics.
# This script handles: audio routing, player daemon, ALSA, overlay FS.
#
# PLAYER_TYPE in player.env controls which player is configured:
#   snapcast  — snapclient connecting to MA's Snapcast server
#   airplay   — shairport-sync appearing as AirPlay device in MA
#
# WIFI_MODE in player.env controls WiFi interface selection:
#   builtin   — use built-in wlan0 (default)
#   usb       — use USB adapter wlan1, disable built-in wlan0
#   none      — disable WiFi entirely (ethernet only)
#
# The root filesystem is switched to a RAM overlay as the final step, so
# everything written after that point is discarded on reboot. Anything that
# must survive a power cycle has to live on the boot partition, which is why
# the clock, the network watchdog log and the failure report all go there.
# ════════════════════════════════════════════════════════════════

# -E propagates the ERR trap into functions; without it a failure inside a
# function would abort silently and leave a half-provisioned card.
set -Eeuo pipefail

# Locate boot partition (Trixie: /boot/firmware, Bookworm: /boot)
if [ -d /boot/firmware ]; then
    BOOT_PART=/boot/firmware
else
    BOOT_PART=/boot
fi

BOOT_ENV="${BOOT_PART}/player.env"
ALSA_STATE="${BOOT_PART}/asound.state"
LOG="/tmp/provision.log"

# player.env lives on a FAT partition and is routinely edited from macOS or
# Windows. A stray CR turns "usb" into "usb\r", which matches no case arm and
# silently falls through to a different configuration than the operator chose,
# so every read goes through a normalised copy instead of the original.
BOOT_ENV_CLEAN="/tmp/player.env.clean"

exec > >(tee -a "$LOG") 2>&1
echo "=== Provisioning started: $(date) ==="

# ── Failure reporting ──────────────────────────────────────────────────────────
# On failure the overlay is never enabled, so the card stays writable and the
# report below survives for post-mortem.
on_error() {
    local exit_code=$?
    local failed_line="$1"

    echo "!!! Provisioning FAILED at line ${failed_line} (exit ${exit_code})"

    {
        echo "=== PROVISIONING FAILED ==="
        echo "date:      $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
        echo "line:      ${failed_line}"
        echo "exit code: ${exit_code}"
        echo "version:   ${PROVISIONER_VERSION:-unknown}"
        echo "hostname:  $(hostname 2>/dev/null || echo unknown)"
        echo
        echo "--- last 200 log lines ---"
        tail -n 200 "$LOG" 2>/dev/null
    } > "${BOOT_PART}/provision-failed.txt" 2>/dev/null || true

    sync 2>/dev/null || true

    wall $'\n*** PROVISIONING FAILED ***\nSee provision-failed.txt on the boot partition.\nThe overlay filesystem was NOT enabled; this card is still writable.\n' 2>/dev/null || true
    printf '\n\n*** PROVISIONING FAILED ***\nSee provision-failed.txt on the boot partition.\n\n' > /dev/tty1 2>/dev/null || true

    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# Notify anyone at the console that provisioning is running
wall $'\n*** PROVISIONING IN PROGRESS ***\nThis system is being configured automatically.\nIt will reboot when complete. Do not power off.\n' 2>/dev/null || true
printf '\n\n*** PROVISIONING IN PROGRESS ***\nThis system is being configured. It will reboot automatically.\nDo not power off.\n\n' > /dev/tty1 2>/dev/null || true

# ── Load config ────────────────────────────────────────────────────────────────
if [ ! -f "$BOOT_ENV" ]; then
    echo "ERROR: $BOOT_ENV not found. Cannot provision."
    exit 1
fi

tr -d '\r' < "$BOOT_ENV" > "$BOOT_ENV_CLEAN"
# shellcheck disable=SC1090
source "$BOOT_ENV_CLEAN"

# Defaults for every optional key, so `set -u` can catch genuine typos rather
# than tripping over keys the operator legitimately left out.
PLAYER_TYPE="${PLAYER_TYPE:-snapcast}"
WIFI_MODE="${WIFI_MODE:-builtin}"
MULTI_OUTPUT="${MULTI_OUTPUT:-false}"
ROOM_NAME="${ROOM_NAME:-}"
AUDIO_DEVICE="${AUDIO_DEVICE:-auto}"
SNAPCLIENT_LATENCY="${SNAPCLIENT_LATENCY:-}"
USB_VENDOR_ID="${USB_VENDOR_ID:-0d8c}"
USB_PRODUCT_ID="${USB_PRODUCT_ID:-0008}"
HAT_OVERLAY="${HAT_OVERLAY:-none}"
PROVISIONER_VERSION="${PROVISIONER_VERSION:-unknown}"

# Populated by whichever setup_* function runs. The startup chime has to finish
# with the sound card before these start, or they race it for the device.
PLAYER_UNITS=""

# ── Validate config ────────────────────────────────────────────────────────────
# Fail loudly on an unrecognised value. A silent fallback to the default is how
# a card ends up configured differently than the operator believes it is.
validate_choice() {
    local name="$1" value="$2"
    shift 2
    local choice
    for choice in "$@"; do
        [ "$value" = "$choice" ] && return 0
    done
    echo "ERROR: ${name}='${value}' is not valid. Expected one of: $*"
    echo "       (check for stray whitespace or line endings in ${BOOT_ENV})"
    exit 1
}

if [ -z "${MA_HOST:-}" ]; then
    echo "ERROR: MA_HOST must be set in player.env"
    exit 1
fi

validate_choice PLAYER_TYPE  "$PLAYER_TYPE"  snapcast airplay
validate_choice WIFI_MODE    "$WIFI_MODE"    builtin usb none
validate_choice MULTI_OUTPUT "$MULTI_OUTPUT" true false

echo "Config: player=${PLAYER_TYPE} wifi=${WIFI_MODE} multi=${MULTI_OUTPUT} ma_host=${MA_HOST}"
echo "Provisioner version: ${PROVISIONER_VERSION}"

# ══ HELPERS ════════════════════════════════════════════════════════════════════

set_card_max_volume() {
    local idx="$1"
    local -a controls=(
        "Master"
        "Speaker"
        "PCM"
        "Headphone"
        "Digital"
        "Headset"
        "Line"
        "A.Mstr Vol"    # Merus Audio amp (snd_rpi_merus_amp)
    )
    local found=0

    for control in "${controls[@]}"; do
        if amixer -c "$idx" sget "$control" &>/dev/null 2>&1; then
            amixer -c "$idx" sset "$control" 100% unmute 2>/dev/null && {
                echo "  [card $idx] Set '$control' to 100%"
                found=1
            }
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo "  [card $idx] WARNING: No recognised volume controls found"
    fi
}

set_all_cards_max_volume() {
    echo "Setting all sound cards to max volume..."
    while IFS= read -r line; do
        if [[ "$line" =~ ^card\ ([0-9]+): ]]; then
            set_card_max_volume "${BASH_REMATCH[1]}"
        fi
    done < <(aplay -l 2>/dev/null)
}

detect_audio_device() {
    local card_name
    # `|| true` because pipefail turns "no match" from grep into a fatal error,
    # which would defeat the fallback below.
    card_name=$(aplay -l 2>/dev/null \
        | grep -v "bcm2835" \
        | grep -v "vc4" \
        | grep "^card" \
        | head -1 \
        | sed 's/^card [0-9]*: \([^ ]*\) .*/\1/') || true

    if [ -n "$card_name" ]; then
        echo "default:CARD=${card_name}"
    else
        echo "default:CARD=Headphones"
    fi
}

# Appliance restart semantics: a player that gives up is a player someone has
# to walk over to. `on-failure` misses clean exits (server went away), and the
# default start limit makes systemd stop retrying after 5 attempts in 10s.
install_restart_dropin() {
    local unit="$1"
    mkdir -p "/etc/systemd/system/${unit}.d"
    cat > "/etc/systemd/system/${unit}.d/10-restart-always.conf" <<EOF
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=5
EOF
    echo "  Restart=always drop-in installed for ${unit}"
}

# ══ SINGLE-OUTPUT SETUP ════════════════════════════════════════════════════════
setup_single_output() {
    echo "Setting up single-output device..."

    if [ -z "$ROOM_NAME" ]; then
        echo "ERROR: ROOM_NAME must be set for single-output devices"
        exit 1
    fi

    if [ "$AUDIO_DEVICE" = "auto" ] || [ -z "$AUDIO_DEVICE" ]; then
        echo "Auto-detecting audio device..."
        AUDIO_DEVICE=$(detect_audio_device)
        echo "  Detected: $AUDIO_DEVICE"
    else
        echo "  Using configured device: $AUDIO_DEVICE"
    fi

    local latency_flag=""
    if [ -n "$SNAPCLIENT_LATENCY" ] && [ "$SNAPCLIENT_LATENCY" != "0" ]; then
        latency_flag=" --latency ${SNAPCLIENT_LATENCY}"
    fi

    cat > /etc/default/snapclient <<EOF
SNAPCLIENT_OPTS="-h ${MA_HOST} --soundcard ${AUDIO_DEVICE}${latency_flag}"
EOF
    echo "  Snapclient config written."
    install_restart_dropin snapclient.service
    systemctl enable snapclient
    PLAYER_UNITS="snapclient.service"
}

# ══ AIRPLAY SETUP (shairport-sync) ════════════════════════════════════════════
setup_airplay() {
    echo "Setting up AirPlay device (shairport-sync)..."

    if [ -z "$ROOM_NAME" ]; then
        echo "ERROR: ROOM_NAME must be set for AirPlay devices"
        exit 1
    fi

    if [ "$AUDIO_DEVICE" = "auto" ] || [ -z "$AUDIO_DEVICE" ]; then
        echo "Auto-detecting audio device..."
        AUDIO_DEVICE=$(detect_audio_device)
        echo "  Detected: $AUDIO_DEVICE"
    else
        echo "  Using configured device: $AUDIO_DEVICE"
    fi

    # Find first recognised mixer control for this card
    local mixer_control=""
    for ctrl in "Master" "Speaker" "PCM" "Headphone" "A.Mstr Vol"; do
        if amixer -D "$AUDIO_DEVICE" sget "$ctrl" &>/dev/null 2>&1; then
            mixer_control="$ctrl"
            break
        fi
    done

    cat > /etc/shairport-sync.conf <<EOF
general = {
    name = "${ROOM_NAME}";
    output_backend = "alsa";
};

alsa = {
    output_device = "${AUDIO_DEVICE}";
$([ -n "$mixer_control" ] && echo "    mixer_control_name = \"${mixer_control}\";")
};

sessioncontrol = {
    wait_for_completion = "no";
};
EOF
    echo "  shairport-sync config written."
    install_restart_dropin shairport-sync.service
    systemctl enable shairport-sync
    PLAYER_UNITS="shairport-sync.service"
}

# ══ MULTI-OUTPUT SETUP ═════════════════════════════════════════════════════════
setup_multi_output() {
    echo "Setting up multi-output device..."

    local udev_rules=""
    local instance=1
    local vendor="${USB_VENDOR_ID}"
    local product="${USB_PRODUCT_ID}"

    while IFS='=' read -r key val; do
        key="${key// /}"
        val="${val// /}"
        [[ "$key" =~ ^# ]] && continue
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^OUTPUT_([0-9]+)_ROOM$ ]] || continue

        local n="${BASH_REMATCH[1]}"
        local room="$val"
        # Sanitize room name for service names, card IDs, hostnames
        local room_slug
        room_slug=$(echo "${room}" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')
        local port_var="OUTPUT_${n}_USB_PORT"
        local port="${!port_var:-}"

        if [ -z "$port" ]; then
            echo "  WARNING: OUTPUT_${n}_ROOM set but OUTPUT_${n}_USB_PORT missing — skipping"
            continue
        fi

        local card_id="room_${room_slug}"
        local latency_var="OUTPUT_${n}_LATENCY"
        local latency_val="${!latency_var:-}"
        local latency_opt=""
        if [ -n "$latency_val" ] && [ "$latency_val" != "0" ]; then
            latency_opt=" --latency ${latency_val}"
        fi
        echo "  Output $n: room=$room  usb_port=$port  card_id=$card_id${latency_opt:+  latency=${latency_val}}"

        udev_rules+="SUBSYSTEM==\"sound\", \
ATTRS{idVendor}==\"${vendor}\", \
ATTRS{idProduct}==\"${product}\", \
KERNELS==\"${port}\", \
ATTR{id}=\"${card_id}\"\n"

        cat > "/etc/systemd/system/snapclient-${room_slug}.service" <<EOF
[Unit]
Description=Snapclient - ${room}
After=network-online.target sound.target alsa-restore-boot.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/bin/snapclient \\
    -h ${MA_HOST} \\
    --instance ${instance} \\
    --soundcard default:CARD=${card_id}${latency_opt}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable "snapclient-${room_slug}.service"
        echo "  Enabled snapclient-${room_slug}.service"
        PLAYER_UNITS="${PLAYER_UNITS:+${PLAYER_UNITS} }snapclient-${room_slug}.service"
        instance=$((instance + 1))
    done < "$BOOT_ENV_CLEAN"

    printf "%b\n" "$udev_rules" > /etc/udev/rules.d/90-usb-audio.rules
    echo "  udev rules written to /etc/udev/rules.d/90-usb-audio.rules"
    udevadm control --reload-rules
    udevadm trigger
    systemctl disable snapclient 2>/dev/null || true
    echo "  Waiting for udev card rename..."
    sleep 3
}

# ══ DEVICE-SPECIFIC CONFIGURATION ═════════════════════════════════════════════

configure_merus_amp() {
    local idx="$1"
    echo "  [card $idx] Configuring Merus Audio amp..."
    # Bypass the limiter — default is enabled which clips audio at high volumes
    amixer -c "$idx" cset numid=5 0 2>/dev/null && \
        echo "  [card $idx] Merus amp: limiter bypassed"
}

configure_device_specific() {
    echo "Applying device-specific configuration..."
    while IFS= read -r line; do
        if [[ "$line" =~ ^card\ ([0-9]+):.*sndrpimerusamp ]]; then
            configure_merus_amp "${BASH_REMATCH[1]}"
        fi
    done < <(aplay -l 2>/dev/null)
}

# ══ ALSA VOLUME + STATE PERSISTENCE ═══════════════════════════════════════════
configure_alsa() {
    set_all_cards_max_volume
    configure_device_specific

    echo "Saving ALSA state to $ALSA_STATE..."
    alsactl -f "$ALSA_STATE" store

    cat > /etc/systemd/system/alsa-restore-boot.service <<EOF
[Unit]
Description=Restore ALSA mixer state from boot partition
DefaultDependencies=no
Before=snapclient.service
After=sound.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/alsactl -f ${ALSA_STATE} restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable alsa-restore-boot.service
    echo "ALSA restore-on-boot service installed."
}

# ══ NETWORK WATCHDOG ═══════════════════════════════════════════════════════════
# NetworkManager's own retry logic only helps when the radio still answers.
# When WiFi firmware wedges — common on cheap USB adapters, not unheard of on
# the onboard SDIO part — the interface can stay nominally associated while
# passing no traffic, NM never emits a "down" event, and the player is dead
# until someone power-cycles it. This watchdog tests reachability for real and
# escalates: reconnect, then reload the driver, then reboot.
install_net_watchdog() {
    local iface="$1"

    cat > /etc/default/player-net <<EOF
# Network watchdog configuration. Written by provision.sh.
WIFI_IFACE=${iface}
NETLOG_FILE=${BOOT_PART}/netlog.txt
NETLOG_MAX_BYTES=262144
# Seconds between reachability checks.
CHECK_INTERVAL=30
# Consecutive failures before each escalation step.
FAIL_RECONNECT=2
FAIL_RELOAD=6
FAIL_REBOOT=12
# Grace period after boot before the first check.
BOOT_GRACE=120
# Cap on consecutive self-reboots. Without this, an outage the player cannot
# fix (AP powered off, PSK changed) becomes an indefinite reboot loop.
REBOOT_STATE_FILE=${BOOT_PART}/netwatch-reboots
MAX_AUTO_REBOOTS=3
# Once past FAIL_REBOOT, only log and retry every Nth check.
THROTTLE_CHECKS=20
EOF

    cat > /usr/local/bin/player-netwatch.sh <<'WATCHDOG'
#!/bin/bash
# player-netwatch.sh — connectivity watchdog with escalating recovery.
#
# Installed by provision.sh. Configuration lives in /etc/default/player-net.
#
# The root filesystem is a RAM overlay and journald is volatile, so a reboot
# destroys all evidence of why the reboot was needed. Failure detail is
# therefore appended to a size-capped file on the boot partition — written only
# when something actually goes wrong, to keep steady-state SD writes at zero.
set -uo pipefail

CONF=/etc/default/player-net
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

WIFI_IFACE="${WIFI_IFACE:-wlan0}"
NETLOG_FILE="${NETLOG_FILE:-/boot/firmware/netlog.txt}"
NETLOG_MAX_BYTES="${NETLOG_MAX_BYTES:-262144}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
FAIL_RECONNECT="${FAIL_RECONNECT:-2}"
FAIL_RELOAD="${FAIL_RELOAD:-6}"
FAIL_REBOOT="${FAIL_REBOOT:-12}"
BOOT_GRACE="${BOOT_GRACE:-120}"
REBOOT_STATE_FILE="${REBOOT_STATE_FILE:-/boot/firmware/netwatch-reboots}"
MAX_AUTO_REBOOTS="${MAX_AUTO_REBOOTS:-3}"
THROTTLE_CHECKS="${THROTTLE_CHECKS:-20}"

JOURNAL_PATTERN='wlan|wifi|NetworkManager|wpa_supplicant|CTRL-EVENT|deauth|disassoc|beacon|brcmfmac|mt7601|link is'

# Truncate in place rather than rotating: keeps the inode stable and bounds
# writes to a FAT partition where a torn rename would be worse than lost lines.
cap_log() {
    local size
    size=$(stat -c %s "$NETLOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$NETLOG_MAX_BYTES" ]; then
        local keep="${NETLOG_FILE}.keep"
        # `tail -n +2` discards the partial line the byte-based trim leaves behind.
        if tail -c $((NETLOG_MAX_BYTES / 2)) "$NETLOG_FILE" | tail -n +2 > "$keep" 2>/dev/null; then
            cat "$keep" > "$NETLOG_FILE" 2>/dev/null || true
        fi
        rm -f "$keep" 2>/dev/null || true
    fi
}

log() {
    local msg
    msg="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] netwatch: $*"
    echo "$msg"
    cap_log
    echo "$msg" >> "$NETLOG_FILE" 2>/dev/null || true
    sync "$NETLOG_FILE" 2>/dev/null || true
}

capture_journal() {
    {
        echo "--- journal excerpt $(date -u '+%Y-%m-%dT%H:%M:%SZ') ---"
        journalctl -n 400 -o short-iso --no-pager 2>/dev/null \
            | grep -Ei "$JOURNAL_PATTERN" | tail -n 60
        echo "--- iface state ---"
        ip -br addr show "$WIFI_IFACE" 2>/dev/null
        grep -E "^\s*${WIFI_IFACE}:" /proc/net/wireless 2>/dev/null
        echo "--- end excerpt ---"
    } >> "$NETLOG_FILE" 2>/dev/null || true
    sync "$NETLOG_FILE" 2>/dev/null || true
}

gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

reachable() {
    local gw
    gw=$(gateway)
    [ -n "$gw" ] || return 1
    ping -c 2 -W 3 -I "$WIFI_IFACE" "$gw" >/dev/null 2>&1
}

wifi_driver() {
    local drv
    drv=$(readlink -f "/sys/class/net/${WIFI_IFACE}/device/driver" 2>/dev/null) || return 1
    [ -n "$drv" ] && [ "$drv" != "/" ] || return 1
    basename "$drv"
}

escalate_reconnect() {
    log "escalation 1/3: bouncing the NetworkManager connection on ${WIFI_IFACE}"
    local con
    con=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
        | awk -F: -v d="$WIFI_IFACE" '$2 == d {print $1; exit}')
    if [ -z "$con" ]; then
        con=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
            | awk -F: '$2 ~ /wireless|wifi/ {print $1; exit}')
    fi
    nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
    sleep 2
    if [ -n "$con" ]; then
        nmcli connection up "$con" >/dev/null 2>&1 || true
    else
        nmcli device connect "$WIFI_IFACE" >/dev/null 2>&1 || true
    fi
    sleep 10
}

escalate_reload_driver() {
    local drv
    if ! drv=$(wifi_driver); then
        log "escalation 2/3: cannot determine driver for ${WIFI_IFACE}, skipping reload"
        return
    fi
    log "escalation 2/3: reloading WiFi driver '${drv}'"
    ip link set "$WIFI_IFACE" down 2>/dev/null || true
    # brcmfmac pulls in a vendor shim that has to go first, and a wedged USB
    # adapter can hold a reference for a moment after the link drops.
    modprobe -r brcmfmac_wcc 2>/dev/null || true
    if ! modprobe -r "$drv" 2>/dev/null; then
        sleep 5
        modprobe -r "$drv" 2>/dev/null || log "  modprobe -r ${drv} failed"
    fi
    sleep 3
    modprobe "$drv" 2>/dev/null || log "  modprobe ${drv} failed"
    sleep 15
}

read_reboot_count() {
    local count=0
    if [ -r "$REBOOT_STATE_FILE" ]; then
        count=$(cat "$REBOOT_STATE_FILE" 2>/dev/null) || count=0
        case "$count" in
            ''|*[!0-9]*) count=0 ;;
        esac
    fi
    echo "$count"
}

escalate_reboot() {
    local count
    count=$(read_reboot_count)

    # Rebooting cannot fix an outage that is not ours (AP down, PSK rotated).
    # After the cap, keep trying the cheaper recoveries instead of power-cycling
    # in a loop until someone notices.
    if [ "$count" -ge "$MAX_AUTO_REBOOTS" ]; then
        log "escalation 3/3: ${count} self-reboot(s) already failed to recover; not rebooting again"
        escalate_reload_driver
        return
    fi

    count=$((count + 1))
    log "escalation 3/3: recovery exhausted, rebooting (self-reboot ${count}/${MAX_AUTO_REBOOTS})"
    capture_journal
    echo "$count" > "$REBOOT_STATE_FILE" 2>/dev/null || true
    sync 2>/dev/null || true
    systemctl reboot 2>/dev/null || reboot -f
}

sleep "$BOOT_GRACE"
log "started (iface=${WIFI_IFACE}, interval=${CHECK_INTERVAL}s)"

fails=0
while true; do
    if reachable; then
        if [ "$fails" -gt 0 ]; then
            log "recovered after ${fails} failed check(s)"
        fi
        fails=0
        # A good check means any earlier self-reboot did its job. Guarded so
        # the steady state performs no writes at all.
        if [ -e "$REBOOT_STATE_FILE" ]; then
            rm -f "$REBOOT_STATE_FILE" 2>/dev/null || true
        fi
    else
        fails=$((fails + 1))
        # Past the reboot threshold this could run for days against an outage
        # we cannot fix, so throttle both logging and recovery attempts.
        if [ "$fails" -le "$FAIL_REBOOT" ] || [ $((fails % THROTTLE_CHECKS)) -eq 0 ]; then
            log "gateway unreachable (consecutive failures: ${fails})"
        fi
        if [ "$fails" -eq 1 ]; then
            capture_journal
        fi

        if [ "$fails" -eq "$FAIL_RECONNECT" ]; then
            escalate_reconnect
        elif [ "$fails" -eq "$FAIL_RELOAD" ]; then
            escalate_reload_driver
        elif [ "$fails" -eq "$FAIL_REBOOT" ] ||
             { [ "$fails" -gt "$FAIL_REBOOT" ] && [ $((fails % THROTTLE_CHECKS)) -eq 0 ]; }; then
            escalate_reboot
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
WATCHDOG
    chmod +x /usr/local/bin/player-netwatch.sh

    cat > /etc/systemd/system/player-netwatch.service <<EOF
[Unit]
Description=Player network watchdog
After=NetworkManager.service
Wants=NetworkManager.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/player-netwatch.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable player-netwatch.service
    echo "  Network watchdog installed for ${iface} (log: ${BOOT_PART}/netlog.txt)"
}

# ══ CLOCK PERSISTENCE ══════════════════════════════════════════════════════════
# The Pi has no RTC, and the overlay means fake-hwclock's own data file is
# reverted to its image-bake value on every boot. Left alone, every boot starts
# at the date the card was written until NTP catches up, which misdates all
# early-boot log lines and makes timelines across reboots unreadable.
configure_clock_persistence() {
    echo "Configuring clock persistence to boot partition..."

    local clock_file="${BOOT_PART}/clock.save"

    cat > /usr/local/bin/player-clock.sh <<EOF
#!/bin/bash
# Persist/restore the system clock across reboots on a Pi with no RTC.
# Installed by provision.sh.
set -uo pipefail
CLOCK_FILE="${clock_file}"
EOF
    cat >> /usr/local/bin/player-clock.sh <<'CLOCK'

case "${1:-}" in
    save)
        date -u '+%s' > "$CLOCK_FILE" 2>/dev/null || exit 0
        sync "$CLOCK_FILE" 2>/dev/null || true
        ;;
    restore)
        [ -r "$CLOCK_FILE" ] || exit 0
        saved=$(cat "$CLOCK_FILE" 2>/dev/null) || exit 0
        case "$saved" in
            ''|*[!0-9]*) exit 0 ;;
        esac
        now=$(date -u '+%s')
        # Only ever move the clock forward; NTP corrects the rest.
        if [ "$saved" -gt "$now" ]; then
            date -u -s "@${saved}" >/dev/null 2>&1 || true
        fi
        ;;
    *)
        echo "usage: $0 {save|restore}" >&2
        exit 2
        ;;
esac
CLOCK
    chmod +x /usr/local/bin/player-clock.sh

    cat > /etc/systemd/system/player-clock-restore.service <<EOF
[Unit]
Description=Restore system clock from boot partition
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target time-set.target systemd-timesyncd.service
ConditionPathExists=${BOOT_PART}/clock.save

[Service]
Type=oneshot
ExecStart=/usr/local/bin/player-clock.sh restore
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

    cat > /etc/systemd/system/player-clock-save.service <<EOF
[Unit]
Description=Persist system clock to boot partition

[Service]
Type=oneshot
ExecStart=/usr/local/bin/player-clock.sh save
EOF

    cat > /etc/systemd/system/player-clock-save.timer <<EOF
[Unit]
Description=Persist system clock hourly

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF

    # Separate unit purely for the shutdown hook: ExecStop fires on clean
    # shutdown, capturing a more recent time than the last hourly tick.
    cat > /etc/systemd/system/player-clock-shutdown.service <<EOF
[Unit]
Description=Persist system clock on shutdown
DefaultDependencies=no
After=local-fs.target
Before=shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/bin/player-clock.sh save

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable player-clock-restore.service
    systemctl enable player-clock-save.timer
    systemctl enable player-clock-shutdown.service

    # Seed it now so the very first post-provisioning boot has a sane baseline.
    /usr/local/bin/player-clock.sh save || true
    echo "  Clock persistence installed (${clock_file})."
}

# ══ NETWORK CONFIGURATION ══════════════════════════════════════════════════════
configure_network() {
    echo "Configuring network (WIFI_MODE=${WIFI_MODE})..."

    # Always write NM global config for robust reconnection
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-reconnect.conf <<EOF
[connection]
connection.autoconnect-retries=-1

[device]
wifi.scan-rand-mac-address=no
EOF

    # Power save is disabled globally rather than per-profile. A per-connection
    # setting applied with `nmcli connection modify` only sticks if the profile
    # survives, and these profiles are generated into /run by netplan on every
    # boot. A conf.d drop-in is immune to that, and covers built-in radios too:
    # mac80211 leaves power save on by default, which costs latency on Snapcast
    # and drops the association outright on some USB adapters.
    cat > /etc/NetworkManager/conf.d/99-powersave-off.conf <<EOF
[connection]
wifi.powersave=2
EOF
    echo "  WiFi power save disabled globally (wifi.powersave=2)."

    # Find the existing WiFi connection profile
    local wifi_profile
    wifi_profile=$(nmcli -t -f NAME,TYPE connection show \
        | grep -E ':(wifi|802-11-wireless)$' | head -1 | cut -d: -f1) || true

    case "$WIFI_MODE" in

        none)
            echo "  Disabling WiFi entirely..."
            # rfkill soft-block state lives under /var/lib, which the overlay
            # discards, so the durable switch is the device-tree overlay on the
            # boot partition. rfkill still handles the current boot.
            rfkill block wifi 2>/dev/null || true
            if ! grep -q '^dtoverlay=disable-wifi' "${BOOT_PART}/config.txt" 2>/dev/null; then
                printf '\n# WIFI_MODE=none — disable onboard WiFi radio\ndtoverlay=disable-wifi\n' \
                    >> "${BOOT_PART}/config.txt"
                echo "  Added dtoverlay=disable-wifi to config.txt (persists across reboots)."
            fi
            # Also set all wifi profiles to not autoconnect
            while IFS= read -r profile; do
                nmcli connection modify "$profile" connection.autoconnect no 2>/dev/null || true
            done < <(nmcli -t -f NAME,TYPE connection show | grep ':wifi$' | cut -d: -f1 || true)
            echo "  WiFi disabled."
            ;;

        usb)
            echo "  Configuring USB WiFi (wlan1) as primary, disabling built-in (wlan0)..."
            if [ -z "$wifi_profile" ]; then
                echo "  WARNING: No WiFi profile found — skipping WiFi config"
                return 0
            fi

            # Bind the profile to wlan1 with a low metric. Power save is handled
            # by the global drop-in above, not here.
            nmcli connection modify "$wifi_profile" \
                connection.interface-name wlan1 \
                ipv4.route-metric 100 \
                ipv6.route-metric 100 \
                connection.autoconnect yes \
                connection.autoconnect-retries -1
            echo "  Bound '$wifi_profile' to wlan1 (metric=100)"

            # Disable built-in wlan0 via NetworkManager
            nmcli radio wifi off 2>/dev/null || true
            # Re-enable just so NM manages wlan1
            nmcli radio wifi on 2>/dev/null || true
            # Match the onboard radio by driver rather than by SDIO address:
            # "mmc1:0001:1" is the Pi 3 path and silently matches nothing on
            # Pi 4/5/Zero 2.
            cat > /etc/udev/rules.d/70-disable-builtin-wifi.rules <<'EOF'
# Disable built-in WiFi, prefer USB adapter
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="brcmfmac", RUN+="/usr/sbin/ip link set %k down"
EOF
            # More reliable: use NM to ignore wlan0
            cat > /etc/NetworkManager/conf.d/99-ignore-wlan0.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
            echo "  Built-in wlan0 unmanaged by NM."

            # Dispatcher: disable wpa_supplicant background scanning when wlan1 comes up.
            # USB adapters (MT7601U and similar) aggressively roam-hunt every few seconds
            # when bgscan is active, deauthenticating and breaking long-lived TCP streams.
            # Firing on "up" (not "down") avoids triggering scans via nmcli connection up.
            mkdir -p /etc/NetworkManager/dispatcher.d
            cat > /etc/NetworkManager/dispatcher.d/99-wifi-bgscan-disable.sh <<'EOF'
#!/bin/bash
INTERFACE="$1"
ACTION="$2"
if [ "$ACTION" = "up" ] && [ "$INTERFACE" = "wlan1" ]; then
    wpa_cli -p /var/run/wpa_supplicant -i wlan1 set_network 0 bgscan '""' 2>/dev/null || true
fi
EOF
            chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-bgscan-disable.sh
            echo "  bgscan-disable dispatcher installed."

            install_net_watchdog wlan1
            ;;

        builtin|*)
            echo "  Using built-in WiFi (wlan0)..."
            if [ -z "$wifi_profile" ]; then
                echo "  WARNING: No WiFi profile found — skipping WiFi config"
                return 0
            fi

            # Ensure wlan0 profile has good reconnection settings
            nmcli connection modify "$wifi_profile" \
                connection.interface-name wlan0 \
                ipv4.route-metric 100 \
                ipv6.route-metric 100 \
                connection.autoconnect yes \
                connection.autoconnect-retries -1
            echo "  Configured '$wifi_profile' on wlan0 (metric=100)"

            # If a USB adapter appears, make NM ignore it
            cat > /etc/NetworkManager/conf.d/99-ignore-wlan1.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan1
EOF
            echo "  wlan1 set as unmanaged (USB adapter ignored if present)."

            # Install dispatcher script for persistent reconnection
            mkdir -p /etc/NetworkManager/dispatcher.d
            cat > /etc/NetworkManager/dispatcher.d/99-wifi-reconnect.sh <<'EOF'
#!/bin/bash
INTERFACE="$1"
ACTION="$2"
if [ "$ACTION" = "down" ] && [ "$INTERFACE" = "wlan0" ]; then
    sleep 5
    nmcli connection up "$(nmcli -t -f NAME,DEVICE connection show | grep ':wlan0' | head -1 | cut -d: -f1)" 2>/dev/null || true
fi
EOF
            chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-reconnect.sh
            echo "  Reconnection dispatcher installed."

            install_net_watchdog wlan0
            ;;
    esac
}

# ══ STARTUP CHIME ══════════════════════════════════════════════════════════════
install_startup_chime() {
    local audio_device="$1"
    local flag="${BOOT_PART}/chime-played"

    cat > /usr/local/bin/startup-chime.sh <<EOF
#!/bin/bash
# Play a startup chime once on first post-provisioning boot, then never again.
FLAG="${flag}"
DEVICE="${audio_device}"

[ -f "\$FLAG" ] && exit 0

# Three ascending tones: a pleasant major chord (C E G)
sox -n -r 48000 -c 2 /tmp/chime.wav \
    synth 0.18 sine 523.25 fade 0 0.18 0.05 \
    synth 0.18 sine 659.25 fade 0 0.18 0.05 delay 0.20 \
    synth 0.22 sine 783.99 fade 0 0.22 0.08 delay 0.40 \
    gain -6 2>/dev/null

aplay -D "\$DEVICE" /tmp/chime.wav 2>/dev/null
rm -f /tmp/chime.wav

touch "\$FLAG"
systemctl disable startup-chime.service
EOF
    chmod +x /usr/local/bin/startup-chime.sh

    # Ordered BEFORE the player, not after: the chime holds the sound card for
    # about three seconds, and a player starting alongside it fails to open the
    # device with EBUSY. Being a oneshot, the player waits for it to finish.
    # On later boots the chime has disabled itself, so this costs nothing.
    cat > /etc/systemd/system/startup-chime.service <<EOF
[Unit]
Description=Play startup chime on first post-provisioning boot
After=sound.target alsa-restore-boot.service
$([ -n "$PLAYER_UNITS" ] && echo "Before=${PLAYER_UNITS}")
Wants=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/startup-chime.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable startup-chime.service
    echo "Startup chime service installed."
}

# ══ PASSWORDLESS SUDO ══════════════════════════════════════════════════════════
configure_passwordless_sudo() {
    local pi_user
    pi_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}') || true
    if [ -n "$pi_user" ]; then
        echo "${pi_user} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/010-nopasswd
        chmod 440 /etc/sudoers.d/010-nopasswd
        echo "Passwordless sudo enabled for: ${pi_user}"
    else
        echo "WARNING: No regular user found, skipping passwordless sudo"
    fi
}

# ══ VERSION STAMP ══════════════════════════════════════════════════════════════
# Records which revision of the provisioner built this card. Without it there is
# no way to tell a running player apart from one imaged before a given fix — and
# a card written from an uncommitted working copy looks identical to a released
# one. PROVISIONER_VERSION is set in player.env by patch-userdata.py.
write_version_stamp() {
    local stamp="${BOOT_PART}/provisioner-version"

    # Ground truth for what audio hardware actually enumerated, independent of
    # what HAT_OVERLAY claimed. Answers "what is in this box?" without having to
    # infer it from a kernel module list.
    local cards
    cards=$(aplay -l 2>/dev/null | sed -n 's/^card [0-9]*: \([^ ]*\) .*/\1/p' \
        | sort -u | paste -sd, -) || true
    [ -z "$cards" ] && cards="none"

    {
        echo "version:      ${PROVISIONER_VERSION}"
        echo "provisioned:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "hostname:     $(hostname 2>/dev/null || echo unknown)"
        echo "player_type:  ${PLAYER_TYPE}"
        echo "wifi_mode:    ${WIFI_MODE}"
        echo "multi_output: ${MULTI_OUTPUT}"
        echo "room_name:    ${ROOM_NAME}"
        echo "ma_host:      ${MA_HOST}"
        echo "hat_overlay:  ${HAT_OVERLAY}"
        echo "audio_device: ${AUDIO_DEVICE}"
        echo "latency_ms:   ${SNAPCLIENT_LATENCY:-0}"
        echo "sound_cards:  ${cards}"
    } > /etc/provisioner-version
    cp /etc/provisioner-version "$stamp" 2>/dev/null || true
    echo "Version stamp written: ${PROVISIONER_VERSION} (cards: ${cards})"
}

# ══ JOURNALD → RAM ═════════════════════════════════════════════════════════════
# Logs stay in RAM to spare the SD card. The network watchdog is the escape
# hatch: it copies the relevant journal excerpt to the boot partition at the
# moment a fault is detected, so a reboot no longer destroys the only evidence.
configure_journald() {
    echo "Configuring journald to use volatile (RAM) storage..."
    if grep -q "^Storage=" /etc/systemd/journald.conf; then
        sed -i 's/^Storage=.*/Storage=volatile/' /etc/systemd/journald.conf
    elif grep -q "^#Storage=" /etc/systemd/journald.conf; then
        sed -i 's/^#Storage=.*/Storage=volatile/' /etc/systemd/journald.conf
    else
        echo "Storage=volatile" >> /etc/systemd/journald.conf
    fi
}

# ══ MAIN ═══════════════════════════════════════════════════════════════════════
# Note: hostname and /etc/hosts are handled by cloud-init (user-data bootcmd
# + manage_etc_hosts: true) before this script runs. No set_hostname() needed.

# 1. Configure audio routing and player daemon
if [ "${PLAYER_TYPE}" = "airplay" ]; then
    setup_airplay
elif [ "${MULTI_OUTPUT}" = "true" ]; then
    setup_multi_output
else
    setup_single_output
fi

# 2. Set all cards to max volume and persist ALSA state to boot partition
configure_alsa

# 3. Configure network interface preference, reconnection and watchdog
configure_network

# 4. Persist the clock across reboots (no RTC + overlay FS)
configure_clock_persistence

# 5. Install startup chime (plays once on first post-provisioning boot)
if [ "${MULTI_OUTPUT}" = "true" ]; then
    first_room_raw=$(grep "^OUTPUT_1_ROOM=" "$BOOT_ENV_CLEAN" | cut -d= -f2 | tr -d '"') || true
    first_room_slug=$(echo "${first_room_raw}" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')
    install_startup_chime "default:CARD=room_${first_room_slug}"
else
    install_startup_chime "${AUDIO_DEVICE}"
fi

# 6. Logs to RAM only
configure_journald

# 7. Passwordless sudo for the provisioned user
configure_passwordless_sudo

# 8. Record which revision built this card
write_version_stamp

# 9. Restore /etc/issue and notify before reboot
printf 'Raspbian GNU/Linux \\n \\l\n' > /etc/issue
wall $'\n*** PROVISIONING COMPLETE — rebooting now. ***\nThis is expected and normal.\n' 2>/dev/null || true
printf '\n\n*** PROVISIONING COMPLETE — rebooting now. ***\n\n' > /dev/tty1 2>/dev/null || true

rm -f "${BOOT_PART}/provision-failed.txt" 2>/dev/null || true
sync 2>/dev/null || true

# 10. Enable overlay filesystem — must be last step before reboot
echo "Enabling overlay filesystem..."
raspi-config nonint enable_overlayfs

echo "=== Provisioning complete: $(date) ==="
