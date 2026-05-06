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
# ════════════════════════════════════════════════════════════════
set -e

# Locate boot partition (Trixie: /boot/firmware, Bookworm: /boot)
if [ -d /boot/firmware ]; then
    BOOT_PART=/boot/firmware
else
    BOOT_PART=/boot
fi

BOOT_ENV="${BOOT_PART}/player.env"
ALSA_STATE="${BOOT_PART}/asound.state"
LOG="/tmp/provision.log"

exec > >(tee -a "$LOG") 2>&1
echo "=== Provisioning started: $(date) ==="

# Notify anyone at the console that provisioning is running
wall $'\n*** PROVISIONING IN PROGRESS ***\nThis system is being configured automatically.\nIt will reboot when complete. Do not power off.\n' 2>/dev/null || true
printf '\n\n*** PROVISIONING IN PROGRESS ***\nThis system is being configured. It will reboot automatically.\nDo not power off.\n\n' > /dev/tty1 2>/dev/null || true

# ── Load config ────────────────────────────────────────────────────────────────
if [ ! -f "$BOOT_ENV" ]; then
    echo "ERROR: $BOOT_ENV not found. Cannot provision."
    exit 1
fi

source "$BOOT_ENV"

if [ -z "$MA_HOST" ]; then
    echo "ERROR: MA_HOST must be set in player.env"
    exit 1
fi

# Sanitize ROOM_NAME for use in hostnames and service names:
# lowercase, spaces and underscores → hyphens, strip any remaining invalid chars
ROOM_SLUG=$(echo "${ROOM_NAME}" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')

# Defaults
PLAYER_TYPE="${PLAYER_TYPE:-snapcast}"
WIFI_MODE="${WIFI_MODE:-builtin}"

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
    card_name=$(aplay -l 2>/dev/null \
        | grep -v "bcm2835" \
        | grep -v "vc4" \
        | grep "^card" \
        | head -1 \
        | sed 's/^card [0-9]*: \([^ ]*\) .*/\1/')

    if [ -n "$card_name" ]; then
        echo "default:CARD=${card_name}"
    else
        echo "default:CARD=Headphones"
    fi
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
    systemctl enable snapclient
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
    systemctl enable shairport-sync
}

# ══ MULTI-OUTPUT SETUP ═════════════════════════════════════════════════════════
setup_multi_output() {
    echo "Setting up multi-output device..."

    local udev_rules=""
    local instance=1
    local vendor="${USB_VENDOR_ID:-0d8c}"
    local product="${USB_PRODUCT_ID:-0008}"

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
        local port="${!port_var}"

        if [ -z "$port" ]; then
            echo "  WARNING: OUTPUT_${n}_ROOM set but OUTPUT_${n}_USB_PORT missing — skipping"
            continue
        fi

        local card_id="room_${room_slug}"
        local latency_var="OUTPUT_${n}_LATENCY"
        local latency_val="${!latency_var}"
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

[Service]
ExecStart=/usr/bin/snapclient \\
    -h ${MA_HOST} \\
    --instance ${instance} \\
    --soundcard default:CARD=${card_id}${latency_opt}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable "snapclient-${room_slug}.service"
        echo "  Enabled snapclient-${room_slug}.service"
        (( instance++ ))
    done < "$BOOT_ENV"

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

    # Find the existing WiFi connection profile
    local wifi_profile
    wifi_profile=$(nmcli -t -f NAME,TYPE connection show \
        | grep -E ':(wifi|802-11-wireless)$' | head -1 | cut -d: -f1)

    case "$WIFI_MODE" in

        none)
            echo "  Disabling WiFi entirely..."
            # Disable both interfaces via rfkill
            rfkill block wifi 2>/dev/null || true
            # Also set all wifi profiles to not autoconnect
            while IFS= read -r profile; do
                nmcli connection modify "$profile" connection.autoconnect no 2>/dev/null || true
            done < <(nmcli -t -f NAME,TYPE connection show | grep ':wifi$' | cut -d: -f1)
            echo "  WiFi disabled."
            ;;

        usb)
            echo "  Configuring USB WiFi (wlan1) as primary, disabling built-in (wlan0)..."
            if [ -z "$wifi_profile" ]; then
                echo "  WARNING: No WiFi profile found — skipping WiFi config"
                return 0
            fi

            # Modify original profile to bind to wlan1 with low metric
            # Disable power saving — USB WiFi adapters (especially MT7601U) drop
            # their association when power save is active, killing TCP streams.
            nmcli connection modify "$wifi_profile" \
                connection.interface-name wlan1 \
                ipv4.route-metric 100 \
                ipv6.route-metric 100 \
                connection.autoconnect yes \
                connection.autoconnect-retries -1 \
                802-11-wireless.powersave 2
            echo "  Bound '$wifi_profile' to wlan1 (metric=100, power save disabled)"

            # Disable built-in wlan0 via NetworkManager
            nmcli radio wifi off 2>/dev/null || true
            # Re-enable just so NM manages wlan1
            nmcli radio wifi on 2>/dev/null || true
            # Soft-block wlan0 specifically via udev rule
            cat > /etc/udev/rules.d/70-disable-builtin-wifi.rules <<'EOF'
# Disable built-in WiFi, prefer USB adapter
SUBSYSTEM=="net", ACTION=="add", KERNELS=="mmc1:0001:1", RUN+="/usr/sbin/ip link set %k down"
EOF
            # More reliable: use NM to ignore wlan0
            cat > /etc/NetworkManager/conf.d/99-ignore-wlan0.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
            echo "  Built-in wlan0 unmanaged by NM."

            # Install dispatcher script for persistent reconnection
            mkdir -p /etc/NetworkManager/dispatcher.d
            cat > /etc/NetworkManager/dispatcher.d/99-wifi-reconnect.sh <<'EOF'
#!/bin/bash
INTERFACE="$1"
ACTION="$2"
if [ "$ACTION" = "down" ] && [ "$INTERFACE" = "wlan1" ]; then
    sleep 5
    nmcli connection up "$(nmcli -t -f NAME,DEVICE connection show | grep ':wlan1' | head -1 | cut -d: -f1)" 2>/dev/null || true
fi
EOF
            chmod +x /etc/NetworkManager/dispatcher.d/99-wifi-reconnect.sh
            echo "  Reconnection dispatcher installed."
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

    cat > /etc/systemd/system/startup-chime.service <<EOF
[Unit]
Description=Play startup chime on first post-provisioning boot
After=sound.target alsa-restore-boot.service snapclient.service
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

# ══ JOURNALD → RAM ═════════════════════════════════════════════════════════════
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

# 3. Configure network interface preference and reconnection
configure_network

# 4. Install startup chime (plays once on first post-provisioning boot)
if [ "${MULTI_OUTPUT}" = "true" ]; then
    first_room_raw=$(grep "^OUTPUT_1_ROOM=" "$BOOT_ENV" | cut -d= -f2 | tr -d '"')
    first_room_slug=$(echo "${first_room_raw}" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')
    install_startup_chime "default:CARD=room_${first_room_slug}"
else
    install_startup_chime "${AUDIO_DEVICE}"
fi

# 5. Logs to RAM only
configure_journald

# 6. Restore /etc/issue and notify before reboot
printf 'Raspbian GNU/Linux \\n \\l\n' > /etc/issue
wall $'\n*** PROVISIONING COMPLETE — rebooting now. ***\nThis is expected and normal.\n' 2>/dev/null || true
printf '\n\n*** PROVISIONING COMPLETE — rebooting now. ***\n\n' > /dev/tty1 2>/dev/null || true

# 7. Enable overlay filesystem — must be last step before reboot
echo "Enabling overlay filesystem..."
raspi-config nonint enable_overlayfs

echo "=== Provisioning complete: $(date) ==="
