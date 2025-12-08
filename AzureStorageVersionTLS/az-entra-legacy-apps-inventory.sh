#!/usr/bin/env bash

# Read-only inventering av Entra ID applikationer (heuristik för legacy-klientmönster)
# - Identifierar public client/implicit grant/OOB-URI mönster
# - Kräver Graph-åtkomst via az (delegated) med rättigheter att läsa applikationer

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq krävs för detta skript"; exit 1; }

TS=$(date '+%Y%m%d_%H%M%S')
OUT="entra_legacy_apps_${TS}.csv"

echo "AppId,DisplayName,SignInAudience,PublicClient,IsFallbackPublicClient,ImplicitGrantEnabled,HasOOBRedirect,IsCompliant" > "$OUT"

URL="https://graph.microsoft.com/v1.0/applications?$top=999"

TMP_JSON="$(mktemp)"
TMP_PAGE="$(mktemp)"
> "$TMP_JSON"

while [ -n "$URL" ] && [ "$URL" != "null" ]; do
  az rest --method GET --url "$URL" --output json > "$TMP_PAGE"
  # Append items
  jq -c '.value[]' "$TMP_PAGE" >> "$TMP_JSON"
  URL=$(jq -r '._"@odata.nextLink" // .["@odata.nextLink"] // .nextLink // empty' "$TMP_PAGE" 2>/dev/null || echo "")
done

if [ ! -s "$TMP_JSON" ]; then
  echo "Inga applikationer hämtades från Microsoft Graph. Kontrollera behörigheter." >&2
  echo "Export klar: $OUT"
  exit 0
fi

while IFS= read -r LINE; do
  APPID=$(echo "$LINE" | jq -r '.appId')
  NAME=$(echo "$LINE" | jq -r '.displayName' | tr '\n,' '  ')
  AUD=$(echo "$LINE" | jq -r '.signInAudience // ""')
  PUB=$(echo "$LINE" | jq -r '.publicClient // false | tostring')
  FALLBACK=$(echo "$LINE" | jq -r '.isFallbackPublicClient // false | tostring')

  # Implicit grant checks (web and spa)
  IMPL=$(echo "$LINE" | jq -r '((.web.implicitGrantSettings.enableIdTokenIssuance // false) or (.spa.implicitGrantSettings.enableIdTokenIssuance // false) or (.oauth2AllowImplicitFlow // false)) | tostring')

  # OOB / legacy redirect patterns
  HAS_OOB=$(echo "$LINE" | jq -r '[
      (.publicClient.redirectUris // []),
      (.web.redirectUris // []),
      (.spa.redirectUris // [])
    ] | add | map(select(test("^urn:ietf:wg:oauth:2.0:oob") or test("localhost(:[0-9]+)?/oauth2/callback", "i"))) | length > 0 | tostring')

  # Compliance: true endast om inga legacy-mönster
  # legacy om publicClient=true eller isFallbackPublicClient=true eller implicit grant true eller OOB-URI
  if [ "$PUB" = "true" ] || [ "$FALLBACK" = "true" ] || [ "$IMPL" = "true" ] || [ "$HAS_OOB" = "true" ]; then
    COMPL="false"
  else
    COMPL="true"
  fi

  echo "$APPID,$NAME,$AUD,$PUB,$FALLBACK,$IMPL,$HAS_OOB,$COMPL" >> "$OUT"
done < "$TMP_JSON"

(
  echo "AppId,DisplayName,SignInAudience,PublicClient,IsFallbackPublicClient,ImplicitGrantEnabled,HasOOBRedirect,IsCompliant"
  cat "$OUT" | tail -n +2
) | column -s, -t

rm -f "$TMP_JSON" "$TMP_PAGE"

echo "Export klar: $OUT"




