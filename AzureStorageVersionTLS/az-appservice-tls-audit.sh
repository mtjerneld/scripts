#!/usr/bin/env bash
set -euo pipefail
TS=$(date '+%Y%m%d_%H%M%S')
OUT="appservice_tls_${TS}.csv"
echo "SubscriptionName,SubscriptionId,ResourceGroup,SiteName,Kind,MinimumTlsVersion,FtpsState,HttpsOnly,IsCompliant" > "$OUT"

for SUB in $(az account list --query "[].id" -o tsv); do
  SUBNAME=$(az account show --subscription "$SUB" --query "name" -o tsv)
  echo "=== Checking subscription: $SUBNAME ($SUB) ==="
  az account set --subscription "$SUB"
  
  WEBAPPS=$(az webapp list -o json 2>/dev/null)
  
  if [ "$WEBAPPS" = "[]" ] || [ -z "$WEBAPPS" ]; then
    echo "Inga App Service-appar funna i denna subscription."
    continue
  fi
  
  TMP_OUT=$(mktemp)
  
  echo "$WEBAPPS" | python3 -c "
import sys, json, subprocess

subname = '''$SUBNAME'''
subid = '''$SUB'''

apps = json.load(sys.stdin)
for app in apps:
    app_id = app.get('id', '')
    app_name = app.get('name', 'unknown')
    app_rg = app.get('resourceGroup', 'unknown')
    app_kind = (app.get('kind') or 'null').replace(' ', '_').replace(',', '_')
    https_only = str(app.get('httpsOnly', False)).lower()
    
    try:
        config = subprocess.check_output(
            ['az', 'webapp', 'config', 'show', '--ids', app_id, '--query', '[minTlsVersion, ftpsState]', '-o', 'tsv'],
            stderr=subprocess.DEVNULL, text=True
        ).strip().split('\t')
        min_tls = config[0] if len(config) > 0 and config[0] else 'null'
        ftps_state = config[1] if len(config) > 1 and config[1] else 'null'
    except:
        min_tls = 'null'
        ftps_state = 'null'
    
    compliant = 'true' if min_tls in ['1.2', '1_2', 'TLS1_2'] and https_only == 'true' else 'false'
    
    print('{},{},{},{},{},{},{},{},{}'.format(subname, subid, app_rg, app_name, app_kind, min_tls, ftps_state, https_only, compliant))
" > "$TMP_OUT"
  
  (
    echo "SubscriptionName,SubscriptionId,ResourceGroup,SiteName,Kind,MinimumTlsVersion,FtpsState,HttpsOnly,IsCompliant"
    cat "$TMP_OUT"
  ) | column -t -s','
  
  cat "$TMP_OUT" >> "$OUT"
  rm -f "$TMP_OUT"
  
done

echo ""
echo "Export klar: $OUT"
EOFSCRIPT
