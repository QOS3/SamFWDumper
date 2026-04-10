#!/bin/bash
set -e

echo "═══════════════════════════════════════"
echo "   Universal Samsung Firmware Extractor"
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

echo ""; echo "🔍 Scanning for partitions..."
echo "  All image files found:"
find . -maxdepth 1 -type f \( -name "*.img*" -o -name "*.lz4" \) | while read f; do
  echo "    - $(basename "$f") ($(du -h "$f" | cut -f1))"
done

echo ""; echo "[4/5] Extracting ALL partitions..."
mkdir -p processed

# Method 1: Extract individual partitions
echo "  Step 1: Looking for individual partitions..."
PARTITIONS="system system_ext product vendor vendor_boot vendor_dlkm system_dlkm boot init_boot vbmeta odm boot_dtbs"

for PART in $PARTITIONS; do
  for EXT in ".img" ".img.ext4" ".img.lz4"; do
    FILE=$(find . -maxdepth 1 -name "${PART}${EXT}" | head -n 1)
    if [ -n "$FILE" ] && [ -f "$FILE" ]; then
      echo "    ✓ Found: $(basename "$FILE")"
      
      # Decompress LZ4
      if [[ "$FILE" == *.lz4 ]]; then
        lz4 -d "$FILE" "${FILE%.lz4}" 2>/dev/null || true
        FILE="${FILE%.lz4}"
      fi
      
      # Handle sparse images
      if file "$FILE" 2>/dev/null | grep -q "sparse"; then
        simg2img "$FILE" "${FILE}.raw" 2>/dev/null || true
        [ -f "${FILE}.raw" ] && mv "${FILE}.raw" "$FILE"
      fi
      
      # Compress with XZ
      if xz -9 -T0 "$FILE" 2>/dev/null; then
        mv "${FILE}.xz" "processed/${PART}.img.xz"
      else
        cp "$FILE" "processed/${PART}.img"
      fi
      break
    fi
  done
done

# Method 2: Extract super.img (for newer devices)
echo ""; echo "  Step 2: Looking for super.img..."
SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" | head -n 1)

if [ -n "$SUPER_FILE" ] && [ -f "$SUPER_FILE" ]; then
  echo "    ✓ Found: $(basename "$SUPER_FILE")"
  
  # Decompress LZ4 if needed
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    echo "    Decompressing LZ4 (this may take 2-3 minutes)..."
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || { echo "    ❌ LZ4 decompression failed"; exit 1; }
    SUPER_FILE="super.img"
  fi
  
  SUPER_SIZE=$(du -h "$SUPER_FILE" | cut -f1)
  echo "    Size: $SUPER_SIZE"
  
  mkdir -p super_dump
  
  # Try multiple extraction methods
  echo "    Extracting dynamic partitions..."
  
  # Method A: lpunpack
  if [ -f "bin/lp/lpunpack" ]; then
    echo "      Trying lpunpack..."
    if bin/lp/lpunpack "$SUPER_FILE" super_dump 2>/dev/null; then
      echo "        ✓ lpunpack succeeded"
    else
      echo "        ⚠️ lpunpack failed"
    fi
  fi
  
  # Method B: Python extractor
  if [ $(ls super_dump/ 2>/dev/null | wc -l) -eq 0 ] && [ -f "bin/py_scripts/imgextractor.py" ]; then
    echo "      Trying Python extractor..."
    if python3 bin/py_scripts/imgextractor.py "$SUPER_FILE" super_dump 2>/dev/null; then
      echo "        ✓ Python extractor succeeded"
    else
      echo "        ⚠️ Python extractor failed"
    fi
  fi
  
  # Method C: lpdump + extract
  if [ $(ls super_dump/ 2>/dev/null | wc -l) -eq 0 ] && [ -f "bin/lp/lpdump" ]; then
    echo "      Trying lpdump..."
    bin/lp/lpdump "$SUPER_FILE" 2>/dev/null | grep -E "^\s+\d+" | while read line; do
      PART_NAME=$(echo "$line" | awk '{print $NF}')
      echo "        Extracting: $PART_NAME"
      # Use dd or lpextract if available
    done || echo "        ⚠️ lpdump failed"
  fi
  
  # Move extracted partitions
  echo "    Checking extracted partitions..."
  EXTRACTED_COUNT=0
  for PART in system system_ext product vendor vendor_boot vendor_dlkm system_dlkm; do
    if [ -f "super_dump/${PART}.img" ]; then
      echo "      ✓ ${PART}.img"
      mv "super_dump/${PART}.img" "${PART}.img"
      
      # Compress
      if xz -9 -T0 "${PART}.img" 2>/dev/null; then
        mv "${PART}.img.xz" "processed/${PART}.img.xz"
      else
        mv "${PART}.img" "processed/${PART}.img"
      fi
      EXTRACTED_COUNT=$((EXTRACTED_COUNT + 1))
    fi
  done
  
  if [ "$EXTRACTED_COUNT" -eq 0 ]; then
    echo "    ⚠️ No partitions extracted from super.img"
    echo "    Contents of super_dump:"
    ls -lh super_dump/ 2>/dev/null || echo "      (empty)"
  fi
  
  rm -rf super_dump
  rm -f super.img
else
  echo "    ⚠️ super.img not found (older device or separate partitions)"
fi

# Method 3: Catch-all for any other .img files
echo ""; echo "  Step 3: Looking for any other .img files..."
for IMG_FILE in $(find . -maxdepth 1 -name "*.img" -o -name "*.img.ext4" | grep -v "super"); do
  BASENAME=$(basename "$IMG_FILE" | sed 's/\.img\.ext4$//' | sed 's/\.img$//')
  if [ ! -f "processed/${BASENAME}.img.xz" ] && [ ! -f "processed/${BASENAME}.img" ]; then
    echo "    Found: $(basename "$IMG_FILE")"
    
    # Handle .img.ext4
    if [[ "$IMG_FILE" == *.img.ext4 ]]; then
      mv "$IMG_FILE" "${IMG_FILE%.img.ext4}.img"
      IMG_FILE="${IMG_FILE%.img.ext4}.img"
      BASENAME=$(basename "$IMG_FILE" .img)
    fi
    
    # Handle sparse
    if file "$IMG_FILE" 2>/dev/null | grep -q "sparse"; then
      simg2img "$IMG_FILE" "${IMG_FILE}.raw" 2>/dev/null || true
      [ -f "${IMG_FILE}.raw" ] && mv "${IMG_FILE}.raw" "$IMG_FILE"
    fi
    
    # Compress
    if xz -9 -T0 "$IMG_FILE" 2>/dev/null; then
      mv "${IMG_FILE}.xz" "processed/${BASENAME}.img.xz"
      echo "      ✓ ${BASENAME}.img.xz"
    else
      cp "$IMG_FILE" "processed/${BASENAME}.img"
      echo "      ✓ ${BASENAME}.img"
    fi
  fi
done

echo ""; echo "[5/5] Final Results:"; cd processed
FILE_COUNT=$(ls -1 | wc -l)

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "❌ ERROR: No partitions extracted!"
  echo ""; echo "📋 Debug info:"
  cd ../../; find . -maxdepth 1 -type f -name "*.img*" | head -20
  exit 1
fi

TOTAL_SIZE=$(du -sh . | cut -f1)
echo "═══════════════════════════════════════"
echo "✅ Successfully extracted $FILE_COUNT partitions"
echo "Total size: $TOTAL_SIZE"
echo ""; echo "Files:"
ls -lh
echo "═══════════════════════════════════════"
echo "✅ Done!"
