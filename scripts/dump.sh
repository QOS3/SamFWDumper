#!/bin/bash
set -e

echo "═══════════════════════════════════════"
echo "   Professional Firmware Extractor"
echo "═══════════════════════════════════════"

URL="$1"
[ -z "$URL" ] && { echo "❌ No URL"; exit 1; }

chmod +x bin/lp/* bin/ext4/* bin/erofs-utils/* bin/py_scripts/* 2>/dev/null || true

echo ""; echo "[1/6] Downloading..."
wget --no-check-certificate -O "firmware.zip" "$URL" 2>&1 | tail -3
[ ! -f "firmware.zip" ] && { echo "❌ Download failed"; exit 1; }
FILESIZE=$(stat -c%s "firmware.zip")
[ "$FILESIZE" -eq 0 ] && { echo "❌ Empty file"; exit 1; }
echo "✅ Downloaded: $(numfmt --to=iec $FILESIZE)"

echo ""; echo "[2/6] Extracting ZIP..."
unzip -o "firmware.zip" >/dev/null 2>&1
rm -f "firmware.zip"
echo "✅ Done"

echo ""; echo "[3/6] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP not found"; exit 1; }
tar -xf "$AP_FILE" >/dev/null 2>&1
rm -f "$AP_FILE"
echo "✅ Done"

echo ""; echo "[4/6] Processing partitions..."
mkdir -p processed

# Process individual partitions
echo "  Processing individual partitions..."
for PART in boot init_boot vbmeta vendor_boot; do
  FILE=$(find . -maxdepth 1 -name "${PART}.img*" | head -n 1)
  [ -z "$FILE" ] && continue
  
  echo "    Found: $PART"
  [[ "$FILE" == *.lz4 ]] && { lz4 -d "$FILE" "${FILE%.lz4}" 2>/dev/null; FILE="${FILE%.lz4}"; }
  file "$FILE" 2>/dev/null | grep -q "sparse" && { simg2img "$FILE" "${FILE}.raw" 2>/dev/null; [ -f "${FILE}.raw" ] && mv "${FILE}.raw" "$FILE"; }
  xz -9 -T0 "$FILE" 2>/dev/null && mv "${FILE}.xz" "processed/${PART}.img.xz" || cp "$FILE" "processed/${PART}.img"
done

# Extract super.img
SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" | head -n 1)
if [ -n "$SUPER_FILE" ] && [ -f "$SUPER_FILE" ]; then
  echo ""; echo "  Extracting super.img..."
  
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    echo "    Decompressing LZ4..."
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || { echo "    ❌ LZ4 failed"; exit 1; }
    SUPER_FILE="super.img"
  fi
  
  echo "    Size: $(du -h "$SUPER_FILE" | cut -f1)"
  mkdir -p super_dump
  
  echo "    Trying lpunpack..."
  [ -f "bin/lp/lpunpack" ] && bin/lp/lpunpack "$SUPER_FILE" super_dump 2>/dev/null || echo "      ⚠️ lpunpack failed"
  
  if [ $(ls super_dump/ 2>/dev/null | wc -l) -eq 0 ] && [ -f "bin/py_scripts/imgextractor.py" ]; then
    echo "    Trying Python extractor..."
    python3 bin/py_scripts/imgextractor.py "$SUPER_FILE" super_dump 2>/dev/null || echo "      ⚠️ Python failed"
  fi
  
  echo "    Checking extracted files..."
  for PART in system system_ext product vendor vendor_boot vendor_dlkm system_dlkm; do
    if [ -f "super_dump/${PART}.img" ]; then
      mv "super_dump/${PART}.img" "${PART}.img"
      echo "      ✓ Extracted: ${PART}.img"
      xz -9 -T0 "${PART}.img" 2>/dev/null && mv "${PART}.img.xz" "processed/${PART}.img.xz" || mv "${PART}.img" "processed/${PART}.img"
    fi
  done
  rm -rf super_dump
  rm -f super.img
fi

echo ""; echo "[5/6] Results:"; cd processed
FILE_COUNT=$(ls -1 | wc -l)
[ "$FILE_COUNT" -eq 0 ] && { echo "❌ Nothing extracted!"; exit 1; }

echo "═══════════════════════════════════════"
echo "Extracted: $FILE_COUNT partitions"
ls -lh
echo "═══════════════════════════════════════"
echo "✅ Done!"
