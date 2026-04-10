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

# Extract super.img if exists
SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" | head -n 1)

if [ -n "$SUPER_FILE" ] && [ -f "$SUPER_FILE" ]; then
  echo "  🔍 Found: $(basename "$SUPER_FILE")"
  
  # Decompress LZ4
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    echo "    Decompressing LZ4..."
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || { echo "    ❌ LZ4 failed"; exit 1; }
    SUPER_FILE="super.img"
  fi
  
  SUPER_SIZE=$(du -h "$SUPER_FILE" | cut -f1)
  echo "    Size: $SUPER_SIZE"
  
  # DEBUG: Check file type
  echo "    File type:"
  file "$SUPER_FILE"
  
  # DEBUG: Check if it's sparse
  if file "$SUPER_FILE" 2>/dev/null | grep -q "sparse"; then
    echo "    ⚠️ Sparse image detected - converting..."
    simg2img "$SUPER_FILE" "super.img.raw" 2>/dev/null || true
    [ -f "super.img.raw" ] && mv "super.img.raw" "$SUPER_FILE"
  fi
  
  # DEBUG: List what lpunpack sees
  echo "    🔎 Checking super.img contents..."
  
  # Try lpdump first to see what's inside
  if [ -f "bin/lp/lpdump" ]; then
    echo "    Running lpdump..."
    bin/lp/lpdump "$SUPER_FILE" 2>&1 | head -30 || echo "      lpdump failed"
  fi
  
  # Try to list partitions with lpunpack --list
  echo "    Attempting to list partitions..."
  if [ -f "bin/lp/lpunpack" ]; then
    bin/lp/lpunpack --list "$SUPER_FILE" 2>&1 | head -20 || echo "      lpunpack --list failed"
  fi
  
  # Try Python extractor to list
  if [ -f "bin/py_scripts/imgextractor.py" ]; then
    echo "    Trying Python extractor to list..."
    python3 bin/py_scripts/imgextractor.py --list "$SUPER_FILE" 2>&1 | head -20 || echo "      Python list failed"
  fi
  
  # Now try actual extraction
  echo "    Extracting dynamic partitions..."
  mkdir -p super_dump
  
  EXTRACTION_SUCCESS=false
  
  # Method 1: lpunpack
  if [ -f "bin/lp/lpunpack" ]; then
    echo "      Trying lpunpack..."
    if bin/lp/lpunpack "$SUPER_FILE" super_dump 2>/dev/null; then
      echo "        ✓ lpunpack succeeded"
      EXTRACTION_SUCCESS=true
    else
      echo "        ⚠️ lpunpack failed"
    fi
  fi
  
  # Method 2: Python extractor
  if [ "$EXTRACTION_SUCCESS" = false ] && [ -f "bin/py_scripts/imgextractor.py" ]; then
    echo "      Trying Python extractor..."
    if python3 bin/py_scripts/imgextractor.py "$SUPER_FILE" super_dump 2>/dev/null; then
      echo "        ✓ Python extractor succeeded"
      EXTRACTION_SUCCESS=true
    else
      echo "        ⚠️ Python extractor failed"
    fi
  fi
  
  # Method 3: Try extracting partition by partition
  if [ "$EXTRACTION_SUCCESS" = false ]; then
    echo "      Trying partition-by-partition extraction..."
    PARTITIONS="system system_ext product vendor vendor_boot vendor_dlkm system_dlkm"
    
    for PART in $PARTITIONS; do
      echo "        Trying to extract: $PART..."
      
      # Try with lpunpack --partition
      if [ -f "bin/lp/lpunpack" ]; then
        if bin/lp/lpunpack --partition="$PART" "$SUPER_FILE" super_dump 2>/dev/null; then
          echo "          ✓ Extracted: $PART"
        fi
      fi
      
      # Try _a slot
      if [ -f "bin/lp/lpunpack" ]; then
        if bin/lp/lpunpack --partition="${PART}_a" "$SUPER_FILE" super_dump 2>/dev/null; then
          echo "          ✓ Extracted: ${PART}_a"
        fi
      fi
    done
  fi
  
  # Check what was extracted
  echo "    Checking extracted files..."
  if [ -d "super_dump" ]; then
    EXTRACTED_COUNT=$(ls -1 super_dump/ 2>/dev/null | wc -l)
    echo "      Files in super_dump: $EXTRACTED_COUNT"
    ls -lh super_dump/ 2>/dev/null | head -20 || echo "      (empty directory)"
    
    # Move extracted partitions (handle A/B slots)
    for PART in system system_ext product vendor vendor_boot vendor_dlkm system_dlkm; do
      SRC=""
      if [ -f "super_dump/${PART}_a.img" ]; then
        SRC="super_dump/${PART}_a.img"
        echo "      ✓ Found: ${PART}_a.img → ${PART}.img"
      elif [ -f "super_dump/${PART}.img" ]; then
        SRC="super_dump/${PART}.img"
        echo "      ✓ Found: ${PART}.img"
      elif [ -f "super_dump/${PART}_b.img" ]; then
        SRC="super_dump/${PART}_b.img"
        echo "      ✓ Found: ${PART}_b.img → ${PART}.img"
      fi
      
      if [ -n "$SRC" ]; then
        cp "$SRC" "${PART}.img"
        
        # Compress
        if xz -9 -T0 "${PART}.img" 2>/dev/null; then
          mv "${PART}.img.xz" "processed/${PART}.img.xz"
        else
          mv "${PART}.img" "processed/${PART}.img"
        fi
      fi
    done
  else
    echo "      ⚠️ super_dump directory not created"
  fi
  
  rm -rf super_dump
  rm -f super.img
else
  echo "  ⚠️ super.img not found"
fi

# Extract individual partitions
echo ""; echo "  Processing individual partitions..."
PARTITIONS="system system_ext product vendor vendor_boot vendor_dlkm system_dlkm boot init_boot vbmeta"

for PART in $PARTITIONS; do
  [ -f "processed/${PART}.img.xz" ] && continue
  
  FILE=$(find . -maxdepth 1 -name "${PART}.img*" | head -n 1)
  [ -z "$FILE" ] && { echo "    ⚠️ $PART not found"; continue; }
  
  echo "    ✓ Found: $(basename "$FILE")"
  
  # Handle LZ4
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
    echo "      ✓ ${PART}.img.xz"
  else
    cp "$FILE" "processed/${PART}.img"
    echo "      ✓ ${PART}.img"
  fi
done

echo ""; echo "[5/5] Results:"; cd processed
FILE_COUNT=$(ls -1 | wc -l)
[ "$FILE_COUNT" -eq 0 ] && { echo "❌ Nothing extracted!"; exit 1; }

echo "═══════════════════════════════════════"
echo "✅ Extracted $FILE_COUNT partitions"
ls -lh
echo "═══════════════════════════════════════"
