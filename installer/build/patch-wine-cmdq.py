#!/usr/bin/env python3
"""Make Cmd-Q quit RaceStudio 3 by patching Wine's native macOS menu.

winemac.drv hard-codes the app menu's Quit item to Command-Option-Q (⌘⌥Q), not the
Mac-standard ⌘Q. The reason is deliberate in stock Wine: AppKit intercepts a menu's
plain ⌘Q before the keystroke reaches the focused window, so a ⌘Q-Quit would stop the
Windows app from ever seeing ⌘Q. RS3 ignores ⌘Q anyway (and we don't need to forward it),
so for a native feel we flip the Quit item to plain ⌘Q.

There is NO registry key / env var for this (setup_options() in macdrv_main.c reads none),
and our menu can't be replaced from outside (Wine's child process owns the menu bar). The
only lever is the compiled Cocoa code in lib/wine/x86_64-unix/winemac.so, which builds the
menu in -[WineApplicationController transformProcessToForeground:].

We change ONE immediate. The Quit item is created with:
    item = [submenu addItemWithTitle:@"Quit …" action:@selector(terminate:) keyEquivalent:@"q"];
    [item setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
NSEventModifierFlagCommand = 1<<20 = 0x100000, NSEventModifierFlagOption = 1<<19 = 0x80000,
so the mask is 0x180000. We rewrite it to 0x100000 (Command only) -> ⌘Q.

In the x86_64 codegen the mask is `movl $0x180000, %edx` (BA 00 00 18 00) right before the
setKeyEquivalentModifierMask: message send. TWO sites use 0x180000 — Quit and "Hide Others"
(⌘⌥H). They are distinguished by the instructions that follow the immediate:
    Quit:        BA 00 00 18 00  48 89 C7  48 8B 35   (mov edx,imm; mov rdi,rax; mov rsi,[rip])
    Hide Others: BA 00 00 18 00  48 89 C7  41 FF D4   (mov edx,imm; mov rdi,rax; call *r12)
We match the Quit sequence exactly and flip the single 0x18 byte to 0x10, leaving Hide
Others alone. AppKit-level ⌘Tab / ⌘M and phase-1's Cmd-as-Ctrl mapping are unaffected
(AppKit fires the menu's terminate: before the key reaches Wine's translation layer).

Strict + fail-loud: requires exactly one Quit site. If Wine's codegen changes on a version
bump the pattern won't match and this exits nonzero, so the build fails red rather than
silently shipping ⌘⌥Q. Idempotent: a no-op if already patched. Re-sign the binary afterwards
(editing the Mach-O invalidates any existing signature).

Usage: patch-wine-cmdq.py <path-to-winemac.so>
"""
import sys

# mov edx, <mask> ; mov rdi, rax ; mov rsi, [rip+disp]  — the Quit setKeyEquivalentModifierMask site.
_TAIL = bytes.fromhex("4889C7488B35")          # mov rdi,rax ; mov rsi,[rip+...]
QUIT_UNPATCHED = bytes.fromhex("BA00001800") + _TAIL   # movl $0x180000, %edx ; ...
QUIT_PATCHED = bytes.fromhex("BA00001000") + _TAIL     # movl $0x100000, %edx ; ...
MASK_BYTE_OFF = 3                               # the 0x18/0x10 byte within the matched run


def count(data: bytes, pat: bytes) -> int:
    n = 0
    i = data.find(pat)
    while i != -1:
        n += 1
        i = data.find(pat, i + 1)
    return n


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-wine-cmdq.py <path-to-winemac.so>")
    path = sys.argv[1]
    data = bytearray(open(path, "rb").read())

    n_un = count(data, QUIT_UNPATCHED)
    n_done = count(data, QUIT_PATCHED)

    if n_un == 0 and n_done >= 1:
        print(f"Cmd-Q already patched in {path}; nothing to do")
        return
    if n_un != 1:
        raise SystemExit(
            f"expected exactly one ⌘⌥Q Quit site in {path}, found {n_un} "
            f"(patched={n_done}). Wine codegen may have changed on a version bump — "
            f"re-derive the byte pattern from a fresh disassembly before shipping."
        )

    i = data.find(QUIT_UNPATCHED)
    assert data[i + MASK_BYTE_OFF] == 0x18, "matched run does not hold the expected 0x18 mask byte"
    data[i + MASK_BYTE_OFF] = 0x10            # NSEventModifierFlagCommand|Option -> Command only
    open(path, "wb").write(data)
    print(f"patched Quit shortcut ⌘⌥Q -> ⌘Q in {path} (offset {hex(i)})")


if __name__ == "__main__":
    main()
