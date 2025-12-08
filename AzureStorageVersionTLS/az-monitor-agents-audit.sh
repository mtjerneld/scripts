#!/usr/bin/env bash

# Read-only inventering av agenttillägg på VM och VMSS
# - Identifierar legacy Log Analytics-agenter (MMA/OMS) och nya Azure Monitor-agenter
# - Skriver tabell till konsolen + CSV med tidsstämpel

set -euo pipefail

TS=$(date '+%Y%m%d_%H%M%S')
OUT="monitor_agents_${TS}.csv"

echo "SubscriptionName,SubscriptionId,ResourceGroup,VmType,Name,ExtensionPublisher,ExtensionType,ExtensionVersion,IsLegacyAgent,IsCompliant" > "$OUT"

# Heuristiklistor
LEGACY_TYPES="OmsAgentForLinux MicrosoftMonitoringAgent MMAExtension Microsoft.EnterpriseCloud.Monitoring"
COMPLIANT_TYPES="AzureMonitorLinuxAgent AzureMonitorWindowsAgent"

is_in_list() {
  local needle="$1"; shift
  for item in "$@"; do
    if [ "$needle" = "$item" ]; then return 0; fi
  done
  return 1
}

for SUB in $(az account list --query "[].id" -o tsv); do
  SUBNAME=$(az account show --subscription "$SUB" --query "name" -o tsv)
  echo "=== Checking subscription: $SUBNAME ($SUB) ==="
  az account set --subscription "$SUB"

  TMP_OUT="$(mktemp)"
  : > "$TMP_OUT"

  # VM extensions
  az resource list --resource-type Microsoft.Compute/virtualMachines/extensions \
    --query "[].{Id:id,RG:resourceGroup,Name:name,Type:type,Publisher:properties.publisher,ExtType:properties.type,Version:properties.typeHandlerVersion}" -o tsv |
  while IFS=$'\t' read -r RID RG NAME RTYPE PUBLISHER EXTTYPE VERSION; do
    # Namnformat: vmName/extensionName
    VMNAME=${NAME%%/*}
    LEGACY="false"; COMPL="false"
    if is_in_list "$EXTTYPE" $LEGACY_TYPES; then LEGACY="true"; fi
    if is_in_list "$EXTTYPE" $COMPLIANT_TYPES; then COMPL="true"; fi
    echo "$SUBNAME,$SUB,$RG,VM,$VMNAME,$PUBLISHER,$EXTTYPE,$VERSION,$LEGACY,$COMPL" >> "$TMP_OUT"
  done

  # VMSS extensions
  az resource list --resource-type Microsoft.Compute/virtualMachineScaleSets/extensions \
    --query "[].{Id:id,RG:resourceGroup,Name:name,Type:type,Publisher:properties.publisher,ExtType:properties.type,Version:properties.typeHandlerVersion}" -o tsv |
  while IFS=$'\t' read -r RID RG NAME RTYPE PUBLISHER EXTTYPE VERSION; do
    # Namnformat: vmssName/extensionName
    VMSSNAME=${NAME%%/*}
    LEGACY="false"; COMPL="false"
    if is_in_list "$EXTTYPE" $LEGACY_TYPES; then LEGACY="true"; fi
    if is_in_list "$EXTTYPE" $COMPLIANT_TYPES; then COMPL="true"; fi
    echo "$SUBNAME,$SUB,$RG,VMSS,$VMSSNAME,$PUBLISHER,$EXTTYPE,$VERSION,$LEGACY,$COMPL" >> "$TMP_OUT"
  done

  if [ -s "$TMP_OUT" ]; then
    (
      echo "SubscriptionName,SubscriptionId,ResourceGroup,VmType,Name,ExtensionPublisher,ExtensionType,ExtensionVersion,IsLegacyAgent,IsCompliant"
      cat "$TMP_OUT"
    ) | column -s, -t

    cat "$TMP_OUT" >> "$OUT"
  else
    echo "Inga VM/VMSS-agenttillägg funna i denna subscription."
  fi

  rm -f "$TMP_OUT"
done

echo "Export klar: $OUT"




