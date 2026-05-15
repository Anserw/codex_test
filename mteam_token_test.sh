#!/usr/bin/env bash
set -euo pipefail

# M-Team token smoke test script.
#
# Default flow:
#   1) POST /api/torrent/search
#   2) Extract first torrent id from response JSON
#   3) GET /api/torrent/download/<id>
#
# Usage:
#   ./mteam_token_test.sh [base_url]
#
# Optional env vars:
#   mteam                    API token (required)
#   WORKDIR                  output dir (default: ./mteam_test_output)
#   SEARCH_PATH              search endpoint (default: /api/torrent/search)
#   SEARCH_METHOD            GET or POST (default: POST)
#   SEARCH_BODY              request body for POST search
#   SEARCH_QUERY             query string for GET search, e.g. "keyword=ubuntu"
#   DOWNLOAD_PATH_TEMPLATE   printf template with torrent id, default /api/torrent/download/%s
#   DOWNLOAD_METHOD          GET or POST (default: GET)
#   AUTH_STYLE               auto|authorization|x_api_key|both (default: auto)
#
# Exit codes:
#   1  missing token
#   2  search request failed
#   3  download request failed
#   4  jq missing / invalid JSON / torrent id not found

BASE_URL="${1:-https://api.m-team.io}"
SEARCH_PATH="${SEARCH_PATH:-/api/torrent/search}"
SEARCH_METHOD="${SEARCH_METHOD:-POST}"
SEARCH_BODY="${SEARCH_BODY:-{\"keyword\":\"\",\"mode\":\"adult\"}}"
SEARCH_QUERY="${SEARCH_QUERY:-}"
DOWNLOAD_PATH_TEMPLATE="${DOWNLOAD_PATH_TEMPLATE:-/api/torrent/download/%s}"
DOWNLOAD_METHOD="${DOWNLOAD_METHOD:-GET}"
AUTH_STYLE="${AUTH_STYLE:-auto}"

if [[ -z "${mteam:-}" ]]; then
  echo "[ERROR] env var 'mteam' is not set." >&2
  exit 1
fi
TOKEN="$mteam"

WORKDIR="${WORKDIR:-./mteam_test_output}"
mkdir -p "$WORKDIR"

build_url() {
  local base="$1" path="$2"
  if [[ "$path" == /* ]]; then
    printf '%s%s' "$base" "$path"
  else
    printf '%s/%s' "$base" "$path"
  fi
}

SEARCH_URL="$(build_url "$BASE_URL" "$SEARCH_PATH")"
if [[ -n "$SEARCH_QUERY" ]]; then
  SEARCH_URL="${SEARCH_URL}?${SEARCH_QUERY}"
fi

SEARCH_RESP="$WORKDIR/search_response.json"
SEARCH_HDR="$WORKDIR/search_headers.txt"

header_args=()
case "$AUTH_STYLE" in
  authorization)
    header_args+=( -H "Authorization: $TOKEN" )
    ;;
  x_api_key)
    header_args+=( -H "x-api-key: $TOKEN" )
    ;;
  both|auto)
    header_args+=( -H "Authorization: $TOKEN" -H "x-api-key: $TOKEN" )
    ;;
  *)
    echo "[ERROR] AUTH_STYLE must be one of: auto, authorization, x_api_key, both" >&2
    exit 1
    ;;
esac

curl_common=( -sS -L -w '%{http_code}' -D )

echo "[INFO] Testing token against: $BASE_URL"
echo "[INFO] Search: ${SEARCH_METHOD^^} $SEARCH_URL"

if [[ "${SEARCH_METHOD^^}" == "POST" ]]; then
  HTTP_CODE=$(curl "${curl_common[@]}" "$SEARCH_HDR" -o "$SEARCH_RESP" \
    -X POST "$SEARCH_URL" \
    -H "Content-Type: application/json" \
    "${header_args[@]}" \
    --data "$SEARCH_BODY" || true)
else
  HTTP_CODE=$(curl "${curl_common[@]}" "$SEARCH_HDR" -o "$SEARCH_RESP" \
    -X GET "$SEARCH_URL" \
    "${header_args[@]}" || true)
fi

echo "[INFO] Search HTTP code: $HTTP_CODE"
echo "[INFO] Search response: $SEARCH_RESP"

if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
  echo "[WARN] Search failed; check $SEARCH_HDR and $SEARCH_RESP"
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[WARN] jq not found; cannot parse torrent id automatically."
  exit 4
fi

if ! jq empty "$SEARCH_RESP" >/dev/null 2>&1; then
  echo "[WARN] Search response is not valid JSON; cannot parse torrent id."
  exit 4
fi

TORRENT_ID=$(jq -r '
  .data[0].id //
  .data.data[0].id //
  .data.torrents[0].id //
  .data.list[0].id //
  .message[0].id //
  empty
' "$SEARCH_RESP" | head -n1)

if [[ -z "$TORRENT_ID" || "$TORRENT_ID" == "null" ]]; then
  echo "[WARN] No torrent id extracted. Inspect: $SEARCH_RESP"
  exit 4
fi

printf -v DOWNLOAD_PATH "$DOWNLOAD_PATH_TEMPLATE" "$TORRENT_ID"
DOWNLOAD_URL="$(build_url "$BASE_URL" "$DOWNLOAD_PATH")"
DOWNLOAD_FILE="$WORKDIR/${TORRENT_ID}.torrent"
DOWNLOAD_HDR="$WORKDIR/download_headers.txt"

echo "[INFO] Download: ${DOWNLOAD_METHOD^^} $DOWNLOAD_URL"
DL_CODE=$(curl "${curl_common[@]}" "$DOWNLOAD_HDR" -o "$DOWNLOAD_FILE" \
  -X "${DOWNLOAD_METHOD^^}" "$DOWNLOAD_URL" \
  "${header_args[@]}" || true)

echo "[INFO] Download HTTP code: $DL_CODE"
if [[ "$DL_CODE" -ge 200 && "$DL_CODE" -lt 300 ]]; then
  echo "[OK] Download saved to: $DOWNLOAD_FILE"
else
  echo "[WARN] Download failed; check $DOWNLOAD_HDR"
  exit 3
fi
