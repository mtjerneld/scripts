# Read-only inventering av Azure Storage-konton
# - Flaggar kontotyper som påverkas av pensioneringen (BlobStorage, Storage)
# - Flaggar TLS-konfigurationer som inte tvingar TLS1_2
# - Skriver tabell till konsolen + CSV med tidsstämpel
# - Inga förändringar görs i Azure-resurser

set -euo pipefail

TS=$(date '+%Y%m%d_%H%M%S')
OUT="storage_inventory_${TS}.csv"

echo "SubscriptionName,SubscriptionId,ResourceGroup,Name,Kind,MinimumTlsVersion,Status" > "$OUT"

for SUB in $(az account list --query "[].id" -o tsv); do
  SUBNAME=$(az account show --subscription "$SUB" --query "name" -o tsv)
  echo "=== Checking subscription: $SUBNAME ($SUB) ==="
  az account set --subscription "$SUB"

  # Hämta kandidater: version (BlobStorage/Storage) eller TLS != TLS1_2/null
  TMP="$(mktemp)"
  az storage account list \
    --query "[?(kind=='BlobStorage' || kind=='Storage' || minimumTlsVersion!='TLS1_2' || minimumTlsVersion==null)].{
      ResourceGroup:resourceGroup,
      Name:name,
      Kind:kind,
      MinimumTlsVersion:minimumTlsVersion
    }" -o tsv > "$TMP"

  # CSV-append + beräkna Status
  awk -v SUBNAME="$SUBNAME" -v SUB="$SUB" 'BEGIN{FS="\t"; OFS=","}
    {
      rg=$1; name=$2; kind=$3; tls=$4;
      if(tls=="") tls="null";
      versionIssue = (kind=="BlobStorage" || kind=="Storage");
      tlsIssue     = (tls!="TLS1_2");
      status = (versionIssue && tlsIssue) ? "Both" : (versionIssue ? "Version" : (tlsIssue ? "TLS" : "OK"));
      print SUBNAME,SUB,rg,name,kind,tls,status
    }' "$TMP" >> "$OUT"

  # Tabell till konsolen om det finns rader
  if [ -s "$TMP" ]; then
    (
      echo "SubscriptionName,SubscriptionId,ResourceGroup,Name,Kind,MinimumTlsVersion,Status"
      awk -v SUBNAME="$SUBNAME" -v SUB="$SUB" 'BEGIN{FS="\t"; OFS=","}
        {
          rg=$1; name=$2; kind=$3; tls=$4;
          if(tls=="") tls="null";
          versionIssue = (kind=="BlobStorage" || kind=="Storage");
          tlsIssue     = (tls!="TLS1_2");
          status = (versionIssue && tlsIssue) ? "Both" : (versionIssue ? "Version" : (tlsIssue ? "TLS" : "OK"));
          print SUBNAME,SUB,rg,name,kind,tls,status
        }' "$TMP"
    ) | column -s, -t
  else
    echo "Inga avvikelser i denna subscription."
  fi

  rm -f "$TMP"
done

echo "Export klar: $OUT"
