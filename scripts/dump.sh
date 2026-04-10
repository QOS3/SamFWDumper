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
wget --no-check-certificate -O "firmware.zip" "$URL" 2>&1 | tail -5

# Check if file exists AND has size > 0
if [ ! -f "firmware.zip" ]; then
  echo "❌ Download failed - file not found"
  exit 1
fi

FILESIZE=$(stat -c%s "firmware.zip")
if [ "$FILESIZE" -eq 0 ]; then
  echo "❌ Download failed - file is empty (0 bytes)"
  echo "⚠️ The SamFW link is expired or invalid"
  rm -f firmware.zip
  exit 1
fi

echo "✅ Downloaded: $(numfmt --to=iec $FILESIZE)"

echo ""; echo "[2/6] Extracting ZIP..."
if ! unzip -o "firmware.zip" >/dev/null 2>&1; then
  echo "❌ ZIP extraction failed"
  exit 1
fi
rm -f "firmware.zip"
echo "✅ Done"

echo ""; echo "[3/6] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" | head -n 1)
if [ -z "$AP_FILE" ]; then
  echo "❌ AP file not found"
  echo "Files found:"
  ls -la
  exit 1
fi
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
    if [ -f "bin/erofs-utils/extract.erofs" ]; then
      bin/erofs-utils/extract.erofs "$SUPER_FILE" "super.img" 2>/dev/null || true
    fi
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || true
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
    if [ -f "bin/ext4/simg2img" ]; then
      bin/ext4/simg2img "$FILE" "${FILE}.raw" 2>/dev/null || true
    else
      simg2img "$FILE" "${FILE}.raw" 2>/dev/null || true
    fi
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
FILE_COUNT=$(ls -1 | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "❌ No partitions extracted!"
  exit 1
fi
echo "═══════════════════════════════════════"
echo "Files: $FILE_COUNT"; ls -lh
echo "═══════════════════════════════════════"
echo "✅ Done!"
