# Wine `ws2_32` Local-Network redirect patch (Phase 2)

Redirects RaceStudio 3's WiFi sockets so RS3-under-Wine only ever talks to `127.0.0.1`
(outside the macOS Local Network gate — proven by Phase 1.5), and the root `aim-bridge`
daemon relays loopback ↔ the real dash. This is the **only** viable in-Wine redirect:
DYLD interpose (Rosetta) and a ws2_32 proxy/hook DLL (no Wine `AppInit_DLLs`) are both
ruled out — see project CLAUDE.md "Don't retry" and the spike reproducers under `../test/`.

## Why the PE `ws2_32.dll` (not a `.so` swap)

In Wine 11.9 the host `connect()`/`sendto()` syscalls live in `ntdll.so` (sockets go through
the afd device), not in `ws2_32.so`. But the **authoritative, clean** rewrite point is the
public `ws2_32.dll` PE entry points, where the destination is still a plain `struct sockaddr`
before it's marshaled to afd. So we patch and rebuild only `ws2_32.dll` (PE) and swap it into
the prebuilt bundle.

## The patch (≈20 lines in `dlls/ws2_32/socket.c`)

A helper, applied at the top of each address-taking entry point:

```c
/* AiM WiFi loopback redirect: AP-mode dash is 10.0.0.0/28; the macOS Local Network gate
 * drops it for the Wine guest, so send it to 127.0.0.1 where the root aim-bridge relays. */
static const struct sockaddr *aim_loopback_redirect(const struct sockaddr *addr, int len,
                                                    struct sockaddr_in *tmp)
{
    if (addr && len >= (int)sizeof(struct sockaddr_in) && addr->sa_family == AF_INET)
    {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        if ((ntohl(in->sin_addr.s_addr) & 0xfffffff0) == 0x0a000000) /* 10.0.0.0/28 */
        {
            *tmp = *in;
            tmp->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            return (const struct sockaddr *)tmp;
        }
    }
    return addr;
}
```

Call sites (each: `struct sockaddr_in _aim_tmp; addr = aim_loopback_redirect(addr, len, &_aim_tmp);`):
- `connect()`        (~L1370, param `addr`)
- `WSAConnect()`     (~L1412, param `name`)
- `sendto()`         (~L3285, param `to`)
- `WSASendTo()`      (~L3269, the destination param)
- `WSASendMsg()`     (~L1205, `msg->name`)

Scope guard: ONLY 10.0.0.0/28 is rewritten, so RS3's other traffic (license/update to public
IPs) is untouched. v1 is AP-mode only (see plan scope).

## Build (just the one DLL)

```bash
brew install mingw-w64 bison flex
curl -LO https://dl.winehq.org/wine/source/11.x/wine-11.9.tar.xz   # match WINE_PINNED_VER
tar xf wine-11.9.tar.xz && cd wine-11.9
# apply the socket.c patch
./configure --enable-archs=i386,x86_64        # finds clang PE cross + mingw CRT
make __tooldeps__                              # winebuild, widl, crt import libs
make dlls/ws2_32/ws2_32.dll                    # build just ws2_32 (both arch dirs)
# swap into a copy of the bundle: lib/wine/{x86_64,i386}-windows/ws2_32.dll
```

Then verify with the existing harness: run `aim-bridge` + the keepalive dash on loopback,
launch `loopback_probe.exe 10.0.0.1 ...` under the patched Wine, confirm bytes land on the
`127.0.0.1` listener (the rewrite fired) and the keepalive-gated transfer survives.

## Status: PROVEN (2026-06-07)

Built the patched `ws2_32.dll` (PE x86-64) from wine-11.9 source, swapped it into the prebuilt
Gcenx staging bundle, and ran `loopback_probe.exe 10.0.0.1 ...` under the patched Wine with a
native listener on `127.0.0.1`: both TCP and UDP arrived (`GOT TCP:WS2PATCH` / `GOT UDP:WS2PATCH`).
So the rewrite fires for `connect()` and `sendto()`, and a vanilla-built DLL is ABI-compatible
with the staging bundle. Reproduce with `build-ws2_32.sh`.

## CI integration — built from source in the runner

`release-dmg.yml` builds the patched `ws2_32.dll` from Wine source on the macOS runner
(`brew install mingw-w64 bison flex` → `build-ws2_32.sh "$WINE_VER"`) and `build-apps.sh`
step 1e swaps it into the bundle before signing. **No patched binary is committed** — it
always tracks `WINE_PINNED_VER` (resolved once in the workflow and used for the bundle fetch,
the cache key, and this build, so they can't drift to different Wine versions). The rejected
alternative (commit the prebuilt DLL) would have meant a binary blob to rebuild and re-commit
on every Wine bump.

ABI note: a vanilla-built `ws2_32.dll` swapped into the Gcenx **staging** bundle of the same
version is compatible (ws2_32 PE ABI is stable within a Wine version) — verified for 11.9.
