# Follow-ups

Ideas considered and deliberately deferred, plus known gaps. Each entry records
enough context to pick it up later without re-deriving the reasoning.

---

## Boot-time self-reprovisioning

**Status:** deferred — design agreed, not built.

Detect on boot that `player.env` has changed since the last provisioning run and
re-provision locally, without needing `reprovision.sh` from another machine.

Hash `player.env` at provisioning time and store the hash on the boot partition.
On each boot, compare. The overlay is the obstacle — `provision.sh`'s writes go
to a RAM overlay unless it is off — so it takes three boots:

```
boot 1   hash differs → raspi-config nonint disable_overlayfs, reboot
boot 2   overlay off  → run provision.sh (writes new hash, re-enables overlay), reboot
boot 3   hash matches → nothing to do
```

**Why it was deferred.** The failure mode is a boot loop on a headless speaker:
if `provision.sh` fails at boot 2 the hash never updates, so boot 3 starts over.
Survivable with an attempt counter on the boot partition and a hard cap, but a
bedroom device rebooting every few minutes until someone unplugs it is worse
than the outage that motivated all this work.

The value is also narrower than it appears. Where SSH is available,
`reprovision.sh` already does the job with visible output and real error
handling. Self-provisioning only wins for the pull-the-card-and-edit-it
workflow.

**If built:** gate behind `AUTO_REPROVISION=true` in `player.env`, default off,
with a 2-attempt cap that gives up and leaves a marker file rather than looping.

**Cheaper 80% variant:** detect and report, don't act. On boot, if the hash
differs, log it loudly and write a marker to the boot partition, so you know the
card is out of sync and can run `reprovision.sh`. ~15 lines, no new failure
modes.

---

## Filesystem snapshot / rollback

**Status:** rejected in favour of `reset_stale_config`, but one gap remains.

The original idea was to snapshot the filesystem before initial provisioning and
roll back to it before each re-run. Rejected because:

- **btrfs/LVM** need non-stock partitioning; RPi OS is ext4 with
  `rootfstype=ext4` in `cmdline.txt`.
- **A persistent overlay upper layer** would make rollback trivial, but
  `raspi-config`'s overlay is tmpfs-only and making writes persist inverts the
  point of having it.
- **Tarring `/etc`** works for capture, but rolling back means *deleting* files
  created since — and getting that scope right is the whole risk. Too tight and
  stale files survive; too broad and you revert things apt legitimately changed.

`reset_stale_config` gets the same benefit with a blast radius of exactly the
files we author.

**The remaining gap:** convergence only handles things we can enumerate. A true
snapshot would also capture non-file state for free — unit enablement, `nmcli`
changes, apt state. We handle unit enablement explicitly, but the manifest can
drift out of sync as features are added, and a snapshot could not. Worth
revisiting if the manifest is ever found stale in practice.

---

## Music Assistant reassigns clients to a standalone group

**Status:** observed twice, cause unconfirmed, possibly an upstream MA bug.

After a power-cycle and again after a `systemctl restart snapclient`, the
bedroom player ended up alone in its own Snapcast group pointed at the idle
`default` stream, while the other players stayed in the playing sync group. The
player looks completely healthy — connected, unmuted, volume responsive — and is
simply never sent audio.

Re-adding it in the MA UI fixes it.

**Next time it happens, capture the server state BEFORE touching the player** —
this is read-only and would have identified it in seconds:

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
  http://<MA_HOST>:1780/jsonrpc | python3 -m json.tool | grep -E 'stream_id|status|name'
```

A restart of the client destroys the evidence, so diagnose first. If the pattern
holds — reconnect leads to a standalone group on the idle stream — it is an MA
reconciliation bug worth reporting upstream. Nothing the provisioner can fix.

---

## Faster flashing / slimmer base image

**Status:** investigated, no good option found.

There is no drop-in slimmer base. The provisioner is built on cloud-init
(`user-data`, `bootcmd`, `runcmd`, `write_files`, `ssh_keys`, `power_state`),
plus `raspi-config`'s overlayfs helper and NetworkManager/netplan. DietPi and
Alpine are far smaller but have no cloud-init; Ubuntu Server has cloud-init but
ships a bigger image.

Flash time is set by the uncompressed image written to the card (~2.7 GB for
RPi OS Lite 64-bit), not by what ends up installed, so trimming packages after
the fact does not help.

**The one real option:** build a shrunk golden image — provision once,
`cloud-init clean --logs --seed`, shrink the root partition to what is actually
used, capture that. A card in use reports ~2.1 GB used against a ~2.7 GB stock
image, so perhaps a 30–40% reduction in bytes written. Real work, worthwhile
only if imaging many players.

Largely obsoleted by `reprovision.sh`, which avoids the write entirely for
anything `provision.sh` controls.

**Observed waste on a Pi 3B**, if a slim step is ever wanted (gate it on
`WIFI_MODE`, since removing `firmware-mediatek` breaks `WIFI_MODE=usb`, and
dropping the 2712 kernel means the card can never move to a Pi 5):

| | |
|---|---|
| `linux-image-*-rpi-2712` | a Pi 5 kernel, on a Pi 3B |
| `firmware-atheros` + `firmware-mediatek` | 140 MB for radios not present |
| `gcc-14` + `g++-14` + `cpp-14` + `linux-headers` | ~172 MB of toolchain |
| `/var/cache/apt` | 146 MB, never cleaned after our own `apt-get update` |

---

## Diagnosing a WiFi player: distinguishing signatures

Four different causes produced or could produce the same user-visible symptom —
"the player dropped off and never came back". They are distinguishable, and
`netlog.txt` captures the counters needed to tell them apart, because it records
`/proc/net/wireless` and the interface state at the moment a fault is detected.

| Cause | Signature |
|---|---|
| **Wedged radio firmware** (the MT7601U failure) | Nominally associated but passing nothing; `misc`/discard counters climbing; kernel warnings at probe. Only a driver reload or power cycle recovers it. |
| **Power save** | Drops after *idle* periods, retry counts near zero. `brcmf_cfg80211_set_power_mgmt: power save enabled` in dmesg with no matching `disabled` line afterwards. |
| **RF interference** (e.g. a class-D amp HAT near the antenna) | Correlates with *playback*, not idle. Rising `retry` and `missed beacon` while audio runs. |
| **Upstream / mesh backhaul** | Interface UP, still associated, strong signal, zero retries — but the gateway is unreachable. Nothing is wrong locally. |

The last two have opposite correlations (playback vs idle), which is the
cheapest discriminator available.

Baseline for comparison, measured on the bedroom player on onboard `wlan0`
while the amp was actively driving audio: **-29 dBm, retry 0, missed beacon 0,
all discards 0**. The MT7601U dongle by contrast accumulated 110 discards while
close to idle.

### Deferred: teach the watchdog to tell local from upstream

`player-netwatch` decides everything from one test — can it ping the default
gateway. An upstream outage (mesh backhaul down, router rebooting) is therefore
indistinguishable from a dead radio, and the watchdog escalates through
reconnect → driver reload → reboot, none of which can help. The self-reboot cap
bounds it at three, so it is noisy rather than dangerous.

Fix: a second target. Add `WATCHDOG_PEER` to `player.env` — typically the AP's
own IP:

- gateway unreachable, **peer reachable** → upstream problem; log and keep
  watching, do not reload the driver or reboot
- **neither** reachable → local problem; escalate as now

~20 lines. Worth building if the UniFi controller history shows the mesh uplink
actually flapping; otherwise it is machinery for a hypothetical.

---

## Network watchdog recovery is unexercised

**Status:** known gap.

`player-netwatch` has verified detection, escalation ordering, logging, and the
self-reboot cap — but nothing has ever made a radio genuinely wedge, so the
recovery path itself (driver reload, USB rebind) has never run in anger. The
onboard `brcmfmac` may simply never need it.

`sudo ip link set wlan0 down` on a physically reachable player exercises the
reconnect rung, but not the driver reload.

---

## Operational reminders

- **`players/` holds private SSH host keys.** Gitignored, so it exists only on
  the machine that images cards. Losing it means the next reflash of a player
  mints a new host identity. It needs to be in whatever gets backed up.
- **All other players are on ethernet.** Only the bedroom player is wireless —
  and it is the only one that has ever failed. Keep that correlation in mind
  before blaming the Pi. If a wired player is ever moved to WiFi, import its
  current host key into `players/<hostname>.hostkey` first, or its identity
  changes once.
- **Changing `WIFI_MODE` changes the MAC**, and therefore the Snapcast client
  ID, and therefore requires re-associating the player in Music Assistant.
