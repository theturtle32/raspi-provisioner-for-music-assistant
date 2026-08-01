#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml"]
# ///
"""
patch-userdata.py — Prepare a Snapcast/AirPlay player SD card

Usage:
    uv run patch-userdata.py /Volumes/bootfs        # no install needed
    python3 patch-userdata.py /media/username/bootfs

What it does:
  1. Prompts for player config and writes /boot/firmware/player.env
     (including PROVISIONER_VERSION, so a running player can report which
     revision built it)
  2. Patches Imager's user-data:
       - Sets hostname: snapplayer-<room> directly
       - Removes legacy bootcmd entries from previous runs (idempotent)
       - Removes player packages from packages key (moved to runcmd)
       - Always updates embedded provision.sh via write_files (read from disk)
       - Adds NTP time-sync wait + apt-get update + install to runcmd
       - Adds runcmd to run provision.sh
       - Adds power_state reboot
  3. Optionally patches /boot/firmware/config.txt for HAT overlays
  4. Backs up the original user-data as user-data.bak (once)

Requirements:
    pyyaml. Either run via `uv run patch-userdata.py` (which resolves the
    inline dependency block above automatically) or `pip install pyyaml`
    into whichever interpreter you invoke.

provision.sh must be in the same directory as this script.
"""

import sys
import os
import shutil
import subprocess

try:
    import yaml
except ImportError:
    sys.exit(
        "ERROR: pyyaml is not available to this interpreter.\n"
        f"       ({sys.executable})\n"
        "\n"
        "Easiest fix, no install required:\n"
        "    uv run patch-userdata.py <boot-partition>\n"
        "\n"
        "Or install it into the interpreter you are using:\n"
        f"    {sys.executable} -m pip install pyyaml"
    )

# Known HAT overlays — maps a short name to (dtoverlay, disable_onboard_audio)
HAT_OVERLAYS = {
    "merus-amp":         ("merus-amp",         True),
    "hifiberry-amp":     ("hifiberry-amp",      True),
    "hifiberry-dac":     ("hifiberry-dac",      True),
    "hifiberry-dacplus": ("hifiberry-dacplus",  True),
    "none":              None,
}


def provisioner_version():
    """
    Return an identifier for the provisioner revision building this card.

    A dirty working tree is marked as such: a card written from uncommitted
    changes is otherwise indistinguishable from one built at the recorded
    commit, which makes "does this player have fix X?" unanswerable later.

    Returns "unknown" outside a git checkout.
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))

    def git(*args):
        return subprocess.run(("git", "-C", script_dir) + args,
                              capture_output=True, text=True, timeout=10)

    try:
        rev = git("rev-parse", "--short", "HEAD")
        if rev.returncode != 0:
            return "unknown"
        version = rev.stdout.strip()

        status = git("status", "--porcelain")
        if status.returncode == 0 and status.stdout.strip():
            version += "-dirty"
        return version
    except (OSError, subprocess.SubprocessError):
        return "unknown"


ARCHIVE_DIRNAME = "players"


def archive_dir():
    """Directory holding a copy of every player.env this script has written."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        ARCHIVE_DIRNAME)


def read_env_file(path):
    """Parse a shell-style KEY=value file into a dict, ignoring comments."""
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                values[k.strip()] = v.strip().strip('"')
    return values


def list_archived_players():
    """Return [(label, path)] of previously prepared players, newest first."""
    directory = archive_dir()
    if not os.path.isdir(directory):
        return []
    entries = []
    for name in sorted(os.listdir(directory)):
        if name.endswith(".env"):
            full = os.path.join(directory, name)
            entries.append((name[:-4], full, os.path.getmtime(full)))
    entries.sort(key=lambda e: e[2], reverse=True)
    return [(label, path) for label, path, _ in entries]


def seed_from_archive():
    """
    Offer to pre-fill prompts from a previously prepared player.

    Re-imaging a card rewrites the boot partition and takes player.env with it,
    so without a copy held on this machine every reflash means reconstructing
    each answer by hand.
    """
    players = list_archived_players()
    if not players:
        return {}

    print("\n  No player.env on this card — writing a fresh image wipes it.")
    print("  Previously prepared players:")
    for i, (label, _) in enumerate(players, 1):
        print(f"    {i}) {label}")
    print("    n) start fresh")

    choice = prompt("Seed prompts from which?", "1").strip().lower()
    if choice in ("n", "no", "none"):
        return {}

    try:
        index = int(choice)
    except ValueError:
        print("  Unrecognised choice — starting fresh.")
        return {}

    if not 1 <= index <= len(players):
        print("  Out of range — starting fresh.")
        return {}

    label, path = players[index - 1]
    print(f"  Seeding from '{label}'")
    values = read_env_file(path)
    # The archived revision describes the card that was built then; this run
    # stamps its own.
    values.pop("PROVISIONER_VERSION", None)
    return values


def ensure_host_key(hostname):
    """
    Return (private_key_text, public_key_line) for this player's pinned SSH
    host key, generating and archiving one the first time it is needed.

    Reuse across re-images is the entire point. A fresh image otherwise presents
    a new host identity every time, so each reflash trips host key verification
    and has to be waved through — which trains you to wave through the one
    warning that would ever matter.

    :param hostname: Player hostname, used as the archive filename and key comment.
    """
    directory = archive_dir()
    os.makedirs(directory, exist_ok=True)
    private_path = os.path.join(directory, f"{hostname}.hostkey")
    public_path = private_path + ".pub"

    if not os.path.exists(private_path):
        subprocess.run(
            ("ssh-keygen", "-t", "ed25519", "-N", "", "-C", hostname,
             "-f", private_path),
            check=True, capture_output=True, text=True,
        )
        print(f"  Generated SSH host key for {hostname}")
    else:
        print(f"  Reusing archived SSH host key for {hostname}")

    os.chmod(private_path, 0o600)

    with open(private_path) as f:
        private_text = f.read()
    with open(public_path) as f:
        public_text = f.read().strip()

    return private_text, public_text


def save_archive_copy(player_env_path, hostname):
    """Keep a copy of the finished player.env, keyed by hostname."""
    directory = archive_dir()
    os.makedirs(directory, exist_ok=True)
    dest = os.path.join(directory, f"{hostname}.env")
    shutil.copy2(player_env_path, dest)
    return dest


def load_provision_sh():
    """Load provision.sh from the same directory as this script."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    provision_path = os.path.join(script_dir, "provision.sh")
    if not os.path.exists(provision_path):
        print(f"ERROR: provision.sh not found at {provision_path}")
        print("provision.sh must be in the same directory as patch-userdata.py")
        sys.exit(1)
    with open(provision_path) as f:
        return f.read()


def patch_config_txt(boot_partition, overlay_name, disable_onboard_audio):
    """Add dtoverlay to config.txt and optionally disable onboard audio."""
    config_path = os.path.join(boot_partition, "config.txt")
    if not os.path.exists(config_path):
        print(f"  WARNING: {config_path} not found, skipping HAT config")
        return

    with open(config_path) as f:
        lines = f.readlines()

    changed = []
    new_lines = []
    overlay_line = f"dtoverlay={overlay_name}\n"
    already_has_overlay = any(overlay_line.strip() in l for l in lines)

    for line in lines:
        stripped = line.strip()

        if disable_onboard_audio and stripped == "dtparam=audio=on":
            new_lines.append(f"#dtparam=audio=on  # disabled for HAT: {overlay_name}\n")
            changed.append("Disabled dtparam=audio=on (conflicts with HAT)")
            continue

        if stripped == overlay_line.strip():
            new_lines.append(line)
            already_has_overlay = True
            continue

        new_lines.append(line)

    if not already_has_overlay:
        new_lines.append(f"\n# HAT audio overlay\n{overlay_line}")
        changed.append(f"Added dtoverlay={overlay_name}")

    with open(config_path, "w") as f:
        f.writelines(new_lines)

    if changed:
        for c in changed:
            print(f"  + {c}")
    else:
        print(f"  (config.txt already configured for {overlay_name})")


def prompt(label, default=None):
    if default:
        value = input(f"  {label} [{default}]: ").strip()
        return value if value else default
    else:
        while True:
            value = input(f"  {label}: ").strip()
            if value:
                return value
            print("    (required)")


def load_user_data(path):
    with open(path, "r") as f:
        content = f.read()
    lines = content.splitlines()
    if lines and lines[0].strip() == "#cloud-config":
        yaml_content = "\n".join(lines[1:])
    else:
        yaml_content = content
    return yaml.safe_load(yaml_content) or {}


def _literal_block_str(dumper, data):
    """Emit multi-line strings as YAML literal blocks instead of escaped one-liners."""
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


# Without this the embedded provision.sh and the PEM-formatted host key are both
# dumped as single enormous \n-escaped strings, leaving user-data unreadable and
# undiffable. Semantics are identical either way; PyYAML falls back to quoting
# automatically for any string a literal block cannot represent exactly.
yaml.add_representer(str, _literal_block_str)


def save_user_data(path, data):
    with open(path, "w") as f:
        f.write("#cloud-config\n")
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True,
                  sort_keys=False)


def derive_hostname(room_name):
    """Return a valid lowercase hostname from a room name."""
    slug = room_name.lower().replace(" ", "-").replace("_", "-")
    slug = "".join(c for c in slug if c.isalnum() or c == "-")
    return "snapplayer-" + slug


def patch(data, hostname, multi_output, player_type="snapcast"):
    """Patch user-data dict in place. Returns list of change descriptions."""
    changed = []

    # ── hostname ───────────────────────────────────────────────────────────────
    if data.get("hostname") != hostname:
        data["hostname"] = hostname
        changed.append(f"Set hostname: {hostname}")

    # ── manage_etc_hosts ───────────────────────────────────────────────────────
    if not data.get("manage_etc_hosts"):
        data["manage_etc_hosts"] = True
        changed.append("Set manage_etc_hosts: true")

    # ── Remove legacy bootcmd entries from previous runs ───────────────────────
    existing_bootcmd = data.get("bootcmd", [])
    filtered_bootcmd = [c for c in existing_bootcmd
                        if "player.env" not in str(c)
                        and "time-wait-sync" not in str(c)]
    if len(filtered_bootcmd) != len(existing_bootcmd):
        if filtered_bootcmd:
            data["bootcmd"] = filtered_bootcmd
        else:
            data.pop("bootcmd", None)
        changed.append("Removed legacy bootcmd entries")

    # ── packages: remove player packages (moved to runcmd) ────────────────────
    # Keeping packages here causes cloud-init to run apt during the config phase
    # before time sync, resulting in GPG signature failures and a spurious reboot.
    our_pkgs = {"snapclient", "alsa-utils", "avahi-daemon", "shairport-sync"}
    existing_pkgs = data.get("packages", [])
    remaining_pkgs = [p for p in existing_pkgs if p not in our_pkgs]
    if len(remaining_pkgs) != len(existing_pkgs):
        if remaining_pkgs:
            data["packages"] = remaining_pkgs
        else:
            data.pop("packages", None)
        changed.append("Moved player packages to runcmd (uses --fix-missing)")

    # ── write_files: always update provision.sh from disk ─────────────────────
    existing_wf = data.get("write_files", [])
    filtered_wf = [e for e in existing_wf
                   if not (isinstance(e, dict)
                           and e.get("path") in ("/usr/local/bin/provision.sh",
                                                  "/etc/issue"))]
    filtered_wf.append({
        "path": "/usr/local/bin/provision.sh",
        "permissions": "0755",
        "content": load_provision_sh(),
    })
    filtered_wf.append({
        "path": "/etc/issue",
        "content": (
            "\n"
            "  *** PROVISIONING IN PROGRESS ***\n"
            "\n"
            "  This system is being configured automatically.\n"
            "  It will reboot when complete. Do not power off.\n"
            "\n"
        ),
    })
    data["write_files"] = filtered_wf
    changed.append("Updated embedded provision.sh")

    # ── runcmd ─────────────────────────────────────────────────────────────────
    existing_runcmd = data.get("runcmd", [])

    time_sync_cmd = "systemctl start systemd-time-wait-sync.service"
    apt_update = "apt-get update"
    player_pkg = "shairport-sync" if player_type == "airplay" else "snapclient"
    apt_install = f"apt-get install -y --fix-missing {player_pkg} alsa-utils avahi-daemon vim sox"

    if not any("time-wait-sync" in str(c) for c in existing_runcmd):
        existing_runcmd.insert(0, time_sync_cmd)
        changed.append("Added NTP time-sync wait to runcmd")

    if not any("apt-get update" in str(c) for c in existing_runcmd):
        idx = next((i for i, c in enumerate(existing_runcmd)
                    if "time-wait-sync" in str(c)), 0)
        existing_runcmd.insert(idx + 1, apt_update)
        changed.append("Added apt-get update to runcmd")

    if not any(player_pkg in str(c) for c in existing_runcmd) and \
       not any("apt-get install" in str(c) for c in existing_runcmd):
        idx = next((i for i, c in enumerate(existing_runcmd)
                    if "apt-get update" in str(c)), 0)
        existing_runcmd.insert(idx + 1, apt_install)
        changed.append(f"Added apt-get install ({player_pkg}) to runcmd")

    if not any("provision.sh" in str(c) for c in existing_runcmd):
        existing_runcmd.append("/usr/local/bin/provision.sh")
        changed.append("Added runcmd: /usr/local/bin/provision.sh")

    data["runcmd"] = existing_runcmd

    # ── ssh_keys: pin the host identity across re-images ──────────────────────
    # Raspberry Pi OS ships regenerate_ssh_host_keys.service, which wipes and
    # regenerates host keys on first boot. It is ConditionFirstBoot=yes and runs
    # at sysinit, so cloud-init's cc_ssh stage lands afterwards and wins; the
    # pinned key is then baked into the image before the overlay is enabled.
    private_key, public_key = ensure_host_key(hostname)
    data["ssh_keys"] = {
        "ed25519_private": private_key,
        "ed25519_public": public_key,
    }
    # Deliberately no ssh_genkeytypes here: cloud-init only consults it (and
    # ssh_deletekeys) on the branch where it generates keys itself. Supplying
    # ssh_keys skips that branch, so RPi OS's earlier `ssh-keygen -A` leaves
    # per-image RSA and ECDSA keys in place regardless. provision.sh prunes them
    # instead, so the pinned ed25519 is the only identity ever presented.
    changed.append("Pinned SSH host key (ed25519)")

    # ── power_state: reboot cleanly after runcmd completes ────────────────────
    if "power_state" not in data:
        data["power_state"] = {
            "mode": "reboot",
            "delay": "now",
            "condition": True,
        }
        changed.append("Added power_state reboot")

    return data, changed


def create_player_env(path, boot_partition):
    existing = {}
    if os.path.exists(path):
        existing = read_env_file(path)
        print(f"\nUpdating existing player.env")
    else:
        print(f"\nCreating player.env")
        existing = seed_from_archive()

    print("  (Press Enter to keep existing value shown in brackets)\n")

    multi = prompt("Multi-output device? (true/false)",
                   existing.get("MULTI_OUTPUT", "false")).lower()

    ma_host = prompt("MA_HOST (Music Assistant server IP)",
                     existing.get("MA_HOST", "192.168.3.42"))

    player_type = prompt("Player type (snapcast/airplay)",
                         existing.get("PLAYER_TYPE", "snapcast")).lower()
    if player_type not in ("snapcast", "airplay"):
        player_type = "snapcast"

    if multi == "true":
        vendor  = prompt("USB_VENDOR_ID", existing.get("USB_VENDOR_ID", "0d8c"))
        product = prompt("USB_PRODUCT_ID", existing.get("USB_PRODUCT_ID", "0008"))
        outputs = []
        print("\n  Enter OUTPUT_N_ROOM / OUTPUT_N_USB_PORT pairs.")
        print("  Leave ROOM blank to finish.\n")
        n = 1
        while True:
            room = input(f"  OUTPUT_{n}_ROOM: ").strip()
            if not room:
                break
            port = prompt(f"OUTPUT_{n}_USB_PORT")
            latency = prompt(
                f"OUTPUT_{n}_LATENCY in ms (0 = no offset)",
                existing.get(f"OUTPUT_{n}_LATENCY", "0")
            )
            outputs.append((room, port, latency))
            n += 1

        lines = [
            "# Player provisioning config",
            f"MA_HOST={ma_host}",
            f"PLAYER_TYPE={player_type}",
            f"USB_VENDOR_ID={vendor}",
            f"USB_PRODUCT_ID={product}",
            "MULTI_OUTPUT=true",
        ]
        for i, (room, port, latency) in enumerate(outputs, 1):
            lines.append(f'OUTPUT_{i}_ROOM="{room}"')
            lines.append(f"OUTPUT_{i}_USB_PORT={port}")
            if latency != "0":
                lines.append(f"OUTPUT_{i}_LATENCY={latency}")

        room_name = None

    else:
        room_name = prompt("ROOM_NAME (e.g. kitchen, living_room)",
                           existing.get("ROOM_NAME", ""))
        audio = prompt("AUDIO_DEVICE", existing.get("AUDIO_DEVICE", "auto"))

        lines = [
            "# Player provisioning config",
            f"MA_HOST={ma_host}",
            f"PLAYER_TYPE={player_type}",
            f'ROOM_NAME="{room_name}"',
            f"AUDIO_DEVICE={audio}",
        ]

        if player_type == "snapcast":
            latency = prompt(
                "SNAPCLIENT_LATENCY in ms (0 = no offset)",
                existing.get("SNAPCLIENT_LATENCY", "0")
            )
            if latency != "0":
                lines.append(f"SNAPCLIENT_LATENCY={latency}")

    # ── WiFi mode ─────────────────────────────────────────────────────────────
    print("\n  WiFi mode:")
    print("    builtin  — use built-in wlan0 (default)")
    print("    usb      — use USB adapter wlan1, disable built-in")
    print("    none     — disable WiFi entirely (ethernet only)")
    wifi_mode = prompt("WIFI_MODE", existing.get("WIFI_MODE", "builtin")).lower()
    if wifi_mode not in ("builtin", "usb", "none"):
        wifi_mode = "builtin"
    lines.append(f"WIFI_MODE={wifi_mode}")
    if wifi_mode == "usb":
        print("  NOTE: USB WiFi adapter must be plugged in before first boot.")

    # ── HAT selection ─────────────────────────────────────────────────────────
    print("\n  Audio HAT (optional — adds dtoverlay to config.txt)")
    print("  Options: " + ", ".join(HAT_OVERLAYS.keys()))
    hat = prompt("HAT overlay", existing.get("HAT_OVERLAY", "none")).lower()
    hat = hat if hat in HAT_OVERLAYS else "none"
    if hat != "none":
        lines.append(f"HAT_OVERLAY={hat}")

    # ── Provisioner version stamp ─────────────────────────────────────────────
    version = provisioner_version()
    lines.append(f"PROVISIONER_VERSION={version}")
    if version.endswith("-dirty"):
        print("\n  WARNING: the provisioner working tree has uncommitted changes.")
        print("           This card will be stamped as "
              f"'{version}' — commit before imaging")
        print("           if you want the revision to mean anything later.")
    elif version == "unknown":
        print("\n  WARNING: could not determine the provisioner git revision.")
        print("           This card will be stamped 'unknown'.")

    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"  Written: {path}")

    return room_name, multi == "true", hat, player_type


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 patch-userdata.py /Volumes/bootfs")
        print("Example: python3 patch-userdata.py /media/username/bootfs")
        sys.exit(1)

    boot_partition = sys.argv[1].rstrip("/")
    user_data_path = os.path.join(boot_partition, "user-data")
    player_env_path = os.path.join(boot_partition, "player.env")

    if not os.path.isdir(boot_partition):
        print(f"ERROR: {boot_partition} is not a directory")
        sys.exit(1)

    if not os.path.exists(user_data_path):
        print(f"ERROR: {user_data_path} not found")
        print("Is this the right partition? Expected to find user-data there.")
        sys.exit(1)

    # ── player.env first — we need room_name to derive hostname ───────────────
    room_name, multi_output, hat, player_type = create_player_env(
        player_env_path, boot_partition)

    if multi_output:
        hostname = "snapplayer-multi"
    else:
        hostname = derive_hostname(room_name)

    # Keep a copy on this machine. The card's own copy does not survive the next
    # re-image, and this is the only record of what a given player was set to.
    try:
        archived = save_archive_copy(player_env_path, hostname)
        print(f"  Archived config: {os.path.relpath(archived)}")
    except OSError as exc:
        print(f"  WARNING: could not archive player config: {exc}")

    # ── Patch config.txt for HAT if selected ──────────────────────────────────
    if hat and hat != "none" and HAT_OVERLAYS.get(hat):
        overlay_name, disable_onboard = HAT_OVERLAYS[hat]
        print(f"\nPatching config.txt for HAT: {hat}")
        patch_config_txt(boot_partition, overlay_name, disable_onboard)

    # ── Patch user-data ───────────────────────────────────────────────────────
    backup_path = user_data_path + ".bak"
    if not os.path.exists(backup_path):
        shutil.copy2(user_data_path, backup_path)
        print(f"\nBacked up original user-data → user-data.bak")

    data = load_user_data(user_data_path)
    data, changes = patch(data, hostname, multi_output, player_type)
    save_user_data(user_data_path, data)

    print(f"\nPatched: {user_data_path}")
    for c in changes:
        print(f"  + {c}")

    print(f"\nAll done.")
    print(f"  Provisioner version: {provisioner_version()}")
    print(f"  Hostname will be: {hostname}")
    print(f"  Eject the card, insert into Pi, and power on.")
    print(f"  After ~90 seconds '{hostname}' will appear in Music Assistant.")


if __name__ == "__main__":
    main()
