#!/bin/bash
set -e

FILE="$1"
[ ! -f "$FILE" ] && { echo "❌ File not found"; exit 1; }

echo "📤 Uploading to GoFile..."

# Get token first
TOKEN_RESP=$(curl -s -X POST https://api.gofile.io/accounts 2>/dev/null)
TOKEN=$(echo "$TOKEN_RESP" | grep -oP '"token"\s*:\s*"\K[^"]+' | head -n 1)

if [ -z "$TOKEN" ]; then
  echo "⚠️ Getting token failed, trying direct upload..."
  # Direct upload
  RESP=$(curl -s -F "file=@$FILE" https://api.gofile.io/uploadFile 2>/dev/null)
else
  echo "✓ Got token"
  RESP=$(curl -s -F "file=@$FILE" -F "token=$TOKEN" https://api.gofile.io/uploadFile 2>/dev/null)
fi

echo "Response: $RESP"

if echo "$RESP" | grep -q '"status":"ok"'; then
  URL=$(echo "$RESP" | grep -oP '"downloadPage"\s*:\s*"\K[^"]+')
  if [ -n "$URL" ]; then
    echo "✅ Success!"
    echo "🔗 $URL"
    echo "$URL" > download_url.txt
    exit 0
  fi
fi

echo "❌ Upload failed"
exit 1
