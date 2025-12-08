#!/usr/bin/env bash

# Read-only inventering av Azure AD Domain Services (LDAPS)
# - Hämtar secure LDAP-inställningar och certifikatets utgångsdatum
# - Compliance: secure LDAP aktiverad och certifikat inte utgånget
# - Skriver tabell till konsolen + CSV med tidsstämpel

set -euo pipefail

TS=$(date '+%Y%m%d_%H%M%S')
OUT="adds_ldaps_${TS}.csv"

echo "SubscriptionName,SubscriptionId,ResourceGroup,DomainServiceName,SecureLdapEnabled,SecureLdapExternalAccess,CertificateExpiry,IsCompliant" > "$OUT"

for SUB in $(az account list --query "[].id" -o tsv); do
  SUBNAME=$(az account show --subscription "$SUB" --query "name" -o tsv)
  echo "=== Checking subscription: $SUBNAME ($SUB) ==="
  az account set --subscription "$SUB"

  TMP_LIST="$(mktemp)"
  az ad ds list --query "[].{Name:name,ResourceGroup:resourceGroup}" -o tsv > "$TMP_LIST" || true

  TMP_OUT="$(mktemp)"
  : > "$TMP_OUT"

  if [ -s "$TMP_LIST" ]; then
    while IFS=$'\t' read -r DS_NAME DS_RG; do
      # Hämta LDAPS-inställningar
      read -r LDAP_ENABLED LDAP_EXTERNAL CERT_EXP < <(az ad ds show -n "$DS_NAME" -g "$DS_RG" --query "[ldapsSettings.ldaps, ldapsSettings.externalAccess, ldapsSettings.pfxCertificateNotAfter]" -o tsv 2>/dev/null || echo $'\t\t')

      if [ -z "$LDAP_ENABLED" ]; then LDAP_ENABLED="false"; fi
      if [ -z "$LDAP_EXTERNAL" ]; then LDAP_EXTERNAL="false"; fi
      if [ -z "$CERT_EXP" ]; then CERT_EXP=""; fi

      # Compliance: secure LDAP måste vara aktiverat och certifikatet giltigt (om datum finns)
      COMPLIANT="false"
      if [ "$LDAP_ENABLED" = "true" ]; then
        if [ -n "$CERT_EXP" ]; then
          # Jämför UTC nu med CERT_EXP (ISO 8601)
          NOW_EPOCH=$(date -u +%s)
          CERT_EPOCH=$(date -u -d "$CERT_EXP" +%s 2>/dev/null || echo 0)
          if [ "$CERT_EPOCH" -gt "$NOW_EPOCH" ]; then COMPLIANT="true"; fi
        else
          # Om inget datum, betrakta som icke-kompatibel
          COMPLIANT="false"
        fi
      fi

      echo "$SUBNAME,$SUB,$DS_RG,$DS_NAME,$LDAP_ENABLED,$LDAP_EXTERNAL,$CERT_EXP,$COMPLIANT" >> "$TMP_OUT"
    done < "$TMP_LIST"

    (
      echo "SubscriptionName,SubscriptionId,ResourceGroup,DomainServiceName,SecureLdapEnabled,SecureLdapExternalAccess,CertificateExpiry,IsCompliant"
      cat "$TMP_OUT"
    ) | column -s, -t

    cat "$TMP_OUT" >> "$OUT"
  else
    echo "Inga Azure AD Domain Services funna i denna subscription."
  fi

  rm -f "$TMP_LIST" "$TMP_OUT"
done

echo "Export klar: $OUT"




