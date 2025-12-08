#!/usr/bin/env bash

# Read-only inventering av Azure Automation (Hybrid Workers)
# - Listar Automation Accounts, Hybrid Worker Groups och Workers
# - Noterar länkad Log Analytics workspace resourceId (om tillgänglig)
# - Compliance här kräver korsning mot agentinventering (se monitor-agents-skriptet)

set -euo pipefail

TS=$(date '+%Y%m%d_%H%M%S')
OUT="automation_hybrid_workers_${TS}.csv"

echo "SubscriptionName,SubscriptionId,ResourceGroup,AutomationAccount,HybridWorkerGroup,WorkerName,LinkedWorkspaceResourceId,Notes,IsCompliant" > "$OUT"

for SUB in $(az account list --query "[].id" -o tsv); do
  SUBNAME=$(az account show --subscription "$SUB" --query "name" -o tsv)
  echo "=== Checking subscription: $SUBNAME ($SUB) ==="
  az account set --subscription "$SUB"

  TMP_ACCTS="$(mktemp)"
  az automation account list --query "[].{Name:name,ResourceGroup:resourceGroup,LinkedWorkspace:properties.linkedWorkspace}" -o tsv > "$TMP_ACCTS" || true

  TMP_OUT="$(mktemp)"
  : > "$TMP_OUT"

  if [ -s "$TMP_ACCTS" ]; then
    while IFS=$'\t' read -r AA_NAME AA_RG AA_LINKED_WS; do
      AA_LINKED_WS=${AA_LINKED_WS:-}
      TMP_GROUPS="$(mktemp)"
      az automation hybrid-runbook-worker-group list -g "$AA_RG" -a "$AA_NAME" \
        --query "[].{Name:name}" -o tsv > "$TMP_GROUPS" || true

      if [ -s "$TMP_GROUPS" ]; then
        while IFS=$'\n' read -r HG_NAME; do
          TMP_WORKERS="$(mktemp)"
          az automation hybrid-runbook-worker list -g "$AA_RG" -a "$AA_NAME" -w "$HG_NAME" \
            --query "[].{Name:name}" -o tsv > "$TMP_WORKERS" || true

          if [ -s "$TMP_WORKERS" ]; then
            while IFS=$'\n' read -r HW_NAME; do
              NOTES="Agent compliance kräver korsning med monitor_agents CSV"
              # IsCompliant okänd i detta skript
              echo "$SUBNAME,$SUB,$AA_RG,$AA_NAME,$HG_NAME,$HW_NAME,${AA_LINKED_WS},$NOTES,unknown" >> "$TMP_OUT"
            done < "$TMP_WORKERS"
          else
            NOTES="Inga workers i gruppen"
            echo "$SUBNAME,$SUB,$AA_RG,$AA_NAME,$HG_NAME,,${AA_LINKED_WS},$NOTES,unknown" >> "$TMP_OUT"
          fi
          rm -f "$TMP_WORKERS"
        done < "$TMP_GROUPS"
      else
        NOTES="Inga hybrid worker groups"
        echo "$SUBNAME,$SUB,$AA_RG,$AA_NAME,,,${AA_LINKED_WS},$NOTES,unknown" >> "$TMP_OUT"
      fi
      rm -f "$TMP_GROUPS"
    done < "$TMP_ACCTS"

    (
      echo "SubscriptionName,SubscriptionId,ResourceGroup,AutomationAccount,HybridWorkerGroup,WorkerName,LinkedWorkspaceResourceId,Notes,IsCompliant"
      cat "$TMP_OUT"
    ) | column -s, -t

    cat "$TMP_OUT" >> "$OUT"
  else
    echo "Inga Automation Accounts funna i denna subscription."
  fi

  rm -f "$TMP_ACCTS" "$TMP_OUT"
done

echo "Export klar: $OUT"




