#!/bin/bash
# Build and install the out-of-tree camera modules for the RUNNING kernel.
# Run from anywhere: sudo bash scripts/install.sh
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../src" && pwd)"
KVER=$(uname -r)
UPD=/usr/lib/modules/$KVER/updates

[ "$EUID" -eq 0 ] || { echo "Run with sudo."; exit 1; }

make -C "/usr/lib/modules/$KVER/build" M="$SRC" modules
mkdir -p "$UPD"
cp "$SRC/imx471.ko" "$SRC/ipu-bridge.ko" "$UPD/"
depmod -a "$KVER"
echo "Modules installed in $UPD"
echo -n "modules.alias for TBE20A0: "
grep -i tbe20a0 "/usr/lib/modules/$KVER/modules.alias" || echo "(WARNING: TBE20A0 alias missing)"
echo ">>> Reboot to activate (ipu-bridge is in use and needs a fresh boot)."
