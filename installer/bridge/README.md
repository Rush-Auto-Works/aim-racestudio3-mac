# aim-bridge — WiFi loopback relay (macOS 15+/26 Local Network fix)

## Why this exists

RaceStudio 3 runs under Wine and connects to an AiM dash over WiFi (UDP `aim-ka` discovery
on port 36002, then STCP on TCP port 2000). On **macOS 15 (Sequoia) / 26 (Tahoe)** the
**Local Network privacy gate** silently drops that traffic for the Wine guest. The guest's
socket-owning process is the Wine unix-loader: self-daemonized to PPID=1, not a
LaunchServices app, so macOS can never attribute or prompt for the grant. Declaring
`NSLocalNetworkUsageDescription` is necessary-but-insufficient and was **confirmed not to work
on real hardware** (notarized build, MXS dash, macOS 26).

See project memory `wine-local-network-macos15` and the deep-research write-up for the full
dead-end analysis (NEAppProxy/NEFilter, pf/NAT, MDM/PPPC are all ruled out).

## The architecture (A2: loopback bridge)

Keep RS3 **entirely on loopback** — which is *outside* the gate by construction (lo0 is not a
broadcast-capable interface, so 127.0.0.0/8 is not a "local network address" by Apple's own
definition) — and run a relay to carry the bytes to the real dash:

```
RS3 (Wine) ── 127.0.0.1:2000  (TCP) ──▶ aim-bridge ──▶ DASH:2000     (control + data)
RS3 (Wine) ── 127.0.0.1:36002 (UDP) ──▶ aim-bridge ──▶ DASH:36002    (aim-ka discovery)
```

In production the relay runs as **root** (an `SMAppService` daemon). Root code is exempt from
the gate, so the relay reaches the dash with no prompt and no entitlement. The relay is
**protocol-agnostic** — it forwards bytes, it does not parse STCP/STNC — and it is pinned to
exactly two ports and one dash address, refusing everything else.

The pcap (`promiscuous-slurp/sam cap.pcapng`, real RS3↔MXS) shows RS3 **unicasts** to the
dash's fixed gateway IP — no broadcast/multicast in the connect flow — so a plain unicast
relay is sufficient; no broadcast translation is needed.

## Files

| File | Role |
|------|------|
| `aim-bridge.swift` | The relay (TCP + UDP, pinned, protocol-agnostic; EINTR-safe pump, zero-length-UDP-safe). |
| `build-bridge.sh`  | `swiftc` → `build/aim-bridge`; `SKIP_SIGN=1` / `HARDENED_RUNTIME=1` / `CODESIGN_IDENTITY`. |
| `test-bridge.sh`   | Hermetic round-trip test (fake dash + relay + probe, all on loopback, no sudo). |
| `test-bridge-keepalive.sh` | Realistic test against a keepalive-gated dash: sustained transfer survives while keepalives flow; dash's ~1s TCP close is surfaced through the relay when they stop. |
| `falsify-loopback.sh` | Phase 1.5 gate: proves a Wine guest's loopback traffic escapes the Local Network gate (win32 probe under real Wine + nehelper watch). |
| `test/fake_dash.py`, `test/probe_client.py` | Stand-ins for the simple round-trip test. |
| `test/keepalive_dash.py`, `test/ka_sender.py`, `test/ka_client.py` | Realistic keepalive-gated dash + keepalive sender + transfer probe. |
| `test/loopback_probe.c`, `test/loopback_listener.py` | win32 Winsock probe + native listener for the Phase 1.5 gate. |
| `test/interpose_rewrite.c` | Phase 2 DYLD-interpose spike — RULED OUT (Rosetta blocks DYLD insert); kept as reproducer. |

## Build & test

```bash
bash installer/bridge/build-bridge.sh            # build (signs ad-hoc by default)
bash installer/bridge/test-bridge.sh             # hermetic round-trip test
bash installer/bridge/test-bridge-keepalive.sh   # realistic keepalive-gated transfer test
bash installer/bridge/falsify-loopback.sh        # Phase 1.5 gate (needs zig + bundled Wine; run unsandboxed)
```

## Manual test against a real dash (when hardware is available)

The relay is root-exempt, so run it as root and point a native probe at loopback — no Wine,
no gate involved:

```bash
SKIP_SIGN=1 bash installer/bridge/build-bridge.sh
sudo installer/bridge/build/aim-bridge          # DASH_ADDR defaults to 10.0.0.1
# in another shell, drive the bridge like RS3 would (e.g. promiscuous-slurp aim-probe
# pointed at 127.0.0.1 instead of 10.0.0.1) and confirm session list + download work.
```

## Roadmap

- **Phase 1 — DONE:** the relay + hermetic + realistic-keepalive tests.
- **Phase 1.5 — DONE:** proved a Wine guest's loopback traffic escapes the gate (`falsify-loopback.sh`).
- **Phase 2 — DONE:** RS3 (no connection-IP setting, auto-derives the AP gateway `10.0.0.1`) is
  redirected by a **Wine `ws2_32` source patch** (`wine-patch/`, built in CI, swapped into the
  bundle). DYLD interpose (Rosetta blocks it) and a ws2_32 proxy DLL (Wine has no `AppInit_DLLs`)
  were both ruled out — see `test/interpose_rewrite.c`, `test/appinit_probe.c` and project CLAUDE.md.
- **Phase 3 — DONE:** the relay ships as a root `SMAppService.daemon` (`aim-bridge-ctl` registers
  it; one-time Login Items approval), hardened (root → no env, pinned dest, no `SO_REUSEADDR`),
  with uninstall teardown.
- **Phase 3.5 — DONE:** launcher health-check + Login Items guidance + SD/USB fallback.
- **Phase 4 — REMAINING:** on-device end-to-end on macOS 26 with a real MXS — confirm `nehelper`
  stays silent and the dash appears in RS3 (download + config upload). Needs hardware.

## Security

Root scope is limited to the relay, never all of Wine. Running as root, `aim-bridge` ignores the
environment and hardcodes the permitted destination subnet (`10.0.0.0/28`) and ports
(`36002/UDP`, `2000/TCP`), binds loopback-only, and drops `SO_REUSEADDR` (so a local process
can't pre-bind/steal the port). We chose loopback-bind + hardcoded-dest over peer validation
(there's no XPC peer on a raw socket; the confused-deputy risk is low — a dash holds no secrets
and grants no escalation to the Mac). Uninstall unregisters the daemon (user `aim-bridge-ctl
unregister` + root `launchctl bootout`), so nothing is left bound after removal.
