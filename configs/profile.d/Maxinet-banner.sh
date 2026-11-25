#!/bin/bash
#==================================================
# Maxinet Network - Premium Welcome Banner v3.1.5
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
    DOMAIN="${SERVER_DOMAIN:-}"
    [[ -z "$DOMAIN" && -s /etc/maxinet/dominio ]] && DOMAIN="$(tr -d ' \r\n' < /etc/maxinet/dominio 2>/dev/null)"
    [[ -z "$DOMAIN" ]] && DOMAIN="$IP_LOCAL"
    IP_LOCAL="${SERVER_PUB_IP:-"$IP_LOCAL"}"
    TG_CHANNEL="${TG_CHANNEL:-}"
    TG_GROUP="${TG_GROUP:-}"
fi
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //')
FECHA=$(date +"%d-%m-%Y")
HORA=$(date +"%H:%M:%S")

# ── Conexiones VPN reales (100% verificadas, excluye sesión administrativa de root) ──
_ssh_c=$(ps -C sshd -o args= 2>/dev/null | grep "\[priv\]" | grep -vE 'sshd:[[:space:]]*root' | wc -l)
_drop_p=$(pgrep -x dropbear 2>/dev/null | wc -l)
_drop_c=$(( _drop_p > 1 ? _drop_p - 1 : 0 ))
_udp_c=0
if [[ -r /proc/net/nf_conntrack ]]; then
    _udp_c=$(grep -c 'dport=36712' /proc/net/nf_conntrack 2>/dev/null || echo 0)
elif command -v conntrack >/dev/null 2>&1; then
    _udp_c=$(conntrack -L -p udp --dport 36712 2>/dev/null | grep -cv UNREPLIED || echo 0)
fi
_zi_c=0
if [[ -r /proc/net/nf_conntrack ]]; then
    _zi_c=$(grep -c 'dport=5667' /proc/net/nf_conntrack 2>/dev/null || echo 0)
elif command -v conntrack >/dev/null 2>&1; then
    _zi_c=$(conntrack -L -p udp --dport 5667 2>/dev/null | grep -cv UNREPLIED || echo 0)
fi
_bad_c=0
if command -v ss >/dev/null 2>&1; then
    _bad_c=$(ss -Htn sport = :7200 state established 2>/dev/null | wc -l)
fi
ONLINE=$(( _ssh_c + _drop_c + _udp_c + _zi_c + _bad_c ))

# ── Info de red simplificada ──
IFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
IFACE="${IFACE:-eth0}"

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
C_MAGENTA="\e[38;5;205m"
BOLD="\e[1m"

# ── Utilidades (Ultra-rápidas en memoria sin subprocesos) ─────
shopt -s extglob 2>/dev/null || true
COLS="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
[[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
[[ $COLS -lt 60 ]] && COLS=80

# center: centra texto con padding instantáneo sin subshells
center() {
    local text="$1"
    local vis_len="${2:-}"
    if [[ -z "$vis_len" ]]; then
        local s="$text"
        s="${s//$'\e'\[*([0-9;])m/}"
        s="${s//$'\e'\[*([0-9;])K/}"
        s="${s//$'\e'\[*([0-9;])G/}"
        s="${s//$'\e'\[*([0-9;])[a-zA-Z]/}"
        vis_len=${#s}
    fi
    local pad=$(( (COLS - vis_len) / 2 ))
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
PW=48
PL=$(( (COLS - PW - 2) / 2 ))
[[ $PL -lt 0 ]] && PL=0

p_marco_sup() {
    local border; printf -v border '%*s' "$PW" ""
    printf '%*s%b\n' "$PL" "" "${C_CIAN}${BOLD}┌${border// /─}┐${C_RESET}"
}

p_marco_inf() {
    local border; printf -v border '%*s' "$PW" ""
    printf '%*s%b\n' "$PL" "" "${C_CIAN}${BOLD}└${border// /─}┘${C_RESET}"
}

p_cabecera() {
    local title="$1"
    local vis_len="${2:-28}"
    local left_pad=$(( (PW - vis_len) / 2 ))
    local right_pad=$(( PW - vis_len - left_pad ))
    printf '%*s%b%*s%b%*s%b\n' \
        "$PL" "" \
        "${C_CIAN}${BOLD}│${C_RESET}" \
        "$left_pad" "" \
        "${C_BLANCO}${BOLD}${title}${C_RESET}" \
        "$right_pad" "" \
        "${C_CIAN}${BOLD}│${C_RESET}"
}

p_fila() {
    local icon="$1" label="$2" valor="$3" val_color="${4:-$C_BLANCO}"
    local left="  ${C_DORADO}${icon}${C_RESET} ${C_CIAN2}${BOLD}${label}${C_RESET}"
    local len_lbl=$(( 4 + ${#label} ))
    local len_val=${#valor}
    local gap=$(( PW - len_lbl - len_val - 2 ))
    [[ $gap -lt 1 ]] && gap=1
    printf '%*s%b%b%*s%b  %b\n' \
        "$PL" "" \
        "${C_CIAN}${BOLD}│${C_RESET}" \
        "$left" \
        "$gap" "" \
        "${val_color}${BOLD}${valor}${C_RESET}" \
        "${C_CIAN}${BOLD}│${C_RESET}"
}

# ==================================================
#  BANNER PRINCIPAL
# ==================================================
hr "═"
center "" 0

# ASCII MAXINET (exactamente 57 columnas cada línea para centrado idéntico)
center "${C_CIAN2}${BOLD}███╗   ███╗ █████╗ ██╗  ██╗██╗███╗   ██╗███████╗████████╗${C_RESET}" 57
center "${C_CIAN}${BOLD}████╗ ████║██╔══██╗╚██╗██╔╝██║████╗  ██║██╔════╝╚══██╔══╝${C_RESET}" 57
center "${C_CIAN}${BOLD}██╔████╔██║███████║ ╚███╔╝ ██║██╔██╗ ██║█████╗     ██║   ${C_RESET}" 57
center "${C_AZUL}${BOLD}██║╚██╔╝██║██╔══██║ ██╔██╗ ██║██║╚██╗██║██╔══╝     ██║   ${C_RESET}" 57
center "${C_AZUL}${BOLD}██║ ╚═╝ ██║██║  ██║██╔╝ ██╗██║██║ ╚████║███████╗   ██║   ${C_RESET}" 57
center "${C_AZUL2}${BOLD}╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═══╝╚══════╝   ╚═╝        ${C_RESET}" 57

center "" 0
center "${C_DORADO}${BOLD}──  ◆  MAXINET NETWORK  ◆  ──${C_RESET}" 29
center "${C_AMARILLO}${BOLD}🚀  EDICIÓN PREMIUM — 2026  🚀${C_RESET}" 30
center "" 0
hr "═"
center "" 0

# ── Panel de información ──────────────────────────
p_marco_sup
p_cabecera "📊  INFORMACIÓN DEL SERVIDOR" 28
p_marco_inf
p_marco_sup
p_fila "▶" "Servidor"     "${SERVER}"
p_fila "●" "Dominio"      "${DOMAIN}" "${C_MAGENTA}"
p_fila "◈" "IP Pública"   "${IP_LOCAL}" "${C_MAGENTA}"
p_fila "⚡" "Uptime"       "${UPTIME}"
p_fila "✪" "Conectados"   "${ONLINE}"
p_fila "◆" "Fecha"        "${FECHA}"
p_fila "◉" "Hora"         "${HORA}"
p_marco_inf
center "" 0

# ── Usuario / acción ─────────────────────────────
USER_BLOCK_W=32
PL_USER=$(( (COLS - USER_BLOCK_W) / 2 ))
[[ $PL_USER -lt 0 ]] && PL_USER=0

if [[ $EUID -ne 0 ]]; then
    printf '%*s%b   : %b\n' "$PL_USER" "" "${C_DORADO}${BOLD}👑 Usuario${C_RESET}" "${C_BLANCO}$(whoami)${C_RESET}"
    printf '%*s%b   : %b %b\n' "$PL_USER" "" "${C_ROJO}${BOLD}⚠️  Aviso${C_RESET}" "${C_AMARILLO}No eres root — ejecuta:${C_RESET}" "${C_VERDE}sudo -i${C_RESET}"
else
    printf '%*s%b   : %b\n' "$PL_USER" "" "${C_DORADO}${BOLD}👑 Usuario${C_RESET}" "${C_BLANCO}${BOLD}root${C_RESET}"
    printf '%*s%b   : %b %b\n' "$PL_USER" "" "${C_AMARILLO}${BOLD}⚡ Comando${C_RESET}" "${C_VERDE}Escribe:${C_RESET}" "${C_BLANCO}${BOLD}menu${C_RESET}"
fi
center "" 0

hr "═"
center "" 0
center "${C_VERDE}${BOLD}✨  Gracias por usar nuestros servicios  ✨${C_RESET}" 41
center "${C_GRIS}─  Acceso autorizado. Conexiones monitoreadas las 24 horas.  ─${C_RESET}" 63
center "${C_GRIS}─  Powered by Maxinet Network — Uso autorizado  ─${C_RESET}" 49
center "" 0
hr "═"
printf '\n'
