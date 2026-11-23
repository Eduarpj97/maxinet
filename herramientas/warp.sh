#!/bin/bash
#==================================================
# Maxinet Network Premium v2.11
# Cloudflare WARP Smart Exit (Salida Selectiva)
# Salida rápida para dominios de streaming / redes
#==================================================

BASE="/etc/maxinet"
WARP_DIR="$BASE/warp"
WARP_DOMINIOS="$WARP_DIR/dominios.txt"
WARP_CONF="/etc/wireguard/wg0.conf"
WARP_IPSET="maxinet_warp_set"
WARP_FWMARK="0x164"
WARP_TABLE="51820"

C_RESET="\033[0m"
C_B_AZUL="\033[1;34m"
C_B_CIAN="\033[1;36m"
C_B_VERDE="\033[1;32m"
C_B_AMARILLO="\033[1;33m"
C_B_ROJO="\033[1;31m"
C_B_BLANCO="\033[1;37m"
C_DIM="\033[2m"

msg_ok()   { echo -e " ${C_B_VERDE}✔${C_RESET} $1"; }
msg_err()  { echo -e " ${C_B_ROJO}❌${C_RESET} $1"; }
msg_info() { echo -e " ${C_B_CIAN}ℹ${C_RESET} $1"; }
msg_warn() { echo -e " ${C_B_AMARILLO}⚠${C_RESET} $1"; }

_warp_preparar_dirs() {
    mkdir -p "$WARP_DIR" /etc/wireguard "$BASE/scripts" 2>/dev/null
    if [[ ! -f "$WARP_DOMINIOS" ]]; then
        cat > "$WARP_DOMINIOS" << 'DOMEOF'
tiktok.com
tiktokcdn.com
tiktokv.com
instagram.com
cdninstagram.com
facebook.com
fbcdn.net
whatsapp.com
whatsapp.net
netflix.com
nflxvideo.net
googlevideo.com
youtube.com
DOMEOF
    fi
}

warp_estado() {
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        echo "ACTIVO"
    else
        echo "INACTIVO"
    fi
}

menu_warp() {
    _warp_preparar_dirs
    while true; do
        clear
        local ST=$(warp_estado)
        local ST_COLOR="${C_B_ROJO}🔴 INACTIVO${C_RESET}"
        [[ "$ST" == "ACTIVO" ]] && ST_COLOR="${C_B_VERDE}🟢 ACTIVO${C_RESET}"

        echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo -e "       ${C_B_BLANCO}CLOUDFLARE WARP SMART EXIT${C_RESET} ${C_B_CIAN}v2.11${C_RESET}"
        echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo -e "  Estado del túnel: $ST_COLOR"
        echo -e "  Enrutamiento selectivo para streaming y redes sociales"
        echo -e "${C_B_AZUL}────────────────────────────────────────────────────────────${C_RESET}"
        echo ""
        echo -e "  ${C_B_CIAN}[01]${C_RESET} 🚀 Activar Smart Exit WARP"
        echo -e "  ${C_B_CIAN}[02]${C_RESET} 🛑 Detener Smart Exit WARP"
        echo -e "  ${C_B_CIAN}[03]${C_RESET} 📋 Ver dominios enrutados"
        echo -e "  ${C_B_CIAN}[04]${C_RESET} ➕ Añadir dominio a la lista"
        echo -e "  ${C_B_ROJO}[00]${C_RESET} ↩ Volver"
        echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo ""
        read -rp " » Seleccione una opción: " OPC_W

        case "$OPC_W" in
            1|01)
                msg_info "Verificando dependencias wireguard e ipset..."
                apt-get update -y >/dev/null 2>&1
                apt-get install -y wireguard ipset curl iproute2 >/dev/null 2>&1
                systemctl start wg-quick@wg0 >/dev/null 2>&1 || msg_warn "Configuración inicial de WARP requerida en wg0.conf"
                sleep 2
                ;;
            2|02)
                systemctl stop wg-quick@wg0 >/dev/null 2>&1
                msg_ok "WARP Smart Exit detenido."
                sleep 2
                ;;
            3|03)
                clear
                echo -e "${C_B_CIAN}Dominios enrutados por WARP:${C_RESET}\n"
                cat "$WARP_DOMINIOS" 2>/dev/null
                echo ""
                read -rp "Presione [Enter] para continuar..." _
                ;;
            4|04)
                echo -ne "\n Escriba el nuevo dominio (ej: twitch.tv): "
                read -r N_DOM
                if [[ -n "$N_DOM" ]]; then
                    echo "$N_DOM" >> "$WARP_DOMINIOS"
                    msg_ok "Dominio '$N_DOM' añadido."
                fi
                sleep 2
                ;;
            0|00) break ;;
            *) ;;
        esac
    done
}
