# Sharp GPU video for the lap-compare view (the hard fix)

Status: **investigated, not implemented.** The shipped fix is the software `wingdi`
video output (correct size, stable, but GDI-soft). This doc is the plan for getting
*sharp* GPU-rendered video, and the evidence for why the easy paths don't work — so a
future attempt doesn't re-walk the dead ends.

## What RS3 actually uses

RS3 plays the lap-compare / SmartyCam videos through an **embedded libVLC 3.0.9.2**
(`libvlc.dll` + `libvlccore.dll` + a stripped plugin set in
`drive_c/AIM_SPORT/RaceStudio3/64/`). Wrapper classes `CWndVLCPlayer` / `CDlgVLCMovie`.
Embedded child-window mode (`libvlc_media_player_set_hwnd`). VLC picks a video-output
("vout") module by priority: `direct3d11` (300) > `direct3d9` (280) > `glwin32` (~270) >
`wingdi` (110).

## Root cause of the original "small window" bug

`wined3d` on Apple Silicon (M-series, macOS 26) **cannot create a Direct3D 11 device** on
*either* backend:
- GL backend: fails (`GL_VENDOR "Apple"` unrecognized, `GL_INVALID_FRAMEBUFFER_OPERATION`).
- Vulkan backend (`HKCU\Software\Wine\Direct3D\renderer=vulkan`): fails with
  `wined3d_select_feature_level: None of the requested D3D feature levels is supported on
  this GPU with the current shader backend` (MoltenVK 1.4.1 is ~Vulkan 1.2; the adapter
  enumeration is incomplete in Wine 11.9-staging).

So VLC's best vout (`direct3d11`) never opens, and VLC falls down the chain to vouts that
each break under Wine/winemac:
- **direct3d9**: opens on wined3d's *fake* "NVIDIA GeForce 6800" device. Renders the first
  compare video correctly, but a second player on the shared fake device **shrinks both to
  a small top-left rectangle** (the reported bug). d3d9 vout never resets the device on
  resize (VLC's reset code is `#if 0`'d), so it can't recover.
- **glwin32** (OpenGL): **corrupts** the frame — diagonal shear + the Y/U/V planes shown
  as separate green/red bands. VLC's planar-YUV GL upload (`GL_UNPACK_ROW_LENGTH` /
  `GL_RED` single-channel textures) misbehaves on winemac's Apple-GL context.
- **wingdi** (GDI `StretchBlt`, pure software): **correct size, stable, resizes fine** —
  but software-scaled, so soft/grainy. **This is what we ship** (force it by disabling the
  three GPU vout plugins in the launcher).

## Why DXVK / DXMT do NOT fix it (tested 2026-06-13)

We got **DXVK-macOS async 1.10.3** providing a *real* D3D11 device (FL 11_0) on the M5 Max
— the capability wined3d lacks. Required clearing a `winevulkan` `vkDestroyInstance`
`assert(!status)` abort (binary-patchable). But:

- **VLC's `direct3d11` vout never engages even with a working DXVK device.** Forced to be
  the *only* vout (wingdi disabled), VLC logs `2 candidates → no vout display modules
  matched → video output creation failed` and **DXVK's d3d11/dxgi logs stay 0 bytes**. The
  vout `Open()` fails *before it ever calls into the D3D layer.*
- The most likely cause: VLC 3.0's `direct3d11` vout needs **DirectComposition**
  (`dcomp.dll`) to composite into an embedded child HWND, and Wine stubs `dcomp`.
- **Consequence:** because the vout bails *upstream* of the D3D translation layer, **DXMT
  (D3D11→Metal) would hit the same wall** — it replaces the layer VLC never reaches. DXMT
  is therefore NOT worth its custom-Wine-build cost for this.
- **DXVK d3d9** is a separate dead end: its device creation fails outright
  (`DxvkAdapter: Failed to create device` / `D3DERR_NOTAVAILABLE`) — MoltenVK doesn't
  expose `robustBufferAccess2`/`nullDescriptor`, which DXVK's d3d9 needs (d3d11 tolerates).

Also ruled out: Apple **D3DMetal** (GPTK) — its license forbids redistribution in a free
open-source DMG.

## The actual levers (all require code, none is config)

RS3 calls `libvlc_new` with **no options**, and libVLC **ignores its config file**
(`vlcrc`) by default — verified: an `avcodec-hw=none` vlcrc had no effect. So vout,
colorspace, decode mode, etc. **cannot be injected** from outside. The only runtime lever
is the **plugin set** (which is how the shipped wingdi fix works).

To get *sharp* video, one of:

1. **Make VLC's `direct3d11` vout not need DirectComposition** — rebuild
   `libvlc_direct3d11_plugin` (or libVLC) configured/patched to use the plain DXGI
   flip-model swapchain path on a child HWND instead of dcomp, then pair it with **DXVK**
   (which already gives a working D3D11 device here once the `winevulkan` assert is
   patched). Highest-quality outcome (GPU scaling + correct size + resize). Cost: building
   a Windows libVLC plugin from source against the pinned VLC version, plus shipping
   DXVK + the patched `winevulkan.dll` in the bundle. **Verify first** that the vout
   failure really is dcomp (trace `LoadLibrary("dcomp")` / the exact early-return in
   `direct3d11.c::Open`) before committing.

2. **Implement / unstub Wine `dcomp.dll`** enough for VLC's d3d11 vout — narrower than (1)
   in spirit but `dcomp` is a large API; likely more work than (1).

3. **Fix the `glwin32` planar-YUV upload** under winemac — patch winemac.drv's GL
   pixel-store (`GL_UNPACK_ROW_LENGTH`) handling, or rebuild VLC's `gl` plugin to use a
   packed-RGB upload. `glwin32` already gets sizing right (the thing d3d9 gets wrong), so
   this is the *smallest* GPU win if the corruption is a one-line stride bug — but the root
   (VLC GL code vs winemac GL) is unconfirmed and could need a VLC-plugin rebuild.

## Recommendation

Ship `wingdi` now (done). If sharp video is later deemed worth it, pursue **option 1**, and
**gate it on a cheap up-front check**: confirm (via a VLC `direct3d11.c::Open` trace or a
debug VLC build) that the vout's early bail is the `dcomp` dependency. If it is, a
dcomp-free d3d11 vout + DXVK is the path. If the bail is something else, re-evaluate — do
not start the libVLC rebuild on assumption.

Full evidence and the exact log lines are in agent memory `rs3-video-is-libvlc`.
