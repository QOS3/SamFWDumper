#!/bin/bash
set -e

echo "═══════════════════════════════════════"
echo "   Samsung Firmware Extractor"
echo "═══════════════════════════════════════"

URL="$1"
[ -z "$URL" ] && { echo "❌ No URL"; exit 1; }

chmod +x bin/lp/* bin/ext4/* bin/erofs-utils/* bin/py_scripts/* 2>/dev/null || true

echo ""; echo "[1/5] Downloading..."
wget --no-check-certificate -O "firmware.zip" "$URL" 2>&1 | tail -3
[ ! -f "firmware.zip" ] && { echo "❌ Download failed"; exit 1; }
FILESIZE=$(stat -c%s "firmware.zip")
[ "$FILESIZE" -eq 0 ] && { echo "❌ Empty file"; exit 1; }
echo "✅ Downloaded: $(numfmt --to=iec $FILESIZE)"

echo ""; echo "[2/5] Extracting ZIP..."
unzip -o "firmware.zip" >/dev/null 2>&1
rm -f "firmware.zip"
echo "✅ Done"

echo ""; echo "[3/5] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" -o -name "AP_*.tar" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP file not found"; exit 1; }
echo "  Extracting: $(basename "$AP_FILE")"
tar -xf "$AP_FILE" >/dev/null 2>&1
rm -f "$AP_FILE"
echo "✅ Done"

echo ""; echo "[4/5] Extracting partitions..."
mkdir -p processed

# Process individual partitions first (boot, vbmeta, etc.)
echo "  Processing individual partitions..."
for PART in boot init_boot vbmeta vendor_boot dtbo; do
  FILE=$(find . -maxdepth 1 -name "${PART}.img.lz4" | head -n 1)
  if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    echo "    ✓ Found: $(basename "$FILE")"
    lz4 -d "$FILE" "${FILE%.lz4}" 2>/dev/null || true
    FILE="${FILE%.lz4}"
    if xz -9 -T0 "$FILE" 2>/dev/null; then
      mv "${FILE}.xz" "processed/${PART}.img.xz"
      echo "      ✓ ${PART}.img.xz"
    else
      cp "$FILE" "processed/${PART}.img"
      echo "      ✓ ${PART}.img"
    fi
  fi
done

# Extract super.img partitions
SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" | head -n 1)
if [ -n "$SUPER_FILE" ] && [ -f "$SUPER_FILE" ]; then
  echo ""; echo "  Extracting super.img..."
  
  # Step 1: Decompress LZ4
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    echo "    Decompressing LZ4..."
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || { echo "    ❌ LZ4 failed"; exit 1; }
    SUPER_FILE="super.img"
  fi
  
  # Step 2: Check if sparse, convert if needed
  if file "$SUPER_FILE" 2>/dev/null | grep -q "sparse"; then
    echo "    Converting sparse image..."
    # Try system simg2img first, then bin version
    if command -v simg2img &>/dev/null; then
      simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null
    elif [ -f "bin/ext4/simg2img" ]; then
      bin/ext4/simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null
    else
      echo "    ⚠️ simg2img not found, trying lpunpack on sparse (may fail)..."
      cp "$SUPER_FILE" "super.raw.img"
    fi
    [ -f "super.raw.img" ] && SUPER_FILE="super.raw.img"
  fi
  
  # Step 3: Extract with lpunpack
  echo "    Extracting dynamic partitions..."
  mkdir -p super_dump
  
  if [ -f "bin/lp/lpunpack" ]; then
    bin/lp/lpunpack "$SUPER_FILE" super_dump 2>/dev/null || echo "      ⚠️ lpunpack failed"
  fi
  
  # Step 4: Move and compress extracted partitions
  echo "    Processing extracted partitions..."
  for PART in system system_ext product vendor vendor_boot vendor_dlkm system_dlkm; do
    if [ -f "super_dump/${PART}.img" ]; then
      echo "      ✓ ${PART}.img"
      if xz -9 -T0 "super_dump/${PART}.img" 2>/dev/null; then
        mv "super_dump/${PART}.img.xz" "processed/${PART}.img.xz"
      else
        mv "super_dump/${PART}.img" "processed/${PART}.img"
      fi
    fi
  done
  
  rm -rf super_dump super.img super.raw.img
else
  echo "  ⚠️ super.img not found"
fi

echo ""; echo "[5/5] Results:"; cd processed
FILE_COUNT=$(ls -1 | wc -l)
[ "$FILE_COUNT" -eq 0 ] && { echo "❌ Nothing extracted!"; exit 1; }

echo "═══════════════════════════════════════"
echo "✅ Extracted $FILE_COUNT partitions"
ls -lh
echo "═══════════════════════════════════════"
