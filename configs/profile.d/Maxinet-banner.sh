#!/bin/bash
#==================================================
# Maxinet Network - Premium Welcome Banner v2.0
# DiseÃ±o profesional - alineaciÃ³n exacta de panel
#==================================================
[[ $- != *i* ]] && return
clear

# ââ Datos del sistema âââââââââââââââââââââââââââââ
SERVER=$(hostname)
IP_LOCAL=$(hostname -I 2>/dev/null | awk '{print $1}')
DOMAIN="-"
TG_CHANNEL=""
TG_GROUP=""
if [[ -f /etc/maxinet/config.conf ]]; then
    source /etc/maxinet/config.conf
    DOMAIN="${SERVER_DOMAIN:-"$IP_LOCAL"}"
    TG_CHANNEL="${TG_CHANNEL:-}"
    TG_GROUP="${TG_GROUP:-}"
fi
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //')
FECHA=$(date +"%d-%m-%Y")
HORA=$(date +"%H:%M:%S")
ONLINE=$(who 2>/dev/null | wc -l)
# ── Info de red real (MTU, Buffer, Congestión) ──
IFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
IFACE="${IFACE:-eth0}"
MTU_REAL=$(cat /sys/class/net/"$IFACE"/mtu 2>/dev/null || echo "1470")
RMEM=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
WMEM=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
BUF_RX=$((RMEM / 1024 / 1024))
BUF_TX=$((WMEM / 1024 / 1024))
[[ $BUF_RX -eq 0 ]] && BUF_RX=64
[[ $BUF_TX -eq 0 ]] && BUF_TX=64
CONG_REAL=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "bbr")
if [[ "$CONG_REAL" == "bbr" ]]; then
    if sysctl -n net.core.default_qdisc 2>/dev/null | grep -q fq; then
        CONG_REAL="BBR v3 + FQ Pacing"
    else
        CONG_REAL="BBR v3"
    fi
fi


# ââ Colores (ANSI 256) ââââââââââââââââââââââââââââ
C_RESET="\e[0m"
C_CIAN="\e[38;5;45m"
C_CIAN2="\e[38;5;51m"
C_AZUL="\e[38;5;39m"
C_AZUL2="\e[38;5;33m"
C_DORADO="\e[38;5;220m"
C_AMARILLO="\e[38;5;226m"
C_BLANCO="\e[38;5;255m"
C_GRIS="\e[38;5;245m"
C_VERDE="\e[38;5;82m"
C_ROJO="\e[38;5;203m"
C_MORADO="\e[38;5;201m"
C_NARANJA="\e[38;5;208m"
BOLD="\e[1m"

# ââ Utilidades ââââââââââââââââââââââââââââââââââââ
COLS=$(tput cols 2>/dev/null || echo 80)

# long: ancho visible de un texto (sin ANSI), cuenta emojis como 2 cols
long() {
    local s
    s=$(printf '%b' "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')
    local n
    n=$(printf '%s' "$s" | LC_ALL=C.UTF-8 wc -m 2>/dev/null)
    [[ -z "$n" || "$n" -eq 0 ]] && n=${#s}
    local ne
    ne=$(printf '%s' "$s" | LC_ALL=C.UTF-8 grep -oP '[\x{1F000}-\x{1FAFF}\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}]' 2>/dev/null | wc -l)
    [[ -z "$ne" ]] && ne=0
    echo $(( n + ne ))
}
# center: centra texto (soporta cÃ³digos ANSI)
center() {
    local text="$1"
    local len
    len=$(long "$text")
    local pad=$(( (COLS - len) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    printf '%*s' "$pad" ""
    printf '%b\n' "$text"
}
# hr: lÃ­nea horizontal adaptada al ancho
hr() {
    local char="${1:-â}"
    local line=""
    local i
    for ((i=0; i<COLS; i++)); do line+="$char"; done
    printf '%b\n' "${C_AZUL}${line}${C_RESET}"
}

# ââ Panel (ancho fijo, alineaciÃ³n perfecta) âââââââ
PW=46                      # ancho interior del panel (celdas)
PL=$(( (COLS - PW - 2) / 2 ))   # padding izquierdo
[[ $PL -lt 0 ]] && PL=0

# p_linea <contenido (sin bordes)>
p_linea() {
    local content="$1"
    local len
    len=$(long "$content")
    local fill=$(( PW - len ))
    [[ $fill -lt 0 ]] && fill=0
    printf '%*s' "$PL" ""
    printf '%b' "${C_MORADO}${BOLD}â${C_RESET}${content}"
    printf '%*s' "$fill" ""
    printf '%b\n' "${C_MORADO}${BOLD}â${C_RESET}"
}
# p_marco_sup / p_marco_inf
_repeat() {
    local char="$1" n="$2" out="" i
    for ((i=0; i<n; i++)); do out+="$char"; done
    printf '%s' "$out"
}
p_marco_sup() {
    printf '%*s' "$PL" ""
    printf '%b' "${C_MORADO}${BOLD}â"
    printf '%b' "${C_MORADO}$(_repeat 'â' "$PW")"
    printf '%b\n' "${C_MORADO}${BOLD}â${C_RESET}"
}
p_marco_inf() {
    printf '%*s' "$PL" ""
    printf '%b' "${C_MORADO}${BOLD}â"
    printf '%b' "${C_MORADO}$(_repeat 'â' "$PW")"
    printf '%b\n' "${C_MORADO}${BOLD}â${C_RESET}"
}
# p_fila <icono(1celda)> <label> <valor>
p_fila() {
    local icon="$1" label="$2" valor="$3"
    local txt
    txt="  ${C_NARANJA}${icon}${C_RESET} ${C_CIAN}${BOLD}${label}${C_RESET}"
    local len_lbl
    len_lbl=$(( 2 + 1 + 1 + ${#label} + 1 ))   # espacios + icono + espacio + label + :
    local len_val=${#valor}
    local dots=$(( PW - len_lbl - len_val ))
    [[ $dots -lt 1 ]] && dots=1
    local gap=""
    local i
    for ((i=0; i<dots; i++)); do gap+=" "; done
    p_linea "${txt}${gap}${C_BLANCO}${valor}${C_RESET}"
}

# ==================================================
#  BANNER PRINCIPAL
# ==================================================
hr "â"
center ""
center "${C_CIAN2}${BOLD}   ââââ   ââââ âââââââ âââ   âââââââââ   âââââââââââââ ${C_RESET}"
center "${C_CIAN}${BOLD}   âââââ âââââââââââââââââ   âââââââââ   ââââââââââââââ${C_RESET}"
center "${C_CIAN}${BOLD}   ââââââââââââââ   ââââââ   âââââââââ   ââââââââââââââ${C_RESET}"
center "${C_AZUL}${BOLD}   ââââââââââââââ   âââââââ âââââââââââ ââââââââââââââ ${C_RESET}"
center "${C_AZUL}${BOLD}   âââ âââ ââââââââââââ âââââââ âââ âââââââ ââââââ     ${C_RESET}"
center "${C_AZUL2}${BOLD}   âââ     âââ âââââââ   âââââ  âââ  âââââ  ââââââ     ${C_RESET}"
center ""
center "${C_DORADO}${BOLD}  ââ  â  M A X I N E T   N E T W O R K  â  ââ  ${C_RESET}"
center "${C_AMARILLO}${BOLD}        ð  EDICIÃN PREMIUM â 2026  ð${C_RESET}"
center ""
hr "â"
center ""

# ââ Panel de informaciÃ³n ââââââââââââââââââââââââââ
p_marco_sup
p_linea "${C_BLANCO}${BOLD}          ð  INFORMACIÃN DEL SERVIDOR          ${C_RESET}"
p_marco_inf
p_marco_sup
p_fila "â¶" "Servidor"   "${SERVER}"
p_fila "â" "Dominio"    "${DOMAIN}"
p_fila "â" "IP PÃºblica" "${IP_LOCAL}"
p_fila "â¡" "Uptime"     "${UPTIME}"
p_fila "âª" "Conectados" "${ONLINE}"
p_fila "â" "Fecha"      "${FECHA}"
p_fila "â" "Hora"       "${HORA}"
p_fila "🔧" "MTU"        "${MTU_REAL}"
p_fila "📦" "Buffer RX/TX" "${BUF_RX}MB / ${BUF_TX}MB"
p_fila "🚀" "Congestión"   "${CONG_REAL}"
if [[ -n "$TG_CHANNEL" ]]; then
    p_fila "â¯" "Canal"  "${TG_CHANNEL}"
fi
if [[ -n "$TG_GROUP" ]]; then
    p_fila "â¯" "Grupo"  "${TG_GROUP}"
fi
p_marco_inf
center ""

# ?????? Panel de planes y precios (informativo, estatico en USDT) ??????
p_marco_sup
p_linea "${C_BLANCO}${BOLD}          ????  PLANES Y PRECIOS  ????          ${C_RESET}"
p_marco_inf
p_marco_sup
p_fila "â¯" "BRONCE"        "5 USDT   - 1 dispositivo"
p_fila "â¯" "PREMIUM"       "15 USDT  - 2 dispositivos"
p_fila "â¯" "BETA/VITALICIA" "100 USDT - Ilimitado"
p_marco_inf
center ""

# ââ Usuario / acciÃ³n ââââââââââââââââââââââââââââââ
if [[ $EUID -ne 0 ]]; then
    center "${C_ROJO}${BOLD}ð Usuario${C_RESET}   : ${C_BLANCO}$(whoami)${C_RESET}"
    center "${C_ROJO}${BOLD}â ï¸  Advertencia${C_RESET} : ${C_AMARILLO}No eres root â ejecuta:${C_RESET} ${C_VERDE}sudo -i${C_RESET}"
else
    center "${C_DORADO}${BOLD}ð Usuario${C_RESET}   : ${C_BLANCO}root${C_RESET}"
    center "${C_DORADO}${BOLD}â¡ Comando${C_RESET}   : ${C_VERDE}Escribe:${C_RESET} ${C_BLANCO}menu${C_RESET}"
fi
center ""

hr "â"
center ""
center "${C_VERDE}${BOLD}â¨  Gracias por usar nuestros servicios  â¨${C_RESET}"
# Sello de marca no condicional.
_SELLO_OK=0
if [[ "$_SELLO_OK" == "1" ]]; then
    center "${C_ROJO}${BOLD}ð¡ï¸  SISTEMA PROTEGIDO POR MAXINET NETWORK  ð¡ï¸${C_RESET}"
else
    center "${C_GRIS}â  Acceso autorizado. Conexiones monitoreadas las 24 horas.  â${C_RESET}"
fi
center "${C_GRIS}â  Powered by Maxinet Network â Uso autorizado  â${C_RESET}"
center ""
hr "â"
printf '\n'
