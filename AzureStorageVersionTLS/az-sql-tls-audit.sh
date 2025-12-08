#!/usr/bin/env bash

# Read-only inventering av Azure SQL Servers (Min TLS Version)
# - Flaggar SQL-servrar där minimal TLS-version inte är 1.2
# - Skriver tabell till konsolen + CSV med tidsstämpel
# - Inga förändringar görs i Azure-resurser

set -euo pipefail

TS=$(date '+%Y%m%d_%H%M%S')
OUT="sql_servers_tls_${TS}.csv"

echo "SubscriptionName,SubscriptionId,ResourceGroup,ServerName,MinimumTlsVersion,PublicNetworkAccess,IsCompliant" > "$OUT"

for SUB in $(az account list --query "[].id" -o tsv); do
  SUBNAME=$(az account show --subscription "$SUB" --query "name" -o tsv)
  echo "=== Checking subscription: $SUBNAME ($SUB) ==="
  az account set --subscription "$SUB"

  TMP="$(mktemp)"
  # Hämtar alla SQL-servrar med deras Min TLS och PNA
  # Egenskapen heter vanligtvis minimalTlsVersion (t.ex. "1.2")
  az sql server list \
    --query "[].{ResourceGroup:resourceGroup,Name:name,MinimumTls:minimalTlsVersion,PublicNetworkAccess:publicNetworkAccess}" -o tsv > "$TMP"

  # CSV-append + compliance-kolumn
  awk -v SUBNAME="$SUBNAME" -v SUB="$SUB" 'BEGIN{FS="\t"; OFS=","}
    {
      rg=$1; name=$2; mintls=$3; pna=$4;
      if(mintls=="") mintls="null";
      compliant = (mintls=="1.2" || mintls=="1_2" || mintls=="TLS1_2") ? "true" : "false";
      print SUBNAME,SUB,rg,name,mintls,pna,compliant
    }' "$TMP" >> "$OUT"

  if [ -s "$TMP" ]; then
    (
      echo "SubscriptionName,SubscriptionId,ResourceGroup,ServerName,MinimumTlsVersion,PublicNetworkAccess,IsCompliant"
      awk -v SUBNAME="$SUBNAME" -v SUB="$SUB" 'BEGIN{FS="\t"; OFS=","}
        {
          rg=$1; name=$2; mintls=$3; pna=$4;
          if(mintls=="") mintls="null";
          compliant = (mintls=="1.2" || mintls=="1_2" || mintls=="TLS1_2") ? "true" : "false";
          print SUBNAME,SUB,rg,name,mintls,pna,compliant
        }' "$TMP"
    ) | column -s, -t
  else
    echo "Inga SQL-servrar funna i denna subscription."
  fi

  rm -f "$TMP"
done

echo "Export klar: $OUT"




