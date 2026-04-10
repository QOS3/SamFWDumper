#!/bin/bash
set -e

FILE="$1"
[ ! -f "$FILE" ] && { echo "❌ File not found"; exit 1; }

echo "📤 Uploading to GoFile..."

# Simple direct upload
RESPONSE=$(curl -s -F "file=@$FILE" https://api.gofile.io/uploadFile)
echo "Response: $RESPONSE"

if echo "$RESPONSE" | grep -q '"status":"ok"'; then
  URL=$(echo "$RESPONSE" | grep -oP '"downloadPage"\s*:\s*"\K[^"]+')
  [ -n "$URL" ] && {
    echo "✅ Success! $URL"
    echo "$URL" > download_url.txt
    exit 0
  }
fi

echo "❌ Upload failed"
exit 1
