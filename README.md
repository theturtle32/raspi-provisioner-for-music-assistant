# Raspberry Pi Provisioner for Music Assistant

Automated SD card provisioning for Raspberry Pi Snapcast and AirPlay players
managed by [Music Assistant](https://music-assistant.io/).

Flash a stock Raspberry Pi OS image, run one script, and the Pi comes up
fully configured — correct hostname, audio routing, network preferences,
ALSA state persistence, and overlay filesystem — ready to appear in Music
Assistant within ~90 seconds of first boot.

---

## How it works

Two files do all the work:

| File | When it runs | What it does |
|------|-------------|--------------|
| `patch-userdata.py` | On your Mac/PC before flashing | Writes `player.env` and patches the Raspberry Pi Imager `user-data` on the boot partition |
| `provision.sh` | On the Pi at first boot (via cloud-init) | Configures audio, networking, ALSA, and overlay FS; embedded in `user-data` by the patching script |

---

## Prerequisites

- **Raspberry Pi Imager** — use it to write Raspberry Pi OS Lite (64-bit) to a
  card, with SSH enabled and WiFi credentials set. Stop before ejecting.
- **Python 3** with PyYAML. Either use [`uv`](https://docs.astral.sh/uv/), which
  resolves the dependency automatically from the script's inline metadata, or
  `pip install pyyaml` into whichever interpreter you invoke. Note that on macOS
  a bare `python3` often resolves to Xcode's interpreter rather than a Homebrew
  one, so it may not be the interpreter you installed PyYAML into.
- **Music Assistant** running on your local network with the Snapcast or AirPlay
  integration enabled.

---

## Quick start

### 1. Flash the card

Use Raspberry Pi Imager to write **Raspberry Pi OS Lite (64-bit)**.
In the Imager settings ("OS Customisation"), configure:

- SSH enabled (password or public key)
- WiFi SSID and password
- Leave hostname as-is — the provisioning script sets it

Do **not** eject the card yet.

### 2. Patch the boot partition

```bash
uv run patch-userdata.py /Volumes/bootfs     # or: python3 patch-userdata.py ...
```

Replace `/Volumes/bootfs` with the actual mount path of the boot partition.
The script prompts for player config, writes `player.env` to the boot
partition, embeds `provision.sh` into `user-data`, and patches the cloud-init
config.

### 3. Eject and boot

Eject the card, insert it into the Pi, and power on. The Pi will:

1. Sync time via NTP
2. Install the required packages (`snapclient` or `shairport-sync`, `alsa-utils`, etc.)
3. Run `provision.sh`
4. Reboot

After the final reboot (~90 seconds total), the player appears in Music
Assistant.

---

## Configuration prompts

`patch-userdata.py` asks for these values. Press Enter to keep the value
shown in brackets when re-running against an already-configured card.

| Prompt | Description |
|--------|-------------|
| `MULTI_OUTPUT` | `true` for a USB hub with multiple DACs; `false` (default) for a single output |
| `MA_HOST` | IP address of the Music Assistant server |
| `PLAYER_TYPE` | `snapcast` (default) or `airplay` |
| `ROOM_NAME` | Used for the hostname (`snapplayer-<room>`) and MA player name |
| `AUDIO_DEVICE` | ALSA device string, or `auto` to detect the first non-built-in card |
| `SNAPCLIENT_LATENCY` | Latency offset in ms (snapcast only; see [Latency tuning](#latency-tuning)) |
| `WIFI_MODE` | `builtin` (default), `usb`, or `none` |
| `NTP_SERVER` | `gateway` (default), an IP/hostname, or `default` |
| `TIMESYNC_WAIT` | Seconds the player waits for clock sync (default `45`, `0` disables) |
| `HAT_OVERLAY` | Optional audio HAT; adds `dtoverlay` to `config.txt` |

See `player.env.example` for a fully annotated example.

---

## Player types

### Snapcast (`PLAYER_TYPE=snapcast`)

Runs `snapclient` pointing at Music Assistant's built-in Snapcast server.
Synchronized multi-room audio across all Snapcast players.

### AirPlay (`PLAYER_TYPE=airplay`)

Runs `shairport-sync`, making the Pi appear as an AirPlay device in Music
Assistant. Useful for rooms where sync with other players is not needed.

---

## Multi-output mode

A single Pi connected to a USB hub with multiple identical DACs can serve
multiple rooms independently.

Each output is defined by a room name and the USB port it's physically plugged
into. The provisioner:

- Writes udev rules to rename ALSA card IDs by USB port (`room_<slug>`)
- Creates a separate `snapclient-<room>.service` for each output

```
MULTI_OUTPUT=true
USB_VENDOR_ID=0d8c
USB_PRODUCT_ID=0008
OUTPUT_1_ROOM="kitchen"
OUTPUT_1_USB_PORT=1-1.2
OUTPUT_2_ROOM="garage"
OUTPUT_2_USB_PORT=1-1.3
```

The `patch-userdata.py` prompts for room/port pairs interactively. Leave
the room name blank to finish entering outputs.

To find USB port paths, run `lsusb -t` or `udevadm info` on the Pi.

---

## Latency tuning

Snapcast synchronizes audio across players by having each client report a
latency offset to the server. Different hardware introduces different delays:
I2S HATs reach the speaker faster than USB DACs, and WiFi jitter varies by
room.

### Finding the right value

1. Provision all players with `SNAPCLIENT_LATENCY=0` (the default).
2. Add them to a sync group in Music Assistant and play music.
3. Walk between rooms and listen for offset.
4. Tune in real time via JSON-RPC while music is playing:

```bash
# List clients and their current latency
curl http://192.168.3.42:1780/jsonrpc \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}'

# Adjust latency for a specific client (use the MAC from GetStatus)
curl http://192.168.3.42:1780/jsonrpc -d '{
  "id":1,"jsonrpc":"2.0",
  "method":"Client.SetLatency",
  "params":{"id":"<client-mac>","latency":-20}
}'
```

5. Once you have the right value, re-run `patch-userdata.py` on the card,
   enter the latency, re-flash, and it's permanent.

**Known good values:**

| Hardware | Typical offset |
|----------|---------------|
| Merus Audio I2S amp | `-20 ms` |
| C-Media USB DAC | `0 ms` (reference) |

Negative values play *earlier* — use them for hardware that is natively faster
to the speaker than your reference device.

---

## WiFi modes

| Mode | Description |
|------|-------------|
| `builtin` | Built-in `wlan0` (default). Installs a NM dispatcher for automatic reconnection. |
| `usb` | USB adapter on `wlan1`. Binds the WiFi profile to `wlan1`, sets `wlan0` as unmanaged. Requires the adapter to be plugged in before first boot. |
| `none` | WiFi disabled entirely (ethernet only). `rfkill` for the current boot, plus `dtoverlay=disable-wifi` in `config.txt` so it persists. |

All modes install NetworkManager config for infinite reconnection retries and
disable WiFi power save globally (`wifi.powersave=2` in a `conf.d` drop-in).
Power save is set globally rather than per-connection because these profiles are
regenerated into `/run` by netplan on every boot, so a `nmcli connection modify`
setting does not reliably survive.

`builtin` and `usb` also install the network watchdog described below.

> **Prefer `builtin` unless you have a specific reason not to.** Cheap USB
> adapters based on the MT7601U chipset are common and unreliable: clone units
> ship with an invalid EEPROM, which the `mt7601u` driver reports as a kernel
> `WARNING` in `s6_validate` at probe time and which leaves the radio running on
> garbage TX-power calibration. They wedge at the firmware level after hours or
> days, and no amount of NetworkManager retrying will recover them. A giveaway is
> a MAC address whose OUI is unregistered with the IEEE. Both the onboard Pi 3
> radio and the MT7601U are 2.4 GHz-only, so the dongle buys no extra capability.

### Network watchdog

NetworkManager's retry logic only helps when the radio still answers. When WiFi
firmware wedges, the interface can stay nominally associated while passing no
traffic — NM never emits a `down` event, and the player is dead until someone
power-cycles it.

`player-netwatch.service` pings the default gateway every 30 s and escalates:

| Consecutive failures | Elapsed | Action |
|---|---|---|
| 1 | 30 s | Capture a journal excerpt to the boot partition |
| 2 | 1 min | Bounce the NetworkManager connection |
| 6 | 3 min | Reload the WiFi driver module |
| 12 | 6 min | Reboot |

Tunable in `/etc/default/player-net`.

---

## Clock and time sync

The Pi has no RTC, so its clock is wrong from boot until NTP lands — and
Snapcast schedules every audio chunk against a server-relative timestamp. If the
clock steps while a player is running, its time sync breaks and playback stops,
*while the control connection stays up*, so the player still appears healthy in
Music Assistant with the volume responding. On one boot here Debian's pool timed
out and sync only arrived 24 minutes later.

Two independent settings, both in `player.env`:

| Key | Default | Effect |
|-----|---------|--------|
| `NTP_SERVER` | `gateway` | `gateway` auto-detects the default route (your router). Or an IP/hostname, or `default` to leave Debian's pool alone. |
| `TIMESYNC_WAIT` | `45` | Seconds the player waits for a synchronised clock before starting. `0` disables. |

`NTP_SERVER` writes a `timesyncd.conf.d` drop-in and **always keeps the Debian
pool as `FallbackNTP`** — a single LAN server is a single point of failure, and
timesyncd switches over automatically if it stops answering. A router typically
replies in tens of milliseconds rather than seconds, so sync lands almost
immediately at boot.

`TIMESYNC_WAIT` installs an `ExecStartPre` on the player unit only. It is
**deliberately not** implemented by enabling `systemd-time-wait-sync.service`:
that unit is `TimeoutStartSec=infinity` and gates `time-sync.target`, which also
orders `cloud-final.service` — the stage that runs `provision.sh` — plus several
maintenance timers. On a network that cannot reach NTP, enabling it means
provisioning never finishes and the player never starts, with no timeout to
recover. The `ExecStartPre` is bounded and always exits 0, so a dead NTP server
delays the player instead of silencing it, and nothing else boots any slower.

---

## Audio HAT support

Pass a HAT name when prompted. The patching script writes the appropriate
`dtoverlay` to `config.txt` and disables the built-in audio if required.

| Name | Overlay | Disables onboard audio |
|------|---------|----------------------|
| `merus-amp` | `merus-amp` | Yes |
| `hifiberry-amp` | `hifiberry-amp` | Yes |
| `hifiberry-dac` | `hifiberry-dac` | Yes |
| `hifiberry-dacplus` | `hifiberry-dacplus` | Yes |
| `none` | — | No |

`provision.sh` also runs HAT-specific tuning at provisioning time. Currently
implemented: Merus Audio amp limiter bypass (prevents clipping at high volumes).

---

## What provision.sh does

Runs once on first boot via cloud-init `runcmd`, then the filesystem is locked
read-only via `raspi-config overlayfs`. Steps in order:

1. **Audio routing** — writes `/etc/default/snapclient` (single-output) or
   per-room systemd service files (multi-output), or `shairport-sync.conf`
   (AirPlay).
2. **ALSA volume** — sets all mixer controls to 100%, runs HAT-specific tuning,
   saves state to `asound.state` on the boot partition.
3. **ALSA restore service** — installs `alsa-restore-boot.service` to replay
   the saved state on every subsequent boot (before snapclient starts).
4. **Network** — applies WiFi mode config, NM reconnection dispatcher, global
   power-save-off drop-in, and the network watchdog.
5. **Clock persistence** — installs save/restore units that keep the system
   clock on the boot partition. The Pi has no RTC and the overlay reverts
   `fake-hwclock`, so without this every boot starts at the date the card was
   imaged until NTP catches up, misdating all early-boot log lines.
6. **Startup chime** — installs a one-shot service that plays three ascending
   tones on the first post-provisioning boot, confirming audio is working.
7. **Journald** — sets `Storage=volatile` so logs go to RAM, not the SD card.
8. **Passwordless sudo** — for the provisioned user.
9. **Version stamp** — writes `/etc/provisioner-version` and
   `provisioner-version` on the boot partition.
10. **Overlay FS** — enables read-only root filesystem via `raspi-config`.

If any step fails the script aborts **before** enabling the overlay, so the card
stays writable, and writes `provision-failed.txt` to the boot partition with the
failing line number and the last 200 log lines.

---

## Diagnosing a player that fell off the network

The root filesystem is a RAM overlay and journald is volatile, so **a reboot
destroys all evidence of why the reboot was needed**. Three things on the boot
partition survive — read them before power-cycling anything:

| File | Contents |
|------|----------|
| `netlog.txt` | Watchdog events and a journal excerpt captured at the moment each fault was detected. Size-capped at 256 KB. |
| `provisioner-version` | Which revision built this card, plus the resolved config: room, MA host, WiFi mode, HAT overlay, audio device, latency, and the sound cards that actually enumerated. Answers "what is in this box?" without inferring it from a kernel module list. Also at `/etc/provisioner-version`. |
| `provision-failed.txt` | Present only if provisioning itself failed. |

Useful checks on a running player:

```bash
cat /etc/provisioner-version            # which revision built this card?
sudo tail -50 /boot/firmware/netlog.txt # what did the watchdog see?
systemctl status player-netwatch        # is the watchdog running?
dmesg | grep -iE 'wlan|WARNING'         # driver complaints at probe time
cat /proc/net/wireless                  # signal level and discarded packets
```

Note that timestamps from before NTP sync will read as the date the card was
imaged unless `player-clock-restore.service` ran.

---

## Re-provisioning

The patching script is idempotent. To update a card:

1. Mount the boot partition on your Mac/PC.
2. Re-run `patch-userdata.py /Volumes/bootfs`.
3. Existing values are pre-filled; change only what you need.
4. The script re-embeds the current `provision.sh` from disk automatically.

### SSH host keys

Each player gets a **pinned** ed25519 host key. It is generated the first time
that player's card is prepared, archived to `players/<hostname>.hostkey`, and
injected into `user-data` so cloud-init installs it at first boot. Re-imaging
reproduces the same identity, so `ssh` never reports a changed host key.

ed25519 ends up the only host identity, but not via `ssh_genkeytypes` — that
setting does **not** work here. cloud-init consults it, and `ssh_deletekeys`,
only on the branch where it generates keys itself; supplying `ssh_keys` skips
that branch entirely. Raspberry Pi OS has already run `ssh-keygen -A` by then,
so RSA and ECDSA keys exist and are fresh per image. `provision.sh` prunes them
in `prune_unpinned_host_keys()`, leaving only the pinned key. Without that step
a client that had recorded the RSA or ECDSA key would still see a changed
identity on the next reflash — the exact thing pinning is meant to prevent.

Ordering works out because `regenerate_ssh_host_keys.service` is
`ConditionFirstBoot=yes` and runs at `sysinit`, so cloud-init's `cc_ssh` stage
lands after it and wins. The pinned key is then baked into the image before the
overlay is enabled.

**The `players/` directory now holds private keys.** It is gitignored, but
treat it as secret material and include it in whatever you back up — losing it
means the next reflash of that player mints a new identity. This is not a new
class of exposure for the card itself: the boot partition already carries your
WiFi PSK in both `user-data` and `network-config`. The real tradeoff is
deliberate key *reuse*, so a leaked key stays valid across future rebuilds. If
that matters more than convenience, use an SSH certificate authority instead.

Prefer connecting by mDNS name rather than IP — `ssh snapplayer-<room>.local` —
so a DHCP reassignment does not look like a new host.

To adopt a player built **before** this existed, import its current key rather
than letting the next reflash change it:

```bash
ssh <host> "sudo cat /etc/ssh/ssh_host_ed25519_key"     > players/<hostname>.hostkey
ssh <host> "sudo cat /etc/ssh/ssh_host_ed25519_key.pub" > players/<hostname>.hostkey.pub
chmod 600 players/<hostname>.hostkey
```

### After re-imaging a card

Writing a fresh image with Raspberry Pi Imager rewrites the boot partition, so
`player.env` and everything else the provisioner put there is gone — there is
nothing left on the card to pre-fill from.

Every run therefore archives the finished config to `players/<hostname>.env` on
the machine running the script. When a card has no `player.env`, you are offered
the list of previously prepared players and can seed all prompts from one of
them. The directory is gitignored.

To change config on an already-booted Pi: disable overlay FS, edit
`/boot/firmware/player.env` and `/etc/default/snapclient` (or the relevant
service file), re-enable overlay FS, reboot.

---

## Files

```
patch-userdata.py     — Run on Mac/PC to prepare the SD card
provision.sh          — Runs on the Pi at first boot (embedded into user-data)
player.env.example    — Annotated example of all player.env keys
players/              — Per-player archive: config for seeding after a re-image,
                        plus the pinned SSH host key. Gitignored, created on
                        first run. Contains private keys — back it up.
```
