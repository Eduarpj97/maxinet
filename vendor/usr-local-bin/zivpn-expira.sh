#!/bin/bash
# zivpn-expira.sh — elimina contraseñas vencidas automáticamente
EXP_FILE="/etc/zivpn/expira.conf"
CONFIG="/etc/zivpn/config.json"
NOW=$(date +%s)
[[ -f "$EXP_FILE" ]] || exit 0
CHANGED=0
while IFS='|' read -r PASS EXP; do
    [[ -z "$PASS" ]] && continue
    if [[ "$EXP" != "0" && -n "$EXP" && "$EXP" -le "$NOW" ]]; then
        jq --arg p "$PASS" '.auth.config |= map(select(. != $p))' "$CONFIG" > /tmp/zivpn-exp.json && mv /tmp/zivpn-exp.json "$CONFIG"
        awk -F'|' -v p="$PASS" '$1!=p' "$EXP_FILE" > /tmp/zivpn-exp.tmp && mv /tmp/zivpn-exp.tmp "$EXP_FILE"
        CHANGED=1
    fi
done < "$EXP_FILE"
[[ "$CHANGED" -eq 1 ]] && systemctl restart zivpn
exit 0
