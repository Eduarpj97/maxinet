#!/bin/bash
#==================================================
# Maxinet Network - Premium Welcome Banner v3.1.0
# Diseño profesional - Sistema de diseño Nebula
#==================================================
[[ $- != *i* ]] && return
clear

# ── Datos del sistema ──────────────────────────
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

# ── Colores (ANSI 256) ──────────────────────────
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

# ── Utilidades (Ultra-rápidas en memoria sin subprocesos) ─────
shopt -s extglob 2>/dev/null || true
COLS=$(tput cols 2>/dev/null || echo 80)
[[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80

# center: centra texto con padding instantáneo sin subshells
center() {
    local text="$1"
    local s="$text"
    s="${s//$'\e'\[*([0-9;])m/}"
    s="${s//$'\e'\[*([0-9;])K/}"
    s="${s//$'\e'\[*([0-9;])G/}"
    s="${s//$'\e'\[*([0-9;])[a-zA-Z]/}"
    local pad=$(( (COLS - ${#s}) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    printf '%*s%b\n' "$pad" "" "$text"
}

# hr: línea horizontal adaptada al ancho instantánea
hr() {
    local char="${1:-═}"
    local line
    printf -v line '%*s' "$COLS" ""
    printf '%b\n' "${C_AZUL}${line// /$char}${C_RESET}"
}

# ── Panel (ancho fijo, alineación perfecta) ─────
PW=46                      # ancho interior del panel (celdas)
PL=$(( (COLS - PW - 2) / 2 ))   # padding izquierdo
[[ $PL -lt 0 ]] && PL=0

# p_linea <contenido (sin bordes)> sin subshells
p_linea() {
    local content="$1"
    local s="$content"
    s="${s//$'\e'\[*([0-9;])m/}"
    s="${s//$'\e'\[*([0-9;])K/}"
    s="${s//$'\e'\[*([0-9;])G/}"
    s="${s//$'\e'\[*([0-9;])[a-zA-Z]/}"
    local fill=$(( PW - ${#s} ))
    [[ $fill -lt 0 ]] && fill=0
    printf '%*s%b%*s%b\n' "$PL" "" "${C_CIAN}${BOLD}│${C_RESET}${content}" "$fill" "" "${C_CIAN}${BOLD}│${C_RESET}"
}

# p_marco_sup / p_marco_inf
_repeat() {
    local out
    printf -v out '%*s' "$2" ""
    printf '%s' "${out// /$1}"
}

p_marco_sup() {
    local border
    printf -v border '%*s' "$PW" ""
    printf '%*s%b%b%b\n' "$PL" "" "${C_CIAN}${BOLD}┌" "${C_CIAN}${border// /─}" "${C_CIAN}${BOLD}┐${C_RESET}"
}

p_marco_inf() {
    local border
    printf -v border '%*s' "$PW" ""
    printf '%*s%b%b%b\n' "$PL" "" "${C_CIAN}${BOLD}└" "${C_CIAN}${border// /─}" "${C_CIAN}${BOLD}┘${C_RESET}"
}

# p_fila <icono(1celda)> <label> <valor>
p_fila() {
    local icon="$1" label="$2" valor="$3"
    local txt="  ${C_DORADO}${icon}${C_RESET} ${C_CIAN2}${BOLD}${label}${C_RESET}"
    local len_lbl=$(( 2 + 1 + 1 + ${#label} + 1 ))   # espacios + icono + espacio + label + espacio
    local len_val=${#valor}
    local dots=$(( PW - len_lbl - len_val ))
    [[ $dots -lt 1 ]] && dots=1
    local gap
    printf -v gap '%*s' "$dots" ""
    p_linea "${txt}${gap}${C_BLANCO}${BOLD}${valor}${C_RESET}"
}

# ==================================================
#  BANNER PRINCIPAL
# ==================================================
hr "═"
center ""
center "${C_CIAN2}${BOLD}    ███╗   ███╗ █████╗ ██╗  ██╗██╗███╗   ██╗███████╗████████╗${C_RESET}"
center "${C_CIAN}${BOLD}    ████╗ ████║██╔══██╗╚██╗██╔╝██║████╗  ██║██╔════╝╚══██╔══╝${C_RESET}"
center "${C_CIAN}${BOLD}    ██╔████╔██║███████║ ╚███╔╝ ██║██╔██╗ ██║█████╗     ██║   ${C_RESET}"
center "${C_AZUL}${BOLD}    ██║╚██╔╝██║██╔══██║ ██╔██╗ ██║██║╚██╗██║██╔══╝     ██║   ${C_RESET}"
center "${C_AZUL}${BOLD}    ██║ ╚═╝ ██║██║  ██║██╔╝ ██╗██║██║ ╚████║███████╗   ██║   ${C_RESET}"
center "${C_AZUL2}${BOLD}    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ${C_RESET}"
center ""
center "${C_DORADO}${BOLD}    ──  ◆  MAXINET NETWORK  ◆  ──  ${C_RESET}"
center "${C_AMARILLO}${BOLD}        🚀  EDICIÓN PREMIUM — 2026  🚀${C_RESET}"
center ""
hr "═"
center ""

# ── Panel de información ──────────────────────────
p_marco_sup
p_linea "${C_BLANCO}${BOLD}          📊  INFORMACIÓN DEL SERVIDOR          ${C_RESET}"
p_marco_inf
p_marco_sup
p_fila "▶" "Servidor"     "${SERVER}"
p_fila "●" "Dominio"      "${DOMAIN}"
p_fila "◈" "IP Pública"   "${IP_LOCAL}"
p_fila "⚡" "Uptime"       "${UPTIME}"
p_fila "✪" "Conectados"   "${ONLINE}"
p_fila "◆" "Fecha"        "${FECHA}"
p_fila "◉" "Hora"         "${HORA}"
p_fila "🔧" "MTU"          "${MTU_REAL}"
p_fila "📦" "Buffer RX/TX" "${BUF_RX}MB / ${BUF_TX}MB"
p_fila "🚀" "Congestión"   "${CONG_REAL}"
if [[ -n "$TG_CHANNEL" ]]; then
    p_fila "❯" "Canal"    "${TG_CHANNEL}"
fi
if [[ -n "$TG_GROUP" ]]; then
    p_fila "❯" "Grupo"    "${TG_GROUP}"
fi
p_marco_inf
center ""

# ── Usuario / acción ─────────────────────────────
if [[ $EUID -ne 0 ]]; then
    center "${C_DORADO}${BOLD}👑 Usuario${C_RESET}   : ${C_BLANCO}$(whoami)${C_RESET}"
    center "${C_ROJO}${BOLD}⚠️  Advertencia${C_RESET} : ${C_AMARILLO}No eres root — ejecuta:${C_RESET} ${C_VERDE}sudo -i${C_RESET}"
else
    center "${C_DORADO}${BOLD}👑 Usuario${C_RESET}   : ${C_BLANCO}${BOLD}root${C_RESET}"
    center "${C_AMARILLO}${BOLD}⚡ Comando${C_RESET}   : ${C_VERDE}Escribe:${C_RESET} ${C_BLANCO}${BOLD}menu${C_RESET}"
fi
center ""

hr "═"
center ""
center "${C_VERDE}${BOLD}✨  Gracias por usar nuestros servicios  ✨${C_RESET}"
center "${C_GRIS}─  Acceso autorizado. Conexiones monitoreadas las 24 horas.  ─${C_RESET}"
center "${C_GRIS}─  Powered by Maxinet Network — Uso autorizado  ─${C_RESET}"
center ""
hr "═"
printf '\n'
