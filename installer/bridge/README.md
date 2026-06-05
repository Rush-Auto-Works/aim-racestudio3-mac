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
| `aim-bridge.swift` | The relay (TCP + UDP, pinned, protocol-agnostic). |
| `build-bridge.sh`  | `swiftc` → `build/aim-bridge`; `SKIP_SIGN=1` / `HARDENED_RUNTIME=1` / `CODESIGN_IDENTITY`. |
| `test-bridge.sh`   | Hermetic round-trip test (fake dash + relay + probe, all on loopback, no sudo). |
| `test/fake_dash.py`, `test/probe_client.py` | Test stand-ins for the dash and for RS3. |

## Build & test

```bash
bash installer/bridge/build-bridge.sh     # build (signs ad-hoc by default)
bash installer/bridge/test-bridge.sh      # hermetic round-trip test
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

- **Phase 1 (done):** the relay + hermetic test (this directory).
- **Phase 2:** make RS3-under-Wine target `127.0.0.1`. RS3 has no connection-IP setting and
  auto-derives the dash IP from the AP gateway (`10.0.0.1`), so we rewrite its socket
  destinations. Preferred: a `DYLD_INSERT_LIBRARIES` interpose dylib wrapping `connect`/`sendto`
  that rewrites `10.0.0.0/28` → `127.0.0.1` (no Wine rebuild; needs
  `com.apple.security.cs.allow-dyld-environment-variables` + `disable-library-validation` on the
  loader's hardened-runtime signature). Fallback: patch the bundled Wine's `ws2_32`/`server/sock.c`.
- **Phase 3:** ship the relay as a root `SMAppService.daemon` inside the app bundle
  (`Contents/Library/LaunchDaemons/`), Developer-ID signed + notarized, one-time **Login Items**
  approval (`SMAppServiceStatusRequiresApproval`). Pin destination/ports; validate the loopback peer.
- **Phase 4:** on-device integration test on macOS 26 with the MXS — confirm `nehelper` stays
  silent (RS3 only ever touches loopback) and the dash appears in RS3.

## Security

Root scope is limited to the relay, never all of Wine. The daemon hardcodes the permitted
destination subnet (`10.0.0.0/28`) and ports (`36002/UDP`, `2000/TCP`) and declines anything
else. Phase 3 adds XPC-peer code-signing validation and an idle watchdog.
