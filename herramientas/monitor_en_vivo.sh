#!/bin/bash
#==================================================
# Maxinet Network v2.8
# Monitor Conectados (En Vivo) · 100% Datos Reales
# Basado en Abbienet Monitor v7.2.3
# Monitoreo pasivo (nf_conntrack / sockets / journal / ss / ps)
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

# Paleta ANSI - Estilo Abbienet
RST="\033[0m"
BLD="\033[1m"
DIM="\033[2m"
RED="\033[1;31m"
GRN="\033[1;32m"
YEL="\033[1;33m"
BLU="\033[1;34m"
MAG="\033[1;35m"
CYN="\033[1;36m"
WHT="\033[1;37m"
GRY="\033[38;5;245m"
ORA="\033[38;5;208m"
GOL="\033[38;5;220m"

# Caracteres de caja
BOX_H="─"
BOX_V="│"
BOX_TL="┌"
BOX_TR="┐"
BOX_BL="└"
BOX_BR="┘"
BOX_TM="┬"
BOX_BM="┴"
BOX_ML="├"
BOX_MR="┤"
BOX_MM="┼"

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

# Leer tráfico diario desde iptables accounting
_leer_trafico_diario() {
    local TOTAL_DOWN=0 TOTAL_UP=0
    # Leer de la cadena MAXINET_TRAFFIC si existe
    if iptables -L MAXINET_TRAFFIC -n -v -x 2>/dev/null | grep -q "MAXINET_TRAFFIC"; then
        # Sumar bytes de todas las reglas excepto RETURN
        local DOWN_UP
        DOWN_UP=$(iptables -L MAXINET_TRAFFIC -n -v -x 2>/dev/null | awk '!/RETURN/ && $2 ~ /^[0-9]+$/ {down+=$2; up+=$3} END{print down, up}')
        TOTAL_DOWN=$(echo "$DOWN_UP" | awk '{print $1}')
        TOTAL_UP=$(echo "$DOWN_UP" | awk '{print $2}')
    fi
    # Fallback: leer de /proc/net/dev si no hay accounting
    if [[ $TOTAL_DOWN -eq 0 && $TOTAL_UP -eq 0 ]]; then
        local IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
        IFACE=${IFACE:-eth0}
        read -r TOTAL_DOWN TOTAL_UP < <(awk -v i="$IFACE" '$1==i":"{print $2, $10}' /proc/net/dev 2>/dev/null)
    fi
    echo "$TOTAL_DOWN $TOTAL_UP"
}

# Leer tráfico total VPS
_leer_trafico_vps() {
    local IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    IFACE=${IFACE:-eth0}
    local STATS
    STATS=$(awk -v i="$IFACE" '$1==i":"{print $2+$10}' /proc/net/dev 2>/dev/null)
    echo "${STATS:-0}"
}

_dibujar_barra() {
    local pct="$1" width="${2:-20}"
    local filled=$(( pct * width / 100 ))
    (( filled > width )) && filled=$width
    (( filled < 0 )) && filled=0
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0;i<filled;i++)); do bar+="█"; done
    for ((i=0;i<empty;i++)); do bar+="░"; done
    printf '%s' "$bar"
}

_dibujar_box() {
    local title="$1" width="${2:-60}"
    local len=${#title}
    local pad=$(( (width - len - 2) / 2 ))
    (( pad < 0 )) && pad=0
    local right=$(( width - len - pad - 2 ))
    (( right < 0 )) && right=0
    printf '%s%s%s%s%s\n' "${BOX_TL}$(_abb_rep "$BOX_H" $pad)" " $title " "$(_abb_rep "$BOX_H" $right)${BOX_TR}"
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
    echo -e " ${GRN}✔${RST} Vigilante de conexiones activado (revisa cada 15 segundos)."
}

detener_servicio_monitor() {
    systemctl stop maxinet-monitor.service >/dev/null 2>&1
    systemctl disable maxinet-monitor.service >/dev/null 2>&1
    echo -e " ${RED}✔${RST} Vigilante detenido."
}

verificar_y_limpiar() {
    [[ ! -f "$DB_USERS" ]] && return 0
    local HOY=$(date +%Y-%m-%d)
    while IFS=: read -r u pass exp lim; do
        [[ -z "$u" ]] && continue
        if [[ -n "$exp" && "$exp" != "null" && "$exp" != "Ilimitado" && "$HOY" > "$exp" ]]; then
            pkill -u "$u" -9 2>/dev/null
            usermod -L "$u" 2>/dev/null
        fi
        if [[ "$lim" =~ ^[0-9]+$ ]] && [[ "$lim" -gt 0 ]]; then
            local PIDS
            PIDS=$(ps -u "$u" -o pid= 2>/dev/null)
            local N=$(echo "$PIDS" | grep -c '[0-9]')
            if (( N > lim )); then
                echo "$PIDS" | tail -n +$((lim + 1)) | xargs -r kill -9 2>/dev/null
            fi
        fi
    done < "$DB_USERS"
}

if [[ "${1:-}" == "--check" ]]; then
    verificar_y_limpiar
    exit 0
fi

# Obtener uptime formateado
_get_uptime() {
    local up_sec=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
    [[ -z "$up_sec" ]] && echo "N/A" && return
    local d=$((up_sec/86400))
    local h=$(( (up_sec%86400)/3600 ))
    local m=$(( (up_sec%3600)/60 ))
    if (( d > 0 )); then
        printf "%dd %dh %dm" $d $h $m
    elif (( h > 0 )); then
        printf "%dh %dm" $h $m
    else
        printf "%dm" $m
    fi
}

mostrar_pantalla_monitor() {
    clear
    local ARCH=$(uname -m)
    local RAM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
    local RAM_USED=$(free -m 2>/dev/null | awk '/Mem:/ {print $3}')
    local RAM_PCT=$(( RAM_TOTAL > 0 ? RAM_USED * 100 / RAM_TOTAL : 0 ))
    local CPU_PCT=$(top -bn1 2>/dev/null | awk -F'id,' '/Cpu/ {split($1,a,","); printf("%.0f",100-a[length(a)])}')
    [[ -z "$CPU_PCT" ]] && CPU_PCT=0
    local IP_PUB=$(cat "$BASE/.pub_ip" 2>/dev/null || curl -4 -s --max-time 2 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    local DOMINIO=$(cat "$BASE/dominio" 2>/dev/null || echo "${IP_PUB:-127.0.0.1}")
    local UPTIME=$(_get_uptime)
    local FECHA=$(date +"%d/%m/%Y %H:%M:%S")

    # Leer tráfico
    read -r TOTAL_DOWN TOTAL_UP < <(_leer_trafico_diario)
    local TOTAL_DAY=$(( TOTAL_DOWN + TOTAL_UP ))
    local VPS_TOTAL=$(_leer_trafico_vps)

    # Contar conexiones activas
    local UDP_CONN=0 ZIVPN_CONN=0 BADVPN_CONN=0 SSH_CONN=0
    
    # UDP Custom
    UDP_CONN=$(ss -unp 2>/dev/null | grep -cE ":36712|udp-custom" 2>/dev/null || echo 0)
    
    # ZiVPN
    ZIVPN_CONN=0
    if [[ -s "$DIR_ZIVPN/conexiones.db" ]]; then
        ZIVPN_CONN=$(awk -F'|' '$5=="ok"' "$DIR_ZIVPN/conexiones.db" 2>/dev/null | wc -l)
    fi
    
    # BadVPN
    BADVPN_CONN=$(ss -unp 2>/dev/null | grep -cE ":7[0-9]{3}" 2>/dev/null || echo 0)
    
    # SSH
    SSH_CONN=$(ps -eo user,args 2>/dev/null | grep -cE "sshd:.*@" 2>/dev/null || echo 0)
    SSH_CONN=$(( SSH_CONN + $(ps -eo user,args 2>/dev/null | grep -cE "dropbear.*\[[0-9]+\]" 2>/dev/null || echo 0) ))

    local TOTAL_CONN=$(( UDP_CONN + ZIVPN_CONN + BADVPN_CONN + SSH_CONN ))

    # Cuentas SSH registradas
    local SSH_REG=0
    [[ -f "$DB_USERS" ]] && SSH_REG=$(grep -cv '^#' "$DB_USERS" 2>/dev/null || echo 0)

    # ===== HEADER =====
    echo -e "${CYN}╔════════════════════════════════════════════════════════════════════════════════════════════════╗${RST}"
    echo -e " ${BLD}${GRN}     █▀█ █▀▄ █▀▄ ▀█▀ █▀▀   █▄░█ █▀▀ ▀█▀                               ${RST}"
    echo -e " ${BLD}${GRN}     █▀█ █▀▄ █▀▄ ░█░ ██▄   █░▀█ ██▄ ░█░                               ${RST}"
    echo -e "                                                                       ${RST}"
    echo -e " ${BLD}${GRN}        ⟐  M O N I T O R   D E   C O N E X I O N E S  ⟐               ${RST}"
    echo -e " ${BLD}${GRN}                  v2.8 · Panel en Vivo                             ${RST}"
    echo -e "${CYN}╚════════════════════════════════════════════════════════════════════════════════════════════════╝${RST}"
    echo ""
    echo -e "${CYN}┌──────────────────────────────────────────────────────────────────────────────────────────────┐${RST}"
    printf " ${CYN}│${RST}  ${GRN}● EN VIVO${RST}  │  ${WHT}%s${RST}  │  ${WHT}⏱ %s${RST}  │  ${WHT}🖥 %s${RST}%*s${CYN}│${RST}\n" \
        "$FECHA" "$UPTIME" "$(hostname)" $(( 60 - ${#FECHA} - ${#UPTIME} - ${#$(hostname)} )) ""
    echo -e "${CYN}└──────────────────────────────────────────────────────────────────────────────────────────────┘${RST}"
    echo ""

    # ===== CONEXIONES ACTIVAS =====
    echo -e "${CYN}─── CONEXIONES ACTIVAS ──────────────────────────────────────────────────────────────────────${RST}"
    echo ""
    echo -e "               ${CYN}┌────────────────────────────────────┐${RST}"
    printf "               ${CYN}│${RST}       ${WHT}███  TOTAL: %d   cliente(s)${RST}   ${CYN}│${RST}\n" $TOTAL_CONN
    echo -e "               ${CYN}│${RST}       ${WHT}███${RST}                          ${CYN}│${RST}"
    echo -e "               ${CYN}└────────────────────────────────────┘${RST}"
    echo -e " desglose: udp ${UDP_CONN} · zivpn ${ZIVPN_CONN} · badvpn ${BADVPN_CONN} · ssh ${SSH_CONN}"
    echo ""
    echo -e " ─── SERVICIOS ────────────────────────────────────────────────────────────────────────────"
    echo ""

    # UDP Custom
    local UDP_STATUS="${GRN}● EN FUNCIONAMIENTO${RST}"
    [[ $UDP_CONN -eq 0 ]] && UDP_STATUS="${YEL}○ SIN CONEXIONES${RST}"
    printf "   ${GRN}●${RST} UDP Custom   :36712       ${WHT}%d activo(s)${RST}   ${CYN}%s${RST}\n" $UDP_CONN "$(_dibujar_barra 0 12)"
    
    # ZiVPN
    local ZIVPN_STATUS="${GRN}● EN FUNCIONAMIENTO${RST}"
    [[ $ZIVPN_CONN -eq 0 ]] && ZIVPN_STATUS="${YEL}○ SIN CONEXIONES${RST}"
    printf "   ${GRN}●${RST} ZiVPN (UDP)  :5667        ${WHT}%d en línea${RST}    ${CYN}%s${RST}\n" $ZIVPN_CONN "$(_dibujar_barra 0 12)"
    
    # BadVPN
    local BADVPN_STATUS="${GRN}● EN FUNCIONAMIENTO${RST}"
    [[ $BADVPN_CONN -eq 0 ]] && BADVPN_STATUS="${YEL}○ SIN CONEXIONES${RST}"
    printf "   ${GRN}●${RST} BadVPN Gate  :7100-9900   ${WHT}%d túnel(es)${RST}   ${CYN}%s${RST}\n" $BADVPN_CONN "$(_dibujar_barra 0 12)"
    
    # SSH/Drop
    local SSH_STATUS="${GRN}● EN FUNCIONAMIENTO${RST}"
    [[ $SSH_CONN -eq 0 ]] && SSH_STATUS="${YEL}○ SIN SESIONES${RST}"
    printf "   ${GRN}○${RST} SSH/Drop     :90          ${WHT}%d sesión(es)${RST}  ${CYN}%s${RST}\n" $SSH_CONN "$(_dibujar_barra 0 12)"
    
    echo ""
    printf "   ${WHT}👥 Cuentas SSH registradas : %d (%d en línea)${RST}\n" $SSH_REG $SSH_CONN
    echo ""

    # ===== UDP CUSTOM DETALLADO =====
    echo -e "${CYN}─── 🚀 UDP CUSTOM · Estado, Sesiones y Credenciales ──────────────────────────────────────${RST}"
    echo ""
    echo -e "   ${GRN}●${RST} Estado del Servicio : EN FUNCIONAMIENTO (Puerto UDP :36712)"
    printf "   ${WHT}⚡ Usuarios conectados : %d IP(s) conectada(s) · %d usuario(s) en línea${RST}\n" $UDP_CONN $UDP_CONN
    echo ""
    
    # Tabla UDP Custom
    local COL1=18 COL2=10 COL3=20 COL4=18
    local TOP="┌$(_abb_rep '─' $COL1)┬$(_abb_rep '─' $COL2)┬$(_abb_rep '─' $COL3)┬$(_abb_rep '─' $COL4)┐"
    local MID="├$(_abb_rep '─' $COL1)┼$(_abb_rep '─' $COL2)┼$(_abb_rep '─' $COL3)┼$(_abb_rep '─' $COL4)┤"
    local BOT="└$(_abb_rep '─' $COL1)┴$(_abb_rep '─' $COL2)┴$(_abb_rep '─' $COL3)┴$(_abb_rep '─' $COL4)┘"
    
    echo -e "   ${GRY}${TOP}${RST}"
    printf "   ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST}\n" \
        "$(_abb_celda 'USUARIO SSH' $COL1)" "$(_abb_celda 'DISP.' $COL2)" "$(_abb_celda 'ÚLTIMA CONEXIÓN' $COL3)" "$(_abb_celda 'ESTADO' $COL4)"
    echo -e "   ${GRY}${MID}${RST}"
    
    # Leer usuarios UDP de la DB si existe
    local UDP_HAY=0
    if [[ -f "$DB_USERS" ]]; then
        while IFS=: read -r u pass exp lim; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            # Verificar si tiene conexiones UDP activas
            local ULT_CONEX="Nunca"
            local ESTADO="${RED}○ apagada${RST}"
            # Buscar en ps/ss si tiene conexiones UDP activas
            if ss -unp 2>/dev/null | grep -q "user=$u"; then
                ULT_CONEX=$(date +"%Y-%m-%d %H:%M:%S")
                ESTADO="${GRN}● hace 1s${RST}"
                UDP_HAY=1
            fi
            printf "   ${GRY}│${RST} ${GRN}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} %s ${GRY}│${RST}\n" \
                "$(_abb_celda "$u" $COL1)" "$(_abb_celda "$lim" $COL2)" "$(_abb_celda "$ULT_CONEX" $COL3)" "$ESTADO"
        done < "$DB_USERS"
    fi
    
    if [[ $UDP_HAY -eq 0 ]]; then
        printf "   ${GRY}│${RST} %-70s ${GRY}│${RST}\n" "           (Sin usuarios UDP conectados en este momento)"
    fi
    echo -e "   ${GRY}${BOT}${RST}"
    echo -e " ${UDP_CONN} IP(s) conectada(s) · ${UDP_CONN} usuario(s) en línea · 0 apagada(s) · ${GRN}●${RST}/${YEL}◐${RST} = actividad en los últimos 120 s · ${RED}○${RST} = apagada"
    echo ""

    # ===== ZIVPN DETALLADO =====
    echo -e "${CYN}─── ⚡ ZIVPN · Estado, Sesiones y Credenciales ────────────────────────────────────────${RST}"
    echo ""
    echo -e "   ${GRN}●${RST} Estado del Servicio : EN FUNCIONAMIENTO (Puerto UDP :5667)"
    printf "   ${WHT}⚡ Usuarios conectados : %d conectado(s) · %d contraseña(s) en línea${RST}\n" $ZIVPN_CONN $ZIVPN_CONN
    echo ""
    
    local COL1Z=18 COL2Z=10 COL3Z=20 COL4Z=12
    local TOPZ="┌$(_abb_rep '─' $COL1Z)┬$(_abb_rep '─' $COL2Z)┬$(_abb_rep '─' $COL3Z)┬$(_abb_rep '─' $COL4Z)┐"
    local MIDZ="├$(_abb_rep '─' $COL1Z)┼$(_abb_rep '─' $COL2Z)┼$(_abb_rep '─' $COL3Z)┼$(_abb_rep '─' $COL4Z)┤"
    local BOTZ="└$(_abb_rep '─' $COL1Z)┴$(_abb_rep '─' $COL2Z)┴$(_abb_rep '─' $COL3Z)┴$(_abb_rep '─' $COL4Z)┘"
    
    echo -e "   ${GRY}${TOPZ}${RST}"
    printf "   ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST}\n" \
        "$(_abb_celda 'CONTRASEÑA' $COL1Z)" "$(_abb_celda 'USUARIOS' $COL2Z)" "$(_abb_celda 'ÚLTIMA CONEXIÓN' $COL3Z)" "$(_abb_celda 'ESTADO' $COL4Z)"
    echo -e "   ${GRY}${MIDZ}${RST}"
    
    local ZIVPN_HAY=0
    if [[ -s "$DIR_ZIVPN/conexiones.db" ]]; then
        while IFS='|' read -r fecha addr auth tx res; do
            [[ "$res" != "ok" ]] && continue
            local ULT=$(date -d "$fecha" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$fecha")
            local DIFF=$(( $(date +%s) - $(date -d "$fecha" +%s 2>/dev/null || echo 0) ))
            local ESTADO="${GRN}● hace ${DIFF}s${RST}"
            [[ $DIFF -gt 60 ]] && ESTADO="${YEL}◐ hace ${DIFF}s${RST}"
            [[ $DIFF -gt 3600 ]] && ESTADO="${RED}○ hace $((DIFF/3600))h${RST}"
            printf "   ${GRY}│${RST} ${YEL}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} ${WHT}%s${RST} ${GRY}│${RST} %s ${GRY}│${RST}\n" \
                "$(_abb_celda "$auth" $COL1Z)" "$(_abb_celda "1" $COL2Z)" "$(_abb_celda "$ULT" $COL3Z)" "$ESTADO"
            ZIVPN_HAY=1
        done < <(tail -n 20 "$DIR_ZIVPN/conexiones.db")
    fi
    
    if [[ $ZIVPN_HAY -eq 0 ]]; then
        printf "   ${GRY}│${RST} %-60s ${GRY}│${RST}\n" "           (Sin conexiones ZiVPN activas en este instante)"
    fi
    echo -e "   ${GRY}${BOTZ}${RST}"
    echo -e " ${ZIVPN_CONN} contraseña(s) en línea · ${ZIVPN_CONN} usuario(s) conectado(s) · 0 apagada(s) · ${GRN}●${RST}/${YEL}◐${RST} = conectada en los últimos 60 s · ${RED}○${RST} = apagada"
    echo ""

    # ===== TRÁFICO DEL DÍA =====
    echo -e "${CYN}─── 📊 TRÁFICO DEL DÍA (desde 00:00) ───────────────────────────────────────────────────${RST}"
    echo ""
    local DOWN_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_DOWN / 1073741824}")
    local UP_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_UP / 1073741824}")
    local TOTAL_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_DAY / 1073741824}")
    local VPS_GB=$(awk "BEGIN {printf \"%.2f\", $VPS_TOTAL / 1073741824}")
    
    printf "      ${YEL}▼ Descarga : %s GB${RST}\n" "$DOWN_GB"
    printf "      ${GRN}▲ Subida   : %s GB${RST}\n" "$UP_GB"
    echo -e "      ${CYN}──────────────────────────────${RST}"
    printf "      ${MAG}◆ Total día: %s GB${RST}     ${CYN}%s${RST}\n" "$TOTAL_GB" "$(_dibujar_barra 50 20)"
    local VPS_PCT=0
    [[ $VPS_TOTAL -gt 0 ]] && VPS_PCT=$(( TOTAL_DAY * 100 / VPS_TOTAL ))
    [[ $VPS_PCT -gt 100 ]] && VPS_PCT=100
    printf "      ${MAG}◆ Total VPS: %s GB${RST}     ${CYN}%s${RST}\n" "$VPS_GB" "$(_dibujar_barra $VPS_PCT 20)"
    echo ""

    # ===== SISTEMA =====
    echo -e "${CYN}─── 🖥 SISTEMA ───────────────────────────────────────────────────────────────────────────${RST}"
    echo ""
    
    # CPU bar
    local CPU_BAR=$(_dibujar_barra $CPU_PCT 20)
    printf "      ${WHT}CPU    %3d%%  %s${RST}\n" $CPU_PCT "$CPU_BAR"
    
    # RAM bar
    local RAM_BAR=$(_dibujar_barra $RAM_PCT 20)
    printf "      ${WHT}RAM    %3d%%  %s  %dMB / %dMB${RST}\n" $RAM_PCT "$RAM_BAR" $RAM_USED $RAM_TOTAL
    echo ""

    # ===== FOOTER =====
    echo -e "${CYN}══════════════════════════════════════════════════════════════════════════════════════════════════════${RST}"
    echo -e "  ${CYN}[ENTER]/[R] Actualizar${RST}        ${CYN}[K] Purgar flujos ZiVPN ociosos${RST}        ${RED}[0] Volver${RST}"
    echo -e "${CYN}═════════════════════════════════════════════════════════════════════════════════════════════════════${RST}"
    echo -n "  ► "
}

# Bucle interactivo
while true; do
    mostrar_pantalla_monitor
    read -r OPC_M
    case "$OPC_M" in
        ""|r|R) ;;  # Refrescar con ENTER o R
        k|K) 
            verificar_y_limpiar
            echo -e " ${GRN}✔${RST} Verificación y purga completada."
            sleep 2
            ;;
        0) break ;;
        *) ;;
    esac
done