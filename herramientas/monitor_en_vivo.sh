#!/bin/bash
#==================================================
# Maxinet Network Premium v2.5
# Monitor Conectados (En Vivo) · 100% Datos Reales
# Monitoreo pasivo (nf_conntrack / sockets / journal)
#==================================================

export LC_ALL=C.UTF-8 2>/dev/null
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
DB_USERS="$BASE/usuarios.db"
ZIVPN_CONEX="$DIR_ZIVPN/conexiones.db"
[[ -z "$DIR_ZIVPN" ]] && DIR_ZIVPN="/etc/zivpn"
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null

mkdir -p "$BASE" 2>/dev/null
touch "$DB_USERS" 2>/dev/null

# Paleta ANSI / Nebula
CY="\033[1;36m"
BL="\033[1;34m"
GR="\033[1;32m"
YW="\033[1;33m"
RD="\033[1;31m"
WH="\033[1;37m"
GY="\033[38;5;245m"
GD="\033[38;5;220m"
RST="\033[0m"

_abb_rep() {
    local c="$1" n="$2" out=""
    while (( n-- > 0 )); do out+="$c"; done
    printf '%s' "$out"
}

_abb_celda() {
    local s="${1:-}" ancho="${2:-10}" n
    n=${#s}
    if (( n > ancho )); then
        s="${s:0:ancho}"
        n=$ancho
    fi
    if (( n < ancho )); then
        printf '%s%*s' "$s" $(( ancho - n )) ''
    else
        printf '%s' "$s"
    fi
}

_fmt_bytes() {
    local bytes="$1"
    [[ -z "$bytes" || "$bytes" -le 0 ]] && { echo "0.0 MB"; return; }
    if [[ "$bytes" -ge 1073741824 ]]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes / 1073741824}"
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk "BEGIN {printf \"%.1f MB\", $bytes / 1048576}"
    elif [[ "$bytes" -ge 1024 ]]; then
        awk "BEGIN {printf \"%.1f KB\", $bytes / 1024}"
    else
        echo "${bytes} B"
    fi
}

activar_servicio_monitor() {
    cat > /etc/systemd/system/maxinet-monitor.service << 'EOF'
[Unit]
Description=Maxinet Connection Limits & Watchdog Daemon
After=network.target

[Service]
Type=simple
User=root
ExecStart=/bin/bash -c "while true; do /etc/maxinet/herramientas/monitor_en_vivo.sh --check; sleep 15; done"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable maxinet-monitor.service >/dev/null 2>&1
    systemctl restart maxinet-monitor.service >/dev/null 2>&1
    echo -e " ${GR}✔${RST} Vigilante de conexiones activado (revisa cada 15 segundos)."
}

detener_servicio_monitor() {
    systemctl stop maxinet-monitor.service >/dev/null 2>&1
    systemctl disable maxinet-monitor.service >/dev/null 2>&1
    echo -e " ${RD}✔${RST} Vigilante detenido."
}

verificar_y_limpiar() {
    # Expulsar usuarios excedidos según DB_USERS (usuario:clave:expira:limite)
    [[ ! -f "$DB_USERS" ]] && return 0
    local HOY=$(date +%Y-%m-%d)
    while IFS=: read -r u pass exp lim; do
        [[ -z "$u" ]] && continue
        # Vencido
        if [[ -n "$exp" && "$exp" != "null" && "$exp" != "Ilimitado" && "$HOY" > "$exp" ]]; then
            pkill -u "$u" -9 2>/dev/null
            usermod -L "$u" 2>/dev/null
        fi
        # Límite simultáneo excedido
        if [[ "$lim" =~ ^[0-9]+$ ]] && [[ "$lim" -gt 0 ]]; then
            local PIDS
            PIDS=$(ps -u "$u" -o pid= 2>/dev/null)
            local N=$(echo "$PIDS" | grep -c '[0-9]')
            if (( N > lim )); then
                # Matar excedentes más recientes
                echo "$PIDS" | tail -n +$((lim + 1)) | xargs -r kill -9 2>/dev/null
            fi
        fi
    done < "$DB_USERS"
}

if [[ "${1:-}" == "--check" ]]; then
    verificar_y_limpiar
    exit 0
fi

mostrar_pantalla_monitor() {
    clear
    local ARCH=$(uname -m)
    local RAM_U=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%.0f%%", $3*100/$2}')
    local CPU_U=$(top -bn1 2>/dev/null | awk -F'id,' '/Cpu/ {split($1,a,","); printf("%.0f%%",100-a[length(a)])}')
    [[ -z "$CPU_U" ]] && CPU_U="0%"
    local IP_PUB=$(cat "$BASE/.pub_ip" 2>/dev/null || curl -4 -s --max-time 2 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    local DOMINIO=$(cat "$BASE/dominio" 2>/dev/null || echo "${IP_PUB:-127.0.0.1}")

    echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
    echo -e "       ${GD}★${RST} ${WH}MAXINET NETWORK · MONITOR CONECTADOS (EN VIVO)${RST} ${CY}v2.5${RST} ${GD}★${RST}"
    echo -e "${BL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
    echo -e "  ${GD}◆${RST} ${CY}Host:${RST} ${WH}$DOMINIO${RST} (${IP_PUB})  ${GD}◆${RST} ${CY}RAM:${RST} ${WH}$RAM_U${RST}  ${GD}◆${RST} ${CY}CPU:${RST} ${WH}$CPU_U${RST}  ${GD}◆${RST} ${CY}Arch:${RST} ${WH}$ARCH${RST}"

    local WATCH_STATUS="${RD}○ INACTIVO${RST}"
    if systemctl is-active --quiet maxinet-monitor.service 2>/dev/null; then
        WATCH_STATUS="${GR}● ACTIVO (15s)${RST}"
    fi
    echo -e "  ${GD}◆${RST} ${CY}Vigilante de Límites:${RST} $WATCH_STATUS"
    echo -e "${BL}──────────────────────────────────────────────────────────────────────────────${RST}"
    echo ""

    # 1. Sesiones SSH / Dropbear
    echo -e "  ${GD}👥 SESIONES SSH & DROPBEAR EN VIVO${RST}"
    local TOP="┌$(_abb_rep '─' 18)┬$(_abb_rep '─' 20)┬$(_abb_rep '─' 16)┬$(_abb_rep '─' 18)┐"
    local MID="├$(_abb_rep '─' 18)┼$(_abb_rep '─' 20)┼$(_abb_rep '─' 16)┼$(_abb_rep '─' 18)┤"
    local BOT="└$(_abb_rep '─' 18)┴$(_abb_rep '─' 20)┴$(_abb_rep '─' 16)┴$(_abb_rep '─' 18)┘"

    echo -e "   ${GY}${TOP}${RST}"
    printf "   ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST}\n" \
        "$(_abb_celda 'USUARIO' 16)" "$(_abb_celda 'IP ORIGEN' 18)" "$(_abb_celda 'PROTOCOLO' 14)" "$(_abb_celda 'ESTADO' 16)"
    echo -e "   ${GY}${MID}${RST}"

    local HAY_SSH=0
    # OpenSSH
    while read -r pid u ip; do
        [[ -z "$u" || "$u" == "root" ]] && continue
        printf "   ${GY}│${RST} ${GR}%s${RST} ${GY}│${RST} ${YW}%s${RST} ${GY}│${RST} ${CY}%s${RST} ${GY}│${RST} ${GR}%s${RST} ${GY}│${RST}\n" \
            "$(_abb_celda "$u" 16)" "$(_abb_celda "$ip" 18)" "$(_abb_celda 'OpenSSH' 14)" "$(_abb_celda '● Conectado' 16)"
        HAY_SSH=1
    done < <(ps -eo pid,user,args 2>/dev/null | grep "sshd:" | grep "@" | awk '{print $1, $2, $NF}' | sed 's/[()]//g')

    # Dropbear
    while read -r pid u ip; do
        [[ -z "$u" ]] && continue
        printf "   ${GY}│${RST} ${GR}%s${RST} ${GY}│${RST} ${YW}%s${RST} ${GY}│${RST} ${CY}%s${RST} ${GY}│${RST} ${GR}%s${RST} ${GY}│${RST}\n" \
            "$(_abb_celda "$u" 16)" "$(_abb_celda "$ip" 18)" "$(_abb_celda 'Dropbear' 14)" "$(_abb_celda '● Conectado' 16)"
        HAY_SSH=1
    done < <(ps -eo pid,user,args 2>/dev/null | grep -E "dropbear.*\[[0-9]+\]" | awk '{print $1, $NF, "dropbear"}')

    if [[ "$HAY_SSH" -eq 0 ]]; then
        printf "   ${GY}│${RST} %-74s ${GY}│${RST}\n" "           (Sin usuarios SSH conectados en este momento)"
    fi
    echo -e "   ${GY}${BOT}${RST}"
    echo ""

    # 2. Túneles UDP & ZiVPN
    echo -e "  ${GD}⚡ TÚNELES UDP CUSTOM & ZIVPN${RST}"
    echo -e "   ${GY}${TOP}${RST}"
    printf "   ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST}\n" \
        "$(_abb_celda 'CLAVE / USUARIO' 16)" "$(_abb_celda 'IP REMOTA' 18)" "$(_abb_celda 'PUERTO UDP' 14)" "$(_abb_celda 'ESTADO' 16)"
    echo -e "   ${GY}${MID}${RST}"

    local HAY_UDP=0
    # ZiVPN en conexiones.db
    if [[ -s "$DIR_ZIVPN/conexiones.db" ]]; then
        while IFS='|' read -r fecha addr auth tx res; do
            [[ "$res" != "ok" ]] && continue
            printf "   ${GY}│${RST} ${YW}%s${RST} ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST} ${CY}%s${RST} ${GY}│${RST} ${GR}%s${RST} ${GY}│${RST}\n" \
                "$(_abb_celda "$auth" 16)" "$(_abb_celda "$addr" 18)" "$(_abb_celda 'ZiVPN (5667)' 14)" "$(_abb_celda '● Activo' 16)"
            HAY_UDP=1
        done < <(tail -n 10 "$DIR_ZIVPN/conexiones.db")
    fi

    # UDP Custom sockets
    local UDP_SOCKS
    UDP_SOCKS=$(ss -unp 2>/dev/null | grep -E ":36712|udp-custom")
    if [[ -n "$UDP_SOCKS" ]]; then
        while read -r line; do
            local rem_ip=$(echo "$line" | awk '{print $5}')
            printf "   ${GY}│${RST} ${YW}%s${RST} ${GY}│${RST} ${WH}%s${RST} ${GY}│${RST} ${CY}%s${RST} ${GY}│${RST} ${GR}%s${RST} ${GY}│${RST}\n" \
                "$(_abb_celda 'UDP-Client' 16)" "$(_abb_celda "$rem_ip" 18)" "$(_abb_celda 'UDP (36712)' 14)" "$(_abb_celda '● Flujo UDP' 16)"
            HAY_UDP=1
        done <<< "$UDP_SOCKS"
    fi

    if [[ "$HAY_UDP" -eq 0 ]]; then
        printf "   ${GY}│${RST} %-74s ${GY}│${RST}\n" "           (Sin flujos UDP / ZiVPN activos en este instante)"
    fi
    echo -e "   ${GY}${BOT}${RST}"
    echo ""
}

# Bucle interactivo
while true; do
    mostrar_pantalla_monitor
    echo -e "  ${CY}[ENTER]${RST} Refrescar  ·  ${CY}[1]${RST} Activar Vigilante  ·  ${CY}[2]${RST} Detener Vigilante  ·  ${CY}[3]${RST} Depurar  ·  ${RD}[0]${RST} Volver"
    echo ""
    read -rp "  » Opción: " OPC_M
    case "$OPC_M" in
        1) activar_servicio_monitor; sleep 2 ;;
        2) detener_servicio_monitor; sleep 2 ;;
        3) verificar_y_limpiar; echo -e " ${GR}✔${RST} Verificación completada."; sleep 2 ;;
        0) break ;;
        *) ;;
    esac
done
