#!/bin/bash
#==================================================
# Maxinet Network v2.10
# Monitor Conectados (En Vivo) · 100% Datos Reales
# Sin simulación: ss / conntrack / ps / proc / lastlog
#==================================================

export LC_ALL=C.UTF-8 2>/dev/null
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
DB_USERS="$BASE/usuarios.db"
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null
DIR_ZIVPN="${DIR_ZIVPN:-/etc/zivpn}"
ZIVPN_CONEX="$DIR_ZIVPN/conexiones.db"
DIR_TRAFICO="$BASE/trafico"
BASELINE="$DIR_TRAFICO/iface_dia.db"

mkdir -p "$BASE" "$DIR_TRAFICO" 2>/dev/null
touch "$DB_USERS" 2>/dev/null
# Nunca dejar rutas inexistentes que rompan redirecciones
[[ -f "$DB_USERS" ]] || DB_USERS="/dev/null"

# ── Paleta ANSI ──
RST="\033[0m"; BLD="\033[1m"; DIM="\033[2m"
RED="\033[1;31m"; GRN="\033[1;32m"; YEL="\033[1;33m"
BLU="\033[1;34m"; MAG="\033[1;35m"; CYN="\033[1;36m"; WHT="\033[1;37m"
GRY="\033[38;5;245m"; ORA="\033[38;5;208m"; GOL="\033[38;5;220m"

# ─────────────────────────────────────────────────────────────
# UTILIDADES NUMÉRICAS
# grep -c SIEMPRE imprime un número pero devuelve exit 1 cuando
# no hay coincidencias. Por eso NUNCA se usa "|| echo 0" detrás
# de un grep -c: eso genera DOS líneas ("0\n0") y rompe $(( )).
# ─────────────────────────────────────────────────────────────
_num() {
    local v="${1:-}"
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "$v"
}

_rep() {
    local c="$1" n out=""
    n=$(_num "${2:-0}")
    while (( n-- > 0 )); do out+="$c"; done
    printf '%s' "$out"
}

_celda() {
    local s="${1:-}" ancho n
    ancho=$(_num "${2:-10}")
    (( ancho < 1 )) && ancho=1
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

_barra() {
    local pct width filled empty i out=""
    pct=$(_num "${1:-0}")
    width=$(_num "${2:-20}")
    (( width < 1 )) && width=1
    (( pct > 100 )) && pct=100
    filled=$(( pct * width / 100 ))
    empty=$(( width - filled ))
    for (( i=0; i<filled; i++ )); do out+="█"; done
    for (( i=0; i<empty; i++ )); do out+="░"; done
    printf '%s' "$out"
}

_pct10() {
    local n
    n=$(_num "${1:-0}")
    (( n > 10 )) && n=10
    printf '%s' $(( n * 10 ))
}

_gb() {
    awk -v b="$(_num "${1:-0}")" 'BEGIN{printf "%.2f", b/1073741824}'
}

_sep() {
    local t="$1" pad
    pad=$(( 66 - ${#t} ))
    (( pad < 2 )) && pad=2
    printf '%b\n' "${CYN}─── ${WHT}${t}${CYN} $(_rep '─' "$pad")${RST}"
}

# ─────────────────────────────────────────────────────────────
# INTERFAZ Y TRÁFICO REAL
# ─────────────────────────────────────────────────────────────
_iface() {
    local i
    i=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$i" ]] && i=$(awk -F: '/^[a-z]/ && $1!="lo"{gsub(/ /,"",$1); print $1; exit}' /proc/net/dev 2>/dev/null)
    printf '%s' "${i:-eth0}"
}

_iface_rx() { awk -v k="$1:" '$1==k{print $2+0; exit}' /proc/net/dev 2>/dev/null; }
_iface_tx() { awk -v k="$1:" '$1==k{print $10+0; exit}' /proc/net/dev 2>/dev/null; }

_ensure_trafico() {
    [[ -d "$DIR_TRAFICO" ]] || mkdir -p "$DIR_TRAFICO" 2>/dev/null
    [[ -d "$DIR_TRAFICO" ]]
}

# Guarda la línea base del día (00:00). La llama el cron cada minuto
# y también el propio monitor, así el "hoy" es real y no "desde el boot".
_actualizar_baseline() {
    local iface hoy rx tx f_date f_rx f_tx
    iface=$(_iface)
    [[ -z "$iface" ]] && return 0
    hoy=$(date +%Y-%m-%d)
    rx=$(_num "$(_iface_rx "$iface")")
    tx=$(_num "$(_iface_tx "$iface")")
    if [[ -f "$BASELINE" ]]; then
        read -r f_date f_rx f_tx < "$BASELINE" 2>/dev/null
        [[ "$f_date" == "$hoy" ]] && return 0
    fi
    _ensure_trafico || return 0
    printf '%s %s %s\n' "$hoy" "$rx" "$tx" > "$BASELINE" 2>/dev/null
}

_trafico_dia() {
    local iface hoy rx tx f_date="" f_rx=0 f_tx=0 d_rx d_tx
    iface=$(_iface)
    hoy=$(date +%Y-%m-%d)
    rx=$(_num "$(_iface_rx "$iface")")
    tx=$(_num "$(_iface_tx "$iface")")
    if [[ -f "$BASELINE" ]]; then
        read -r f_date f_rx f_tx < "$BASELINE" 2>/dev/null
    fi
    if [[ "$f_date" != "$hoy" ]]; then
        f_rx="$rx"; f_tx="$tx"
        _ensure_trafico && printf '%s %s %s\n' "$hoy" "$rx" "$tx" > "$BASELINE" 2>/dev/null
    fi
    f_rx=$(_num "$f_rx"); f_tx=$(_num "$f_tx")
    d_rx=$(( rx - f_rx )); d_tx=$(( tx - f_tx ))
    (( d_rx < 0 )) && d_rx=0
    (( d_tx < 0 )) && d_tx=0
    printf '%s %s\n' "$d_rx" "$d_tx"
}

# ─────────────────────────────────────────────────────────────
# CONTEO REAL DE CONEXIONES
# ─────────────────────────────────────────────────────────────
_udp_clientes() {
    local puerto="$1" n=0
    if command -v conntrack >/dev/null 2>&1; then
        n=$(conntrack -L -p udp --dport "$puerto" 2>/dev/null | grep -oE 'src=[0-9.]+' | sort -u | wc -l)
    fi
    n=$(_num "$n")
    if (( n == 0 )); then
        n=$(ss -Hun 2>/dev/null | awk -v p=":$puerto" '$1=="udp" && $4 ~ p"$" {print $5}' | grep -vE '^(0\.0\.0\.0|\*|\[::\]):' | sort -u | wc -l)
        n=$(_num "$n")
    fi
    printf '%s' "$n"
}

_badvpn_conex() {
    local n
    n=$(ss -Htn state established 2>/dev/null | awk '{c=split($3,a,":"); p=a[c]; if (p ~ /^[0-9]+$/ && p >= 7100 && p <= 9900) t++} END{print t+0}')
    printf '%s' "$(_num "$n")"
}

_ssh_sesiones() {
    local a b
    a=$(ps -eo args= 2>/dev/null | grep -c 'sshd:.*@')
    b=$(ps -eo args= 2>/dev/null | grep -c 'dropbear.*\[')
    printf '%s' $(( $(_num "$a") + $(_num "$b") ))
}

_ssh_online() {
    local n
    n=$(who 2>/dev/null | wc -l)
    printf '%s' "$(_num "$n")"
}

_ts_epoch() {
    local e
    e=$(date -d "$1" +%s 2>/dev/null)
    printf '%s' "$(_num "$e")"
}

_relativo() {
    local e="$1" d
    e=$(_num "$e")
    (( e <= 0 )) && { printf '%s' "—"; return; }
    d=$(( $(date +%s) - e ))
    (( d < 0 )) && d=0
    if   (( d < 60 ));    then printf 'hace %ds' "$d"
    elif (( d < 3600 ));  then printf 'hace %dm' $(( d / 60 ))
    elif (( d < 86400 )); then printf 'hace %dh' $(( d / 3600 ))
    else                       printf 'hace %dd' $(( d / 86400 ))
    fi
}

_ultima_conexion() {
    local u="$1" raw
    raw=$(lastlog -u "$u" 2>/dev/null | tail -1)
    if [[ -z "$raw" || "$raw" == *"Never logged"* || "$raw" == *"Nunca"* || "$raw" == *"**"* ]]; then
        printf '%s' "Nunca"
        return
    fi
    raw=$(echo "$raw" | awk '{$1=""; $2=""; sub(/^[ \t]+/,""); print}')
    printf '%s' "${raw:0:19}"
}

_zivpn_resumen() {
    # salida: auth|conexiones|ultima_marca
    local db="$ZIVPN_CONEX"
    [[ -s "$db" ]] || return 0
    awk -F'|' '
        { fila[NR]=$0; if ($5=="ok") hayok=1 }
        END {
            for (i=1; i<=NR; i++) {
                n=split(fila[i], f, "|")
                if (n < 3) continue
                if (hayok && f[5] != "ok") continue
                a=f[3]; if (a=="") continue
                c[a]++
                if (f[1] > l[a]) l[a]=f[1]
            }
            for (a in c) printf "%s|%d|%s\n", a, c[a], l[a]
        }' "$db" 2>/dev/null | sort -t'|' -k3,3r
}

# ─────────────────────────────────────────────────────────────
# SERVICIO / WATCHDOG
# ─────────────────────────────────────────────────────────────
verificar_y_limpiar() {
    [[ ! -f "$DB_USERS" ]] && return 0
    local HOY u pass exp lim PIDS N
    HOY=$(date +%Y-%m-%d)
    while IFS=: read -r u pass exp lim; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        if [[ -n "$exp" && "$exp" != "null" && "$exp" != "Ilimitado" && "$HOY" > "$exp" ]]; then
            pkill -u "$u" -9 2>/dev/null
            usermod -L "$u" 2>/dev/null
        fi
        if [[ "$lim" =~ ^[0-9]+$ ]] && (( lim > 0 )); then
            PIDS=$(ps -u "$u" -o pid= 2>/dev/null)
            N=$(printf '%s\n' "$PIDS" | grep -c '[0-9]')
            N=$(_num "$N")
            if (( N > lim )); then
                printf '%s\n' "$PIDS" | tail -n +$(( lim + 1 )) | xargs -r kill -9 2>/dev/null
            fi
        fi
    done < "$DB_USERS"
}

activar_servicio_monitor() {
    mkdir -p /etc/systemd/system 2>/dev/null
    cat > /etc/systemd/system/maxinet-monitor.service << 'SVCEOF'
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
SVCEOF

    systemctl daemon-reload 2>/dev/null
    systemctl enable maxinet-monitor.service >/dev/null 2>&1
    systemctl restart maxinet-monitor.service >/dev/null 2>&1
    echo -e " ${GRN}✔${RST} Vigilante de conexiones activado (revisa cada 15 s)."
}

detener_servicio_monitor() {
    systemctl stop maxinet-monitor.service >/dev/null 2>&1
    systemctl disable maxinet-monitor.service >/dev/null 2>&1
    echo -e " ${RED}✔${RST} Vigilante detenido."
}

# ─────────────────────────────────────────────────────────────
# PANEL
# ─────────────────────────────────────────────────────────────
_get_uptime() {
    local up d h m
    up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    up=$(_num "$up")
    (( up <= 0 )) && { printf '%s' "N/A"; return; }
    d=$(( up / 86400 )); h=$(( (up % 86400) / 3600 )); m=$(( (up % 3600) / 60 ))
    if   (( d > 0 )); then printf '%dd %dh %dm' "$d" "$h" "$m"
    elif (( h > 0 )); then printf '%dh %dm' "$h" "$m"
    else                   printf '%dm' "$m"
    fi
}

mostrar_pantalla_monitor() {
    [[ -t 1 ]] && clear

    local HOSTN RAM_TOTAL RAM_USED RAM_PCT CPU_PCT UPTIME FECHA
    HOSTN=$(hostname 2>/dev/null || echo "localhost")

    RAM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/{print $2+0}')
    RAM_USED=$(free -m 2>/dev/null | awk '/Mem:/{print $3+0}')
    RAM_TOTAL=$(_num "$RAM_TOTAL"); RAM_USED=$(_num "$RAM_USED")
    RAM_PCT=0
    (( RAM_TOTAL > 0 )) && RAM_PCT=$(( RAM_USED * 100 / RAM_TOTAL ))

    CPU_PCT=$(top -bn1 2>/dev/null | awk -F',' '/Cpu\(s\)|^%Cpu/ {for(i=1;i<=NF;i++) if ($i ~ /id/) {gsub(/[^0-9.]/,"",$i); printf "%.0f", 100-$i; exit}}')
    CPU_PCT=$(_num "${CPU_PCT%%.*}")
    (( CPU_PCT > 100 )) && CPU_PCT=100

    UPTIME=$(_get_uptime)
    FECHA=$(date +"%d/%m/%Y %H:%M:%S")

    # ── Tráfico real del día ──
    _actualizar_baseline
    local TR_DIA TR_RX TR_TX
    TR_DIA=$(_trafico_dia)
    TR_RX=$(_num "$(echo "$TR_DIA" | awk '{print $1}')")
    TR_TX=$(_num "$(echo "$TR_DIA" | awk '{print $2}')")
    local TR_TOTAL=$(( TR_RX + TR_TX ))

    local IFACE VPS_TOTAL
    IFACE=$(_iface)
    VPS_TOTAL=$(( $(_num "$(_iface_rx "$IFACE")") + $(_num "$(_iface_tx "$IFACE")") ))

    # ── Conexiones reales ──
    local UDP_CONN ZIVPN_CONN ZIVPN_ACT ZIVPN_PASS BADVPN_CONN SSH_CONN TOTAL_CONN SSH_REG SSH_ON
    UDP_CONN=$(_udp_clientes 36712)
    BADVPN_CONN=$(_badvpn_conex)
    SSH_CONN=$(_ssh_sesiones)
    SSH_ON=$(_ssh_online)
    SSH_REG=$(grep -cv '^#' "$DB_USERS" 2>/dev/null)
    SSH_REG=$(_num "$SSH_REG")

    local ZIV_DATOS
    ZIV_DATOS=$(_zivpn_resumen)
    ZIVPN_CONN=$(printf '%s\n' "$ZIV_DATOS" | awk -F'|' 'NF>=2{c+=$2} END{print c+0}')
    ZIVPN_CONN=$(_num "$ZIVPN_CONN")

    local AHORA TS DIF
    AHORA=$(date +%s)
    ZIVPN_ACT=0; ZIVPN_PASS=0
    if [[ -n "$ZIV_DATOS" ]]; then
        while IFS='|' read -r zauth zcon zts; do
            [[ -z "$zauth" ]] && continue
            TS=$(_ts_epoch "$zts")
            (( TS <= 0 )) && continue
            DIF=$(( AHORA - TS ))
            if (( DIF <= 60 )); then
                ZIVPN_PASS=$(( ZIVPN_PASS + 1 ))
                ZIVPN_ACT=$(( ZIVPN_ACT + $(_num "$zcon") ))
            fi
        done <<< "$ZIV_DATOS"
    fi

    TOTAL_CONN=$(( UDP_CONN + ZIVPN_ACT + BADVPN_CONN + SSH_CONN ))

    # ═══════════════ CABECERA ═══════════════
    printf '%b\n' "${CYN}╔$(_rep '═' 72)╗${RST}"
    printf '%b\n' "${CYN}    ███╗   ███╗ █████╗ ██╗  ██╗██╗███╗   ██╗███████╗████████╗${RST}"
    printf '%b\n' "${CYN}    ████╗ ████║██╔══██╗╚██╗██╔╝██║████╗  ██║██╔════╝╚══██╔══╝${RST}"
    printf '%b\n' "${CYN}    ██╔████╔██║███████║ ╚███╔╝ ██║██╔██╗ ██║█████╗     ██║   ${RST}"
    printf '%b\n' "${CYN}    ██║╚██╔╝██║██╔══██║ ██╔██╗ ██║██║╚██╗██║██╔══╝     ██║   ${RST}"
    printf '%b\n' "${CYN}    ██║ ╚═╝ ██║██║  ██║██╔╝ ██╗██║██║ ╚████║███████╗   ██║   ${RST}"
    printf '%b\n' "${CYN}    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ${RST}"
    printf '%b\n' "${CYN}╚$(_rep '═' 72)╝${RST}"
    printf '%b\n' " ${BLD}${GRN}      ⟐  M O N I T O R   D E   C O N E X I O N E S  ⟐${RST}"
    printf '%b\n' " ${BLD}${GOL}                    v2.10 · Panel en Vivo${RST}"
    echo ""

    # ═══════════════ BARRA EN VIVO ═══════════════
    printf '%b\n' "${CYN}$(_rep '─' 72)${RST}"
    printf '%b\n' "  ${GRN}● EN VIVO${RST}  │  ${WHT}${FECHA}${RST}  │  ${WHT}⏱ ${UPTIME}${RST}  │  ${WHT}🖥 ${HOSTN}${RST}"
    printf '%b\n' "${CYN}$(_rep '─' 72)${RST}"
    echo ""

    # ═══════════════ CONEXIONES ACTIVAS ═══════════════
    _sep "CONEXIONES ACTIVAS"
    echo ""
    printf '%b\n' "               ${CYN}┌────────────────────────────────────┐${RST}"
    printf '%b\n' "               ${CYN}│${RST}       ${WHT}███  TOTAL: ${TOTAL_CONN}   cliente(s)${RST}   ${CYN}│${RST}"
    printf '%b\n' "               ${CYN}│${RST}       ${WHT}███${RST}                          ${CYN}│${RST}"
    printf '%b\n' "               ${CYN}└────────────────────────────────────┘${RST}"
    printf '%b\n' " desglose: udp ${UDP_CONN} · zivpn ${ZIVPN_ACT} · badvpn ${BADVPN_CONN} · ssh ${SSH_CONN}"
    echo ""

    # ═══════════════ SERVICIOS ═══════════════
    _sep "SERVICIOS"
    echo ""
    printf '%b\n' "   ${GRN}●${RST} UDP Custom   :36712        ${WHT}${UDP_CONN} activo(s)${RST}    ${CYN}$(_barra "$(_pct10 "$UDP_CONN")" 14)${RST}"
    printf '%b\n' "   ${GRN}●${RST} ZiVPN (UDP)  :5667         ${WHT}${ZIVPN_ACT} en línea${RST}    ${CYN}$(_barra "$(_pct10 "$ZIVPN_ACT")" 14)${RST}"
    printf '%b\n' "   ${GRN}●${RST} BadVPN Gate  :7100-9900    ${WHT}${BADVPN_CONN} túnel(es)${RST}    ${CYN}$(_barra "$(_pct10 "$BADVPN_CONN")" 14)${RST}"
    printf '%b\n' "   ${GRN}●${RST} SSH/Drop     :90           ${WHT}${SSH_CONN} sesión(es)${RST}   ${CYN}$(_barra "$(_pct10 "$SSH_CONN")" 14)${RST}"
    echo ""
    printf '%b\n' "   ${WHT}👥 Cuentas SSH registradas : ${SSH_REG} (${SSH_ON} en línea)${RST}"
    echo ""

    # ═══════════════ UDP CUSTOM ═══════════════
    _sep "🚀 UDP CUSTOM · Estado, Sesiones y Credenciales"
    echo ""
    if systemctl is-active --quiet udp-custom 2>/dev/null || ss -Hun 2>/dev/null | grep -q ':36712'; then
        printf '%b\n' "   ${GRN}●${RST} Estado del Servicio : EN FUNCIONAMIENTO (Puerto UDP :36712)"
    else
        printf '%b\n' "   ${RED}●${RST} Estado del Servicio : DETENIDO (Puerto UDP :36712)"
    fi
    printf '%b\n' "   ${WHT}⚡ Usuarios conectados : ${UDP_CONN} IP(s) conectada(s) · ${UDP_CONN} usuario(s) en línea${RST}"
    echo ""

    local C1=18 C2=9 C3=21 C4=18
    printf '%b\n' "   ${GRY}┌$(_rep '─' $C1)┬$(_rep '─' $C2)┬$(_rep '─' $C3)┬$(_rep '─' $C4)┐${RST}"
    printf '%b\n' "   ${GRY}│${RST} ${WHT}$(_celda 'USUARIO SSH' $C1)${RST} ${GRY}│${RST} ${WHT}$(_celda 'DISP.' $C2)${RST} ${GRY}│${RST} ${WHT}$(_celda 'ULTIMA CONEXION' $C3)${RST} ${GRY}│${RST} ${WHT}$(_celda 'ESTADO' $C4)${RST} ${GRY}│${RST}"
    printf '%b\n' "   ${GRY}├$(_rep '─' $C1)┼$(_rep '─' $C2)┼$(_rep '─' $C3)┼$(_rep '─' $C4)┤${RST}"

    local HAYU=0 ULT EST ONL
    while IFS=: read -r u _pass _exp lim; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        HAYU=1
        ULT=$(_ultima_conexion "$u")
        ONL=$(who 2>/dev/null | awk -v us="$u" '$1==us' | wc -l)
        ONL=$(_num "$ONL")
        if (( ONL > 0 )); then
            EST="${GRN}● en línea${RST}"
        else
            EST="${RED}○ apagada${RST}"
        fi
        printf '%b\n' "   ${GRY}│${RST} ${GRN}$(_celda "$u" $C1)${RST} ${GRY}│${RST} ${WHT}$(_celda "${lim:-0}" $C2)${RST} ${GRY}│${RST} ${WHT}$(_celda "$ULT" $C3)${RST} ${GRY}│${RST} ${EST} ${GRY}│${RST}"
    done < "$DB_USERS"

    if (( HAYU == 0 )); then
        printf '%b\n' "   ${GRY}│${RST} ${GRY}(sin cuentas registradas)${RST}"
    fi
    printf '%b\n' "   ${GRY}└$(_rep '─' $C1)┴$(_rep '─' $C2)┴$(_rep '─' $C3)┴$(_rep '─' $C4)┘${RST}"
    printf '%b\n' " ${UDP_CONN} IP(s) conectada(s) · ${UDP_CONN} usuario(s) en línea · ${GRN}●${RST} = sesión SSH activa · ${RED}○${RST} = sin sesión"
    echo ""

    # ═══════════════ ZIVPN ═══════════════
    _sep "⚡ ZIVPN · Estado, Sesiones y Credenciales"
    echo ""
    if ss -Hun 2>/dev/null | grep -q ':5667' || systemctl is-active --quiet zivpn 2>/dev/null; then
        printf '%b\n' "   ${GRN}●${RST} Estado del Servicio : EN FUNCIONAMIENTO (Puerto UDP :5667)"
    else
        printf '%b\n' "   ${RED}●${RST} Estado del Servicio : DETENIDO (Puerto UDP :5667)"
    fi
    printf '%b\n' "   ${WHT}⚡ Usuarios conectados : ${ZIVPN_ACT} conectado(s) · ${ZIVPN_PASS} contraseña(s) en línea${RST}"
    echo ""

    local Z1=18 Z2=9 Z3=21 Z4=12
    printf '%b\n' "   ${GRY}┌$(_rep '─' $Z1)┬$(_rep '─' $Z2)┬$(_rep '─' $Z3)┬$(_rep '─' $Z4)┐${RST}"
    printf '%b\n' "   ${GRY}│${RST} ${WHT}$(_celda 'CONTRASEÑA' $Z1)${RST} ${GRY}│${RST} ${WHT}$(_celda 'USUARIOS' $Z2)${RST} ${GRY}│${RST} ${WHT}$(_celda 'ULTIMA CONEXION' $Z3)${RST} ${GRY}│${RST} ${WHT}$(_celda 'ESTADO' $Z4)${RST} ${GRY}│${RST}"
    printf '%b\n' "   ${GRY}├$(_rep '─' $Z1)┼$(_rep '─' $Z2)┼$(_rep '─' $Z3)┼$(_rep '─' $Z4)┤${RST}"

    local HAYZ=0 ZE ZF
    if [[ -n "$ZIV_DATOS" ]]; then
        while IFS='|' read -r zauth zcon zts; do
            [[ -z "$zauth" ]] && continue
            HAYZ=1
            ZE=$(_ts_epoch "$zts")
            if (( ZE <= 0 )); then
                ZF="${GRY}—${RST}"
            elif (( AHORA - ZE <= 60 )); then
                ZF="${GRN}● $(_relativo "$ZE")${RST}"
            elif (( AHORA - ZE <= 3600 )); then
                ZF="${YEL}◐ $(_relativo "$ZE")${RST}"
            else
                ZF="${RED}○ $(_relativo "$ZE")${RST}"
            fi
            printf '%b\n' "   ${GRY}│${RST} ${GOL}$(_celda "$zauth" $Z1)${RST} ${GRY}│${RST} ${WHT}$(_celda "$zcon" $Z2)${RST} ${GRY}│${RST} ${WHT}$(_celda "$zts" $Z3)${RST} ${GRY}│${RST} ${ZF} ${GRY}│${RST}"
        done <<< "$ZIV_DATOS"
    fi

    if (( HAYZ == 0 )); then
        printf '%b\n' "   ${GRY}│${RST} ${GRY}(sin registros en ${ZIVPN_CONEX})${RST}"
    fi
    printf '%b\n' "   ${GRY}└$(_rep '─' $Z1)┴$(_rep '─' $Z2)┴$(_rep '─' $Z3)┴$(_rep '─' $Z4)┘${RST}"
    printf '%b\n' " ${ZIVPN_PASS} contraseña(s) en línea · ${ZIVPN_ACT} usuario(s) conectado(s) · ${GRN}●${RST} = activa ≤60 s · ${YEL}◐${RST} = ≤1 h · ${RED}○${RST} = inactiva"
    echo ""

    # ═══════════════ TRÁFICO ═══════════════
    _sep "📊 TRÁFICO DEL DÍA (desde 00:00)"
    echo ""
    local P_DIA=0 P_VPS=100
    (( VPS_TOTAL > 0 )) && P_DIA=$(( TR_TOTAL * 100 / VPS_TOTAL ))
    (( P_DIA > 100 )) && P_DIA=100
    printf '%b\n' "      ${YEL}▼ Descarga : $(_gb "$TR_RX") GB${RST}"
    printf '%b\n' "      ${GRN}▲ Subida   : $(_gb "$TR_TX") GB${RST}"
    printf '%b\n' "      ${CYN}──────────────────────────────${RST}"
    printf '%b\n' "      ${MAG}◆ Total día: $(_gb "$TR_TOTAL") GB${RST}     ${CYN}$(_barra "$P_DIA" 20)${RST} ${WHT}${P_DIA}%${RST}"
    printf '%b\n' "      ${MAG}◆ Total VPS: $(_gb "$VPS_TOTAL") GB${RST}     ${CYN}$(_barra "$P_VPS" 20)${RST} ${WHT}acumulado${RST}"
    printf '%b\n' "      ${GRY}interfaz ${IFACE} · base del día ${BASELINE}${RST}"
    echo ""

    # ═══════════════ SISTEMA ═══════════════
    _sep "🖥 SISTEMA"
    echo ""
    printf '%b\n' "      ${WHT}CPU    ${CPU_PCT}%  $(_barra "$CPU_PCT" 20)${RST}"
    printf '%b\n' "      ${WHT}RAM    ${RAM_PCT}%  $(_barra "$RAM_PCT" 20)  ${RAM_USED}MB / ${RAM_TOTAL}MB${RST}"
    echo ""

    # ═══════════════ PIE ═══════════════
    printf '%b\n' "${CYN}$(_rep '═' 74)${RST}"
    printf '%b\n' "  ${CYN}[ENTER]/[R] Actualizar${RST}      ${CYN}[K] Purgar flujos ZiVPN ociosos${RST}      ${RED}[0] Volver${RST}"
    printf '%b\n' "${CYN}$(_rep '═' 74)${RST}"
    printf '%b' "  ► "
}

purgar_flujos_zivpn() {
    if ! command -v conntrack >/dev/null 2>&1; then
        echo -e " ${YEL}⚠${RST} conntrack no instalado: apt install conntrack-tools"
        return 1
    fi
    local antes despues
    antes=$(conntrack -C 2>/dev/null); antes=$(_num "$antes")
    conntrack -D -p udp --dport 5667 --state UNREPLIED >/dev/null 2>&1
    despues=$(conntrack -C 2>/dev/null); despues=$(_num "$despues")
    echo -e " ${GRN}✔${RST} Flujos ZiVPN sin respuesta purgados: $(( antes - despues )) entrada(s) liberada(s)."
    echo -e " ${GRY}Los flujos activos NO se tocaron.${RST}"
}

# ─────────────────────────────────────────────────────────────
# ARGUMENTOS
# ─────────────────────────────────────────────────────────────
case "${1:-}" in
    --check)          verificar_y_limpiar; exit 0 ;;
    --snapshot-iface) _actualizar_baseline; exit 0 ;;
    --install-service) activar_servicio_monitor; exit 0 ;;
    --stop-service)   detener_servicio_monitor; exit 0 ;;
    --status)
        printf 'monitor=%s\n' "$(systemctl is-active maxinet-monitor.service 2>/dev/null || echo inactive)"
        printf 'udp=%s\n' "$(_udp_clientes 36712)"
        printf 'badvpn=%s\n' "$(_badvpn_conex)"
        printf 'ssh=%s\n' "$(_ssh_sesiones)"
        exit 0
        ;;
    --help|-h)
        echo "Uso: $0 [--check|--snapshot-iface|--install-service|--stop-service|--status]"
        echo "  Sin argumentos: panel interactivo (Monitor Conectados En Vivo)."
        exit 0
        ;;
esac

# Sin terminal: renderizar una sola vez y salir (nunca colgar un instalador)
if [[ ! -t 0 ]]; then
    mostrar_pantalla_monitor
    echo ""
    exit 0
fi

# Bucle interactivo
while true; do
    mostrar_pantalla_monitor
    if ! read -r OPC_M; then
        break
    fi
    case "$OPC_M" in
        ""|r|R) ;;
        k|K)
            echo ""
            purgar_flujos_zivpn
            verificar_y_limpiar
            sleep 2
            ;;
        0|q|Q) break ;;
        *) ;;
    esac
done
