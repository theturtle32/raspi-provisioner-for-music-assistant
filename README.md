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
2. Install the required packages (`snapclient` or `shairport-sync`, `alsa-utils`,
   `overlayroot`, etc.)
3. Run `provision.sh`
4. Reboot

After the final reboot (~90 seconds total), the player appears in Music
Assistant.

Steps 2 and 3 print to the screen as they run, so a monitor on the HDMI port shows
what first boot is doing rather than a static banner. The same output goes to
`/var/log/cloud-init-output.log`, which can be followed over SSH once the Pi is on
the network:

```bash
ssh <user>@snapplayer-<room>.local tail -f /var/log/cloud-init-output.log
```

The package install is the long wait. `overlayroot` rebuilds the initramfs for
every installed kernel, which takes most of a minute on a Pi 3B. It is installed
up front so that this happens during step 2. `PROVISIONING COMPLETE — rebooting
now` is the last thing `provision.sh` prints, and cloud-init issues the reboot
within a second or two of it.

---

## Configuration prompts

`patch-userdata.py` asks for these values. Press Enter to keep the value
shown in brackets when re-running against an already-configured card.

| Prompt | Description |
|--------|-------------|
| Output mode | `single` (default), `split` for two mono zones on one card, or `multi` for several USB DACs |
| `MA_HOST` | IP address of the Music Assistant server |
| `PLAYER_TYPE` | `snapcast` (default) or `airplay` |
| `ROOM_NAME` | Used for the hostname (`snapplayer-<room>`) and MA player name |
| `AUDIO_DEVICE` | ALSA device string, or `auto` to detect the first non-built-in card |
| `SNAPCLIENT_LATENCY` | Latency offset in ms (snapcast only; see [Latency tuning](#latency-tuning)) |
| `SNAPCAST_HOST_ID` | Optional; snapcast only. Pins the Snapcast client id so it survives a MAC change — see [Keeping a player's identity](#keeping-a-players-identity) |
| `LEFT_ROOM` / `RIGHT_ROOM` | Split mode only: the player name for each channel. Leave one blank if that channel has nothing wired to it yet |
| `MONO_MIX_GAIN` | Split mode only: gain per half of the mono downmix (default `0.5`) |
| `WIFI_MODE` | `builtin` (default), `usb`, or `none` |
| `NTP_SERVER` | `gateway` (default), an IP/hostname, or `default` |
| `TIMESYNC_WAIT` | Seconds the player waits for clock sync (default `45`, `0` disables) |
| `HAT_OVERLAY` | Optional audio HAT; adds `dtoverlay` to `config.txt` |

See `player.env.example` for a fully annotated example.

---

## Player types

### Snapcast (`PLAYER_TYPE=snapcast`)

Runs `snapclient` pointing at Music Assistant's built-in Snapcast server.
Synchronized multi-room audio across all Snapcast players. Also the only player
type that can serve more than one room from one Pi — see
[channel-split](#channel-split-mode-two-mono-zones-on-one-card) and
[multi-output](#multi-output-mode) modes.

### AirPlay (`PLAYER_TYPE=airplay`)

Runs `shairport-sync`, making the Pi appear as an AirPlay device in Music
Assistant. Useful for rooms where sync with other players is not needed.

---

## Channel-split mode: two mono zones on one card

For two rooms that each have a *single* speaker — a pair of bathrooms with one
in-ceiling speaker each, say — one stereo card can drive both as independently
controllable players. The left amplifier channel feeds one room, the right feeds
the other, and each appears in Music Assistant on its own.

```
CHANNEL_SPLIT=true
ROOM_NAME="bathrooms"            # labels the box; hostname snapplayer-bathrooms
LEFT_ROOM="guest bathroom"       # first channel of the card
RIGHT_ROOM="primary bathroom"    # second channel
MONO_MIX_GAIN=0.5
RIGHT_LATENCY=0                  # per-zone, as with any other player
```

Snapcast only, and mutually exclusive with `MULTI_OUTPUT`; `provision.sh` refuses
both combinations rather than picking one.

### Starting with only one channel wired

Name only the zone that has a speaker on it. Both ALSA devices are still defined,
but only the named zone gets a player, so nothing phantom shows up in Music
Assistant:

```
CHANNEL_SPLIT=true
ROOM_NAME="guest bathroom"
LEFT_ROOM="guest bathroom"       # RIGHT_ROOM omitted until the speaker exists
```

This is a better starting point than single-output mode even with one speaker, for
two reasons. The zone sums both channels to mono, so that speaker hears the whole
mix — a single-output player would send it the left channel alone and lose
whatever is panned right. And the audio path is already final, so the latency
offset you tune now still applies once the second zone arrives; converting from
single-output later would insert the `dmix` buffer and shift it.

Adding the second zone later is one `reprovision.sh` run. Instance numbers belong
to the channel rather than to the order the units are written, so the zone already
in service keeps its Snapcast id and its place in Music Assistant. At the prompts,
leave a zone blank to leave it unconfigured, or enter `-` to clear one that was
configured before.

Before reprovisioning, you can confirm a newly wired speaker from the running
player without changing anything — the device already exists:

```bash
speaker-test -D zone_right -c 2 -t sine -l 1
```

### Each zone hears everything, not half the stereo image

A zone is not "the left channel of the music". Both incoming channels are summed
to mono and sent to one physical output, so nothing panned to one side goes
missing in a room. `MONO_MIX_GAIN` is the gain applied to each half of that sum:

| Value | Effect |
|-------|--------|
| `0.5` (default) | Cannot clip. Costs 6 dB of maximum loudness. |
| `1.0` | 6 dB louder, and clips anything centre-panned — which is most vocals. |

Raise it if a speaker is too quiet with the amp already at full, and listen at
the volume you actually use before keeping it.

### How it works

`provision.sh` writes `/etc/asound.conf` defining three ALSA devices:

| Device | What it is |
|--------|-----------|
| `zone_shared` | A `dmix` that owns the card. An ALSA `hw` device can only be opened once, and two snapclients need it at the same time. |
| `zone_left` | A `route` on top of `zone_shared` summing both incoming channels into physical channel 0. |
| `zone_right` | The same, into physical channel 1. |

Then one `snapclient-<room>.service` per zone, pointed at the matching device.
Rate and buffer are pinned in the `dmix` slave, because `dmix` negotiates those
once — when the first zone opens — and every later zone is stuck with the result.

The file carries a marker line, and provisioning removes it only if it finds that
marker, so an `/etc/asound.conf` you wrote yourself is never touched.

### Which speaker is on which channel

Nothing on the Pi can tell you, so the startup chime does: on the first
post-provisioning boot it plays on each configured zone in channel order, left
first, pausing a second between. Stand where you can hear both and the order tells
you the wiring. A zone with no player configured is skipped rather than chimed
into, so the sequence has no unexplained silences in it.

### Two players, two names

Snapcast identifies a client by MAC address and distinguishes instances on one
host with `--instance`, so the two zones are distinct clients. Their *displayed*
name is another matter: a client reports the system hostname, which is identical
for both, so Music Assistant would list two players called
`snapplayer-bathrooms` and nothing but trial and error would say which room each
one is.

snapclient has no option for the reported name — `--hostID` sets the id, not the
name. So each instance is started inside its own UTS namespace with the room's
name set as the hostname there:

```
ExecStart=/usr/bin/unshare --uts /bin/sh -c 'hostname guest-bathroom && exec /usr/bin/snapclient ...'
```

The Pi's own hostname, and therefore mDNS and SSH, is untouched. This is probed
at provisioning time rather than assumed: if `unshare` is unavailable the units
fall back to a plain `ExecStart` and both players show up under the box's
hostname, to be renamed once in Music Assistant. Multi-output mode gets the same
treatment, for the same reason.

Volume stays independent per zone because snapclient's default mixer is
`software`, so each instance scales its own samples. A `hardware` mixer would
have both zones fighting over the one ALSA control on the shared card.

### Converting an existing single-output player

The left zone is deliberately instance 1, which keeps the bare MAC as its
Snapcast id. A player converted from single-output therefore stays the *same*
client in Music Assistant — same volume, same group membership — and only the
second zone arrives as new. `reprovision.sh` is enough; no re-imaging:

```bash
# players/snapplayer-guest-bathroom.env — keep ROOM_NAME, add the zones
CHANNEL_SPLIT=true
LEFT_ROOM="guest bathroom"
RIGHT_ROOM="primary bathroom"
```

```bash
./reprovision.sh snapplayer-guest-bathroom.local
```

Leave `ROOM_NAME` alone while doing this. It is what the hostname was derived
from, and the hostname is set by cloud-init at image time, so `reprovision.sh`
cannot change it — see
[what it cannot change](#re-provisioning-without-re-imaging). The box keeps the
name of whichever room it was originally built for; the two *players* are named
from `LEFT_ROOM` and `RIGHT_ROOM` regardless.

Expect to want a latency offset relative to your other players: the `dmix` buffer
sits in the path that a single-output player does not have. See
[Latency tuning](#latency-tuning), and set `LEFT_LATENCY` / `RIGHT_LATENCY` —
they are per-zone, though on one card they will normally be equal.

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

A channel-split box needs its own measurement rather than the value for the same
card in single-output mode: its audio goes through a `dmix` buffer that a
single-output player does not have.

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

`builtin` and `usb` also install the network watchdog described below. `none`
does not, and convergence removes it if it was there before: the watchdog decides
everything by pinging the gateway through the WiFi interface, so on a box with no
radio it would fail every check and escalate all the way to rebooting a player
that is perfectly healthy.

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

## Keeping a player's identity

Snapcast identifies a client by MAC address. That is fine until the MAC changes,
which happens whenever a player starts using a different interface — switching
`WIFI_MODE`, or moving a wireless player onto ethernet. On a Pi the onboard
radio and the ethernet port have *different* MACs, so the player arrives in
Music Assistant as a brand-new client. The old one goes stale, and the new one
turns up unnamed, at default volume, in no group.

`SNAPCAST_HOST_ID` pins the id instead, via snapclient's `--hostID`:

```
WIFI_MODE=none
SNAPCAST_HOST_ID=b8:27:eb:d3:3e:b4    # the MAC it had before the change
```

Music Assistant then sees the same client it always had, and keeps its name,
volume, latency and group membership. Find the current id before you change
anything — once the interface is gone, so is the MAC:

```bash
ip -br link | awk '{print $1, $3}'
```

It is not only deliberate changes that move the id. A player with **two live
interfaces** — a wireless box with an ethernet cable also plugged in — has no
stable id at all: snapclient picks one MAC, and which one it picks depends on
interface enumeration that boot. Converting the bedroom player produced exactly
this. In the window between the two reboots, with both `wlan0` and `eth0` up and
the pin not yet written, it registered itself under the *ethernet* MAC and left a
second, disconnected `snapplayer-primary-bedroom` behind in Music Assistant.
Pinning removes the ambiguity regardless of how many interfaces are up.

Leave it unset on new builds; deriving the id from the MAC is the right default
when there is no previous identity to preserve. Under
[channel-split](#channel-split-mode-two-mono-zones-on-one-card) or
[multi-output](#multi-output-mode) one pinned id covers every zone, because
`--instance` still distinguishes them: the first keeps the bare id and later ones
get `id#N`, exactly as they would from a MAC.

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

1. **Dependency preflight** — asserts the packages cloud-init's `runcmd` was
   meant to install actually arrived, and aborts naming any that did not. A
   failed `runcmd` does not stop the ones after it, so without this a failed
   `apt` surfaces much later as `Unit snapclient.service does not exist` — an
   error nowhere near the cause. It only checks; it never installs.
2. **Audio routing** — writes `/etc/default/snapclient` (single-output),
   per-room systemd service files plus `/etc/asound.conf` (channel-split) or
   udev rules (multi-output), or `shairport-sync.conf` (AirPlay).
3. **ALSA volume** — sets all mixer controls to 100%, runs HAT-specific tuning,
   saves state to `asound.state` on the boot partition.
4. **ALSA restore service** — installs `alsa-restore-boot.service` to replay
   the saved state on every subsequent boot (before snapclient starts).
5. **Network** — applies WiFi mode config, NM reconnection dispatcher, global
   power-save-off drop-in, and the network watchdog.
6. **Time sync** — points `timesyncd` at `NTP_SERVER` and installs the
   `TIMESYNC_WAIT` gate on the player unit. See
   [Clock and time sync](#clock-and-time-sync).
7. **Clock persistence** — installs save/restore units that keep the system
   clock on the boot partition. The Pi has no RTC and the overlay reverts
   `fake-hwclock`, so without this every boot starts at the date the card was
   imaged until NTP catches up, misdating all early-boot log lines.
8. **Startup chime** — installs a one-shot service that plays three ascending
   tones on the first post-provisioning boot, confirming audio is working. In
   channel-split mode it plays on each zone in turn, which is what identifies
   the speakers.
9. **Journald** — sets `Storage=volatile` so logs go to RAM, not the SD card.
10. **Passwordless sudo** — for the provisioned user.
11. **Version stamp** — writes `/etc/provisioner-version` and
   `provisioner-version` on the boot partition.
12. **Overlay FS** — enables read-only root filesystem via `raspi-config`.

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

### Re-provisioning without re-imaging

Most `provision.sh` changes do not need a new card. `reprovision.sh` re-runs
provisioning on a live player over SSH:

```bash
./reprovision.sh snapplayer-primary-bedroom.local
```

The only thing standing in the way of an in-place re-run is the RAM overlay,
which discards everything `provision.sh` writes. So the script turns the overlay
off, reboots, runs the current `provision.sh` (which re-enables the overlay as
its last step), and reboots again. Two reboots, a couple of minutes, no card
handling and no ~2.7 GB image write.

It pushes `players/<hostname>.env` if one exists, and always rewrites
`PROVISIONER_VERSION` on the card — otherwise the version stamp would keep
reporting the revision the card was originally imaged with.

`provision.sh` clears its own mode-dependent config before writing new config
(`reset_stale_config`), so a re-run cannot leave behind the artifacts of settings
that are no longer selected. This matters most for `WIFI_MODE`: without it,
switching `usb` → `builtin` would leave both `99-ignore-wlan0.conf` and
`99-ignore-wlan1.conf` in place, marking **both** radios unmanaged and taking the
player off the network with no way back except a console or a reflash. It also
means `TIMESYNC_WAIT=0` and `NTP_SERVER=default` now actually take effect on a
re-run rather than silently leaving the previous settings.

Only paths `provision.sh` authors are cleared. Files it always writes identically
— the sudoers drop-in, the clock units, the chime — are deliberately left alone,
as is operational state on the boot partition (`netlog.txt`, `clock.save`).
`/etc/asound.conf` is a special case, since it is system-wide ALSA config rather
than exclusively ours: it is removed only when it carries the marker line
`provision.sh` writes into the copy it generates for channel-split mode.

**What it cannot change**, because these are applied by `patch-userdata.py` at
image time rather than by `provision.sh`:

- `HAT_OVERLAY` — writes `dtoverlay=` into `config.txt`
- the pinned SSH host key, the hostname, and the cloud-init `user-data`

Changing `WIFI_MODE` *is* possible, and is one of the things `reprovision.sh` is
most useful for. It changes which NIC is used, and therefore the MAC, and
therefore the Snapcast client id — so set `SNAPCAST_HOST_ID` to the MAC the
player has *now*, in the same run, or it arrives in Music Assistant as a new
player. See [Keeping a player's identity](#keeping-a-players-identity), and
[SSH host keys](#ssh-host-keys) for the same caveat applied to host identity.

One ordering note when moving a wireless player to ethernet: run
`reprovision.sh` against the player's **ethernet** address, not its `.local`
name. `WIFI_MODE=none` calls `rfkill block wifi` partway through provisioning,
which would drop an SSH session running over the radio and leave the box
half-provisioned with the overlay off.

If `provision.sh` fails, the script stops and prints `provision-failed.txt`. The
overlay is left **off** and the card writable, which is the right state for
investigating.

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
reprovision.sh        — Re-runs provisioning on a live player over SSH, no re-imaging
FOLLOW-UPS.md         — Deferred ideas and known gaps
player.env.example    — Annotated example of all player.env keys
players/              — Per-player archive: config for seeding after a re-image,
                        plus the pinned SSH host key. Gitignored, created on
                        first run. Contains private keys — back it up.
```
