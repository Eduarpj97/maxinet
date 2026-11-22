#!/bin/bash
# zivpn-limite.sh - control de trafico por IP para ZipVPN
# Sin API de stats por contrasena en udp-zivpn: se mide por IP conectada
# y se bloquea la IP que supera la cuota minima configurada.
CONF="/etc/zivpn/config.json"
LIM_FILE="/etc/zivpn/limites.conf"
CONS_FILE="/etc/zivpn/consumo.conf"
BLOQ_FILE="/etc/zivpn/bloqueadas.txt"
SNAP_FILE="/etc/zivpn/snapshot.conf"
LOG="/etc/zivpn/zivpn-limite.log"
PORT=$(jq -r '.listen' "$CONF" 2>/dev/null | tr -d ':')
[[ -z "$PORT" || "$PORT" == "null" ]] && exit 0

# Cuota minima > 0 configurada
CUOTA=0
[[ -f "$LIM_FILE" ]] && CUOTA=$(awk -F'|' '$2>0 && ($2<CUOTA || CUOTA==0){CUOTA=$2} END{print CUOTA+0}' "$LIM_FILE")
[[ "$CUOTA" -eq 0 ]] && exit 0

LIMIT_BYTES=$((CUOTA * 1073741824))

# Limpiar reglas DROP de IPs que ya no estan activas
if [[ -f "$BLOQ_FILE" ]]; then
    ACTIVE=$(conntrack -L -p udp --dport "$PORT" 2>/dev/null | grep -o 'src=[0-9.]*' | cut -d= -f2 | sort -u)
    while read -r IP; do
        [[ -z "$IP" ]] && continue
        if ! echo "$ACTIVE" | grep -qx "$IP"; then
            iptables -D INPUT -s "$IP" -j DROP 2>/dev/null
            iptables -D OUTPUT -d "$IP" -j DROP 2>/dev/null
            awk -v p="$IP" '$1!=p' "$BLOQ_FILE" > /tmp/zb.tmp 2>/dev/null && mv /tmp/zb.tmp "$BLOQ_FILE"
            rm -f "/etc/zivpn/consumo/$IP.txt"
            echo "$(date '+%F %T') desbloqueada $IP (desconectada)" >> "$LOG"
        fi
    done < "$BLOQ_FILE"
fi

# IPs activas conectadas al puerto
mapfile -t IPS < <(conntrack -L -p udp --dport "$PORT" 2>/dev/null | grep -o 'src=[0-9.]*' | cut -d= -f2 | sort -u)
[[ ${#IPS[@]} -eq 0 ]] && exit 0

touch "$SNAP_FILE" "$CONS_FILE"

for IP in "${IPS[@]}"; do
    # Contar si ya esta bloqueada
    if grep -qx "$IP" "$BLOQ_FILE" 2>/dev/null; then
        continue
    fi
    # Reglas contadoras (no cambian politica)
    iptables -C INPUT -s "$IP" -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -s "$IP" -p udp --dport "$PORT" -j ACCEPT
    iptables -C OUTPUT -d "$IP" -j ACCEPT 2>/dev/null || iptables -I OUTPUT -d "$IP" -j ACCEPT
    # Bytes actuales
    CUR=$(iptables -L INPUT -v -x -n | awk -v ip="$IP" -v pt="$PORT" '$8==ip && $11=="dpt:"pt {s+=$2} END{print s+0}')
    CUR2=$(iptables -L OUTPUT -v -x -n | awk -v ip="$IP" '$7==ip {s+=$2} END{print s+0}')
    CUR=$((CUR + CUR2))
    # Snapshot previo
    PREV=$(awk -F'|' -v ip="$IP" '$1==ip {print $2; exit}' "$SNAP_FILE" 2>/dev/null)
    PREV=${PREV:-0}
    DELTA=$((CUR - PREV))
    [[ $DELTA -lt 0 ]] && DELTA=$((CUR))
    # Acumular
    ACC=$(awk -F'|' -v ip="$IP" '$1==ip {print $2; exit}' "$CONS_FILE" 2>/dev/null)
    ACC=${ACC:-0}
    NEW=$((ACC + DELTA))
    awk -F'|' -v ip="$IP" '$1!=ip' "$CONS_FILE" > /tmp/zc.tmp 2>/dev/null && echo "${IP}|${NEW}" >> /tmp/zc.tmp && mv /tmp/zc.tmp "$CONS_FILE"
    awk -F'|' -v ip="$IP" '$1!=ip' "$SNAP_FILE" > /tmp/zs.tmp 2>/dev/null && echo "${IP}|${CUR}" >> /tmp/zs.tmp && mv /tmp/zs.tmp "$SNAP_FILE"
    # Bloquear si supera la cuota
    if [[ "$NEW" -gt "$LIMIT_BYTES" ]]; then
        iptables -I INPUT -s "$IP" -j DROP 2>/dev/null
        iptables -I OUTPUT -d "$IP" -j DROP 2>/dev/null
        echo "$IP" >> "$BLOQ_FILE"
        GB=$(awk -v b="$NEW" 'BEGIN{printf "%.2f", b/1073741824}')
        echo "$(date '+%F %T') BLOQUEADA $IP por superar cuota ($GB GB / $CUOTA GB)" >> "$LOG"
    fi
done
exit 0
