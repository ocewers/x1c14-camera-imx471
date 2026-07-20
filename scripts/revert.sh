#!/bin/bash
# Remove the out-of-tree camera modules (revert to stock kernel drivers).
set -euo pipefail
KVER=$(uname -r)
rm -f "/usr/lib/modules/$KVER/updates/imx471.ko" \
      "/usr/lib/modules/$KVER/updates/ipu-bridge.ko"
depmod -a "$KVER"
echo "Out-of-tree modules removed. Reboot to return to stock."
