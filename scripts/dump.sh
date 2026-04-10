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
[ ! -f "firmware.zip" ] && exit 1
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

echo "  AP file: $(basename "$AP_FILE")"
tar -xf "$AP_FILE"
rm -f "$AP_FILE"

echo ""; echo "🔍 DEBUG: Listing all extracted files..."
find . -maxdepth 1 -type f | head -30

echo ""; echo "[4/6] Processing partitions..."
mkdir -p processed

# First, look for individual partition files
echo "  Looking for individual partitions..."
PARTITIONS="system system_ext product vendor vendor_boot vendor_dlkm system_dlkm boot init_boot vbmeta"

for PART in $PARTITIONS; do
  # Look for various formats
  for EXT in ".img" ".img.ext4" ".img.lz4"; do
    FILE=$(find . -maxdepth 1 -name "${PART}${EXT}" | head -n 1)
    if [ -n "$FILE" ] && [ -f "$FILE" ]; then
      echo "    ✓ Found: $(basename "$FILE")"
      
      # Decompress LZ4
      if [[ "$FILE" == *.lz4 ]]; then
        lz4 -d "$FILE" "${FILE%.lz4}" 2>/dev/null || true
        FILE="${FILE%.lz4}"
      fi
      
      # Handle sparse
      if file "$FILE" 2>/dev/null | grep -q "sparse"; then
        simg2img "$FILE" "${FILE}.raw" 2>/dev/null || true
        [ -f "${FILE}.raw" ] && mv "${FILE}.raw" "$FILE"
      fi
      
      # Compress
      if xz -9 -T0 "$FILE" 2>/dev/null; then
        mv "${FILE}.xz" "processed/${PART}.img.xz"
      else
        cp "$FILE" "processed/${PART}.img"
      fi
      break
    fi
  done
done

# Now handle super.img
SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" | head -n 1)
if [ -n "$SUPER_FILE" ] && [ -f "$SUPER_FILE" ]; then
  echo ""; echo "  Found super.img - extracting dynamic partitions..."
  
  # Decompress LZ4
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    echo "    Decompressing LZ4..."
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || true
    SUPER_FILE="super.img"
  fi
  
  SUPER_SIZE=$(du -h "$SUPER_FILE" | cut -f1)
  echo "    Size: $SUPER_SIZE"
  
  # List what's inside
  echo "    Contents:"
  if [ -f "bin/lp/lpdump" ]; then
    bin/lp/lpdump "$SUPER_FILE" 2>/dev/null | head -20 || echo "      lpdump failed"
  fi
  
  # Extract with lpunpack
  mkdir -p super_dump
  echo "    Extracting..."
  
  if [ -f "bin/lp/lpunpack" ]; then
    bin/lp/lpunpack "$SUPER_FILE" super_dump 2>/dev/null || echo "      lpunpack failed"
  fi
  
  # Check what was extracted
  echo "    Extracted files:"
  ls -lh super_dump/ 2>/dev/null || echo "      Nothing extracted"
  
  # Move partitions
  for PART in system system_ext product vendor vendor_boot vendor_dlkm system_dlkm; do
    if [ -f "super_dump/${PART}.img" ]; then
      mv "super_dump/${PART}.img" "${PART}.img"
      echo "      ✓ ${PART}.img"
      
      # Compress it
      if xz -9 -T0 "${PART}.img" 2>/dev/null; then
        mv "${PART}.img.xz" "processed/${PART}.img.xz"
      else
        mv "${PART}.img" "processed/${PART}.img"
      fi
    fi
  done
  rm -rf super_dump
fi

echo ""; echo "[5/6] Final results:"; cd processed
FILE_COUNT=$(ls -1 | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "❌ No partitions found!"
  echo ""; echo "📋 All files in AP:"
  cd ../../; find . -maxdepth 1 -type f -name "*.img*" | head -20
  exit 1
fi

echo "═══════════════════════════════════════"
echo "Extracted: $FILE_COUNT partitions"
ls -lh
echo "═══════════════════════════════════════"
echo "✅ Done!"
