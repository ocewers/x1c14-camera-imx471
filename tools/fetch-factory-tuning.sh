#!/usr/bin/env bash
# Hämtar Intels fabrikskalibrering (AIQB) för IMX471 på Panther Lake och konverterar den
# till en libcamera Simple-IPA tuning-fil.
#
# Bakgrund: Intel levererar per-modul kalibreringsblobbar (CPFF/AIQB) som innehåller
# svartnivå, AWB-gaingränser, vitpunkts-locus och fulla 3x3-CCM:er per ljuskälla. De är
# betydligt bättre underlag än en handfittad diagonal - men de är kalibrerade PER
# KAMERAMODUL, och samma laptopmodell säljs med olika moduler. Se README ("Factory
# calibration") för hur man avgör vilken modul man har innan man litar på värdena.
#
# Två källor finns:
#   1. Intels egen HAL-repo (den här scriptets väg): config/linux/ipu75xa/*.aiqb -
#      fritt nedladdningsbart, innehåller referensmodulen BBG803N3 för PTL.
#   2. OEM:ens Windows-drivare (Microsoft Update Catalog, sök på ACPI-HID:t) - innehåller
#      de moduler tillverkaren faktiskt bygger in, t.ex. tre olika för TBE20A0. Kräver
#      cabextract (bsdtar klarar inte LZX).
#
# Parsern är Javier Tias, i granskning på libcamera-devel. Den hämtas vid körning i
# stället för att kopieras in här, så att attributionen och licensen (GPL-2.0-or-later)
# stannar hos upphovspersonen och vi inte får en inaktuell kopia i repot.
set -euo pipefail

HAL_RAW=https://raw.githubusercontent.com/intel/ipu7-camera-hal/main/config/linux
PARSER_PATCH=https://patchwork.libcamera.org/patch/26700/mbox/
BLOB=${1:-ipu75xa/IMX471_BBG803N3_PTL.aiqb}
OUT=${2:-./factory-tuning}

# imx471: 64 LSB pedestal i 10-bitarsdomänen, uppmätt med stängd integritetslucka
# (mörkbild: R=Gr=Gb=B=63.96). libcameras 16-bitarskonvention: 64 << 6 = 4096.
BLACK_LEVEL=4096

mkdir -p "$OUT"
cd "$OUT"

echo "== hämtar blobben: $BLOB"
curl -fL --progress-bar "$HAL_RAW/$BLOB" -o "$(basename "$BLOB")"

echo "== hämtar parsern (Javier Tia, libcamera-devel)"
curl -fsL "$PARSER_PATCH" -o parse_aiqb.mbox
python3 - <<'PY'
txt = open('parse_aiqb.mbox', encoding='utf-8', errors='replace').read()
i = txt.index('+++ b/utils/tuning/parse_aiqb.py')
out = []
for line in txt[i:].split('\n')[1:]:
    if line.startswith('@@'):
        continue
    if line.startswith('+'):
        out.append(line[1:])
    elif line.startswith('-- ') or line.startswith('base-commit'):
        break
    else:
        out.append(line[1:] if line.startswith(' ') else '')
open('parse_aiqb.py', 'w').write('\n'.join(out))
PY

echo "== parsar"
python3 parse_aiqb.py "$(basename "$BLOB")" --sensor-name imx471 \
    --black-level "$BLACK_LEVEL" | tee parsed.txt

cat <<'EOF'

Nästa steg:
 - Vitpunkterna (R/G, B/G per CCT) i utskriften ovan är modulens fingeravtryck. Mät din
   egen med tools/measure-raw.sh på ett neutralt mål i DAGSLJUS och jämför - se README.
 - Bara CCM-listan och blackLevel går att använda på libcamera 0.7.2. maxGainR/maxGainB/
   speed kräver master (0.7.2:s Awb har ingen init()), och Adjust-värden i tuning-filen
   ignoreras - ton sätts som libcamerasrc-properties, se configs/ipu7.conf.
 - En full 3x3-matris har negativa off-diagonaler, vilket gör klippta högdagrar magenta
   på den här ISP:n. Jämför mot den diagonala filen i en scen med utbrända partier innan
   du byter.
EOF
