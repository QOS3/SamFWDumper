#!/bin/bash
set -e

echo "═══════════════════════════════════════"
echo "   Professional Firmware Extractor"
echo "═══════════════════════════════════════"

URL="$1"
[ -z "$URL" ] && { echo "❌ No URL"; exit 1; }

# Setup PATH to use bin tools
export PATH="$GITHUB_WORKSPACE/bin/lp:$GITHUB_WORKSPACE/bin/ext4:$GITHUB_WORKSPACE/bin/erofs-utils:$PATH"
chmod +x bin/lp/* bin/ext4/* bin/erofs-utils/* bin/py_scripts/* 2>/dev/null || true

echo ""; echo "[1/6] Downloading..."
wget --no-check-certificate -O "firmware.zip" "$URL" 2>&1 | tail -3
[ ! -f "firmware.zip" ] && { echo "❌ Download failed"; exit 1; }
echo "✅ Downloaded: $(du -h firmware.zip | cut -f1)"

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

echo ""; echo "[4/6] Extracting super.img..."
SUPER_FILE=$(find . -name "super.img*" | head -n 1)

if [ -n "$SUPER_FILE" ] && [ -f "$SUPER_FILE" ]; then
  echo "  Found: $(basename "$SUPER_FILE")"
  
  # Handle LZ4
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    echo "  Decompressing LZ4..."
    bin/erofs-utils/extract.erofs "$SUPER_FILE" "super.img" 2>/dev/null || lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || true
    SUPER_FILE="super.img"
  fi
  
  # Extract with lpunpack from bin
  echo "  Extracting dynamic partitions..."
  mkdir -p super_dump
  
  if [ -f "bin/lp/lpunpack" ]; then
    bin/lp/lpunpack "$SUPER_FILE" super_dump 2>/dev/null || true
  elif [ -f "bin/py_scripts/imgextractor.py" ]; then
    python3 bin/py_scripts/imgextractor.py "$SUPER_FILE" super_dump 2>/dev/null || true
  fi
  
  # Move extracted partitions
  for PART in system system_ext product vendor vendor_boot vendor_dlkm system_dlkm; do
    [ -f "super_dump/${PART}.img" ] && { mv "super_dump/${PART}.img" "${PART}.img"; echo "  ✓ ${PART}.img"; }
  done
  rm -rf super_dump
else
  echo "  ⚠️ super.img not found"
fi

echo ""; echo "[5/6] Processing partitions..."
mkdir -p processed

PARTITIONS="system system_ext product vendor vendor_boot vendor_dlkm system_dlkm boot init_boot vbmeta"

for PART in $PARTITIONS; do
  FILE=$(find . -maxdepth 1 -name "${PART}.img" | head -n 1)
  [ -z "$FILE" ] && { echo "  ⚠️ $PART not found"; continue; }
  
  FILE_SIZE=$(du -h "$FILE" | cut -f1)
  echo "  Processing ${PART}.img ($FILE_SIZE)..."
  
  # Handle sparse
  if file "$FILE" 2>/dev/null | grep -q "sparse"; then
    echo "    Converting sparse..."
    [ -f "bin/ext4/simg2img" ] && bin/ext4/simg2img "$FILE" "${FILE}.raw" 2>/dev/null || simg2img "$FILE" "${FILE}.raw" 2>/dev/null || true
    [ -f "${FILE}.raw" ] && mv "${FILE}.raw" "$FILE"
  fi
  
  # Compress with XZ
  if xz -9 -T0 "$FILE" 2>/dev/null; then
    mv "${FILE}.xz" "processed/${PART}.img.xz"
    echo "    ✓ ${PART}.img.xz"
  else
    cp "$FILE" "processed/${PART}.img"
    echo "    ✓ ${PART}.img"
  fi
done

echo ""; echo "[6/6] Results:"; cd processed
echo "═══════════════════════════════════════"
echo "Files: $(ls -1 | wc -l)"; ls -lh
echo "═══════════════════════════════════════"
echo "✅ Done!"
