#!/bin/sh
# Upload one file to the pod-assets KV space:  sh upload.sh LOCAL_FILE KEY
# Needs CLOUDFLARE_API_TOKEN (or a session where Cloudflare's API is already authorised) and CLOUDFLARE_ACCOUNT_ID.
set -e
ACCOUNT="${CLOUDFLARE_ACCOUNT_ID:-5b4f2c42c40785cc3405c48128557fd5}"
NS=5a5eab32dc5749e4905ea5b6eab1e433
AUTH=""; [ -n "$CLOUDFLARE_API_TOKEN" ] && AUTH="Authorization: Bearer $CLOUDFLARE_API_TOKEN"
curl -sf -X PUT "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/storage/kv/namespaces/$NS/values/$2" \
  ${AUTH:+-H "$AUTH"} -H 'Content-Type: application/octet-stream' --data-binary "@$1" > /dev/null && echo "uploaded $2"
