#!/bin/bash
# Restore the camera after a kernel or libcamera update.
# - Rebuilds imx471.ko + ipu-bridge.ko for every installed kernel that lacks them
# - Restores the libcamera tuning file if a package update overwrote it
# - Detects when the upstream imx471 driver lands in the kernel (then cleans up)
# Run manually with sudo, or automatically via the pacman hook (see
# x1c14-camera.hook — adjust its Exec path to where this repo is checked out).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../src" && pwd)"
TUNING_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tuning" && pwd)/imx471.yaml"
TUNING_DST=/usr/share/libcamera/ipa/simple/imx471.yaml

[ "$EUID" -eq 0 ] || { echo "Run with sudo: sudo bash $0"; exit 1; }

REBOOT_NEEDED=0

for KDIR in /usr/lib/modules/*/; do
    K=$(basename "$KDIR")
    [ -e "$KDIR/build/Makefile" ] || continue  # no headers for this kernel

    # Does the kernel ship its own imx471? Then the upstream fix has landed.
    if find "$KDIR/kernel" -name 'imx471.ko*' -print -quit 2>/dev/null | grep -q .; then
        echo ">>> $K: kernel now has its OWN imx471 driver — upstream fix has landed! 🎉"
        if [ -f "$KDIR/updates/imx471.ko" ]; then
            echo ">>> Removing out-of-tree modules for $K (kernel's own are used instead)."
            rm -f "$KDIR/updates/imx471.ko" "$KDIR/updates/ipu-bridge.ko"
            depmod -a "$K"
        fi
        continue
    fi

    UPD=$KDIR/updates
    if [ -f "$UPD/imx471.ko" ] && [ "$UPD/imx471.ko" -nt "$SRC/imx471.c" ] \
       && [ -f "$UPD/ipu-bridge.ko" ] && [ "$UPD/ipu-bridge.ko" -nt "$SRC/ipu-bridge.c" ]; then
        echo "$K: modules already in place."
        continue
    fi

    echo "$K: building camera modules..."
    make -C "$KDIR/build" M="$SRC" clean >/dev/null
    make -C "$KDIR/build" M="$SRC" modules
    mkdir -p "$UPD"
    cp "$SRC/imx471.ko" "$SRC/ipu-bridge.ko" "$UPD/"
    depmod -a "$K"
    if grep -qi tbe20a0 "$KDIR/modules.alias"; then
        echo "$K: OK — TBE20A0 → imx471."
        REBOOT_NEEDED=1
    else
        echo "$K: WARNING — TBE20A0 alias missing, something went wrong." >&2
    fi
done

# Tuning file (overwritten by libcamera package updates)
if [ -f "$TUNING_SRC" ] && ! cmp -s "$TUNING_SRC" "$TUNING_DST" 2>/dev/null; then
    cp "$TUNING_SRC" "$TUNING_DST"
    echo "Tuning file restored to $TUNING_DST."
fi

if [ "$REBOOT_NEEDED" -eq 1 ]; then
    echo ">>> Done — reboot to activate the camera."
else
    echo "Done — nothing to do."
fi
