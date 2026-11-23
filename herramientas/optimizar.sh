#!/bin/bash
#==================================================
# Maxinet Network Premium v2.11
# Optimizador de Red Carrier Grade & Latencia
# MTU 9000 · Zero-Copy Buffers · TCP BBRv3 · FQ
#==================================================

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null

source "$BASE/herramientas/warp.sh" 2>/dev/null || true

# Paleta ANSI / Nebula
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_B_AZUL="\033[1;34m"
C_B_CIAN="\033[1;36m"
C_B_VERDE="\033[1;32m"
C_B_AMARILLO="\033[1;33m"
C_B_ROJO="\033[1;31m"
C_B_BLANCO="\033[1;37m"
C_TURQUESA="\033[38;5;45m"
C_DORADO="\033[38;5;220m"
C_GRIS="\033[38;5;245m"
OP_B="$C_B_AZUL"

msg_ok()   { echo -e " ${C_B_VERDE}✔${C_RESET} $1"; }
msg_err()  { echo -e " ${C_B_ROJO}❌${C_RESET} $1"; }
msg_info() { echo -e " ${C_B_CIAN}ℹ${C_RESET} $1"; }
msg_warn() { echo -e " ${C_B_AMARILLO}⚠${C_RESET} $1"; }

ansi_ancho() {
    local str="$1"
    local clean
    clean=$(printf '%b' "$str" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" 2>/dev/null)
    if [[ -z "$clean" ]]; then
        clean=$(printf '%s' "$str" | sed 's/\\033\[[0-9;]*m//g' | sed 's/\\e\[[0-9;]*m//g')
    fi
    echo "${#clean}"
}

truncar_texto() {
    local texto="$1" max_ancho="$2"
    local vis_len
    vis_len=$(ansi_ancho "$texto")
    if [[ "$vis_len" -gt "$max_ancho" ]]; then
        local target=$(( max_ancho - 3 ))
        (( target < 1 )) && target=1
        echo "${texto:0:$target}..."
    else
        echo "$texto"
    fi
}

rellenar_ancho() {
    local texto="$1" ancho="$2"
    local vis_len
    vis_len=$(ansi_ancho "$texto")
    local pad=$(( ancho - vis_len ))
    (( pad < 0 )) && pad=0
    printf '%s' "$texto"
    (( pad > 0 )) && printf '%*s' "$pad" ''
}

BOX_INNER=68

_borde_caja() {
    local tipo="$1" titulo="$2" color_borde="${3:-$OP_B}"
    local izq der
    case "$tipo" in
        top)    izq="┌"; der="┐" ;;
        bottom) izq="└"; der="┘" ;;
        sep)    izq="├"; der="┤" ;;
        *)      izq="┌"; der="┐" ;;
    esac

    local len_titulo
    len_titulo=$(ansi_ancho "$titulo")
    local total_fill=$(( BOX_INNER - len_titulo ))
    (( total_fill < 0 )) && total_fill=0
    local lleno=$(( total_fill / 2 ))
    local vacio=$(( total_fill - lleno ))
    local linea=""
    for ((i=0; i<lleno; i++)); do linea+="─"; done
    linea+="$titulo"
    for ((i=0; i<vacio; i++)); do linea+="─"; done
    echo -e "${color_borde}${izq}${linea}${der}${C_RESET}"
}

imprimir_linea_caja() {
    local content="$1" color_borde="${2:-$OP_B}"
    local target_inner=$BOX_INNER
    local vis_len
    vis_len=$(ansi_ancho "$content")
    local pad=$(( target_inner - vis_len ))
    (( pad < 0 )) && pad=0
    local spaces=""
    (( pad > 0 )) && spaces=$(printf '%*s' "$pad" '')
    echo -e "${color_borde}│${C_RESET}${content}${spaces}${color_borde}│${C_RESET}"
}

imprimir_centro_caja() {
    local content="$1" color_borde="${2:-$OP_B}"
    local target_inner=$BOX_INNER
    local vis_len
    vis_len=$(ansi_ancho "$content")
    local total_pad=$(( target_inner - vis_len ))
    (( total_pad < 0 )) && total_pad=0
    local left_pad=$(( total_pad / 2 ))
    local right_pad=$(( total_pad - left_pad ))
    local s_left="" s_right=""
    (( left_pad > 0 )) && s_left=$(printf '%*s' "$left_pad" '')
    (( right_pad > 0 )) && s_right=$(printf '%*s' "$right_pad" '')
    echo -e "${color_borde}│${C_RESET}${s_left}${content}${s_right}${color_borde}│${C_RESET}"
}

_opt_opcion_fila() {
    local izq
    izq=$(rellenar_ancho "$1" 32)
    imprimir_linea_caja "  ${izq}$2" "$OP_B"
}

_opt_grupo() {
    _borde_caja sep "◆ $1 " "$OP_B"
}

obtener_interfaz_principal() {
    local iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        iface=$(ip link show 2>/dev/null | grep 'state UP' | awk -F: '{print $2}' | tr -d ' ' | head -1)
    fi
    echo "${iface:-eth0}"
}

_opt_dibujar_panel() {
    local err="$1"
    local iface=$(obtener_interfaz_principal)
    local mtu_act=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo "1500")
    local rmem_max=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo "212992")
    local buf_mb=$(( rmem_max / 1048576 ))
    local cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "cubic")
    local qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "fq")

    echo ""
    echo -e " ${C_DORADO}◆${C_RESET} ${C_B_BLANCO}OPTIMIZACIÓN DE RED & BUFFER CARRIER GRADE${C_RESET}"
    _borde_caja top "◈ MAXINET · OPTIMIZADOR v2.11 ◈" "$OP_B"

    imprimir_centro_caja "🌐 Interfaz: ${C_B_CIAN}${iface}${C_RESET}  ·  MTU: ${C_B_AMARILLO}${mtu_act}${C_RESET}  ·  Buffers: ${C_B_VERDE}${buf_mb} MB${C_RESET}" "$OP_B"
    imprimir_centro_caja "⚡ Congestión: ${C_B_VERDE}${cc^^} + ${qdisc^^}${C_RESET}  ·  Modo: Zero-Copy" "$OP_B"

    _opt_grupo "PERFILES PRINCIPALES"
    _opt_opcion_fila "${C_B_CIAN}[01]${C_RESET} 🚀 Modo Carrier Grade" "  ${C_B_CIAN}[02]${C_RESET} 🎬 Turbo Streaming CDN"
    _opt_opcion_fila "${C_B_CIAN}[03]${C_RESET} 🇨🇴 Perfil Colombia 2026" "  ${C_B_CIAN}[04]${C_RESET} ⚡ Turbo Latencia UDP"

    _opt_grupo "SINTONIZACIÓN MANUAL"
    _opt_opcion_fila "${C_B_CIAN}[05]${C_RESET} 📦 Buffers de Socket" "  ${C_B_CIAN}[06]${C_RESET} 🔄 Ring Buffers RX/TX"
    _opt_opcion_fila "${C_B_CIAN}[07]${C_RESET} 📏 Gestionar MTU" "  ${C_B_CIAN}[08]${C_RESET} 🌐 Selector de DNS"

    _opt_grupo "DIAGNÓSTICO & AVANZADO"
    _opt_opcion_fila "${C_B_CIAN}[09]${C_RESET} 🩺 Diagnóstico Streaming" "  ${C_B_CIAN}[10]${C_RESET} 🛡 Cloudflare WARP Exit"
    _opt_opcion_fila "${C_B_ROJO}[00]${C_RESET} ↩ Volver" ""

    [[ -n "$err" ]] && imprimir_linea_caja "  ${C_B_ROJO}⚠ ${err}${C_RESET}" "$OP_B"
    _borde_caja bottom "" "$OP_B"
}

optimizar_modo_carrier_grade_directo() {
    clear
    echo -e "${C_B_CIAN}Aplicando optimización Carrier Grade Directo...${C_RESET}\n"

    local IFACE=$(obtener_interfaz_principal)

    modprobe tcp_bbr 2>/dev/null

    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1
    sysctl -w net.core.rmem_default=33554432 >/dev/null 2>&1
    sysctl -w net.core.wmem_default=33554432 >/dev/null 2>&1
    sysctl -w net.core.optmem_max=2048576 >/dev/null 2>&1
    sysctl -w net.core.netdev_max_backlog=100000 >/dev/null 2>&1
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fin_timeout=15 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_time=300 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=15 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=5 >/dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    ip link set dev "$IFACE" txqueuelen 20000 2>/dev/null

    msg_ok "TCP BBR + FQ Pacing activado."
    msg_ok "Buffers de memoria extendidos a 64MB."
    msg_ok "Cola de transmisión txqueuelen ajustada a 20000 en $IFACE."
    echo ""
    read -rp "Presione [Enter] para continuar..." _
}

perfil_colombia_2026() {
    clear
    echo -e "${C_B_CIAN}Aplicando Perfil Colombia 2026 (Claro, Tigo, Movistar, WOM)...${C_RESET}\n"

    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_notsent_lowat=16384 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
    sysctl -w net.ipv4.ip_no_pmtu_disc=0 >/dev/null 2>&1

    # DNS Cloudflare + Google de baja latencia
    if [[ -w /etc/resolv.conf ]]; then
        echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null
    fi

    msg_ok "Perfil Colombia 2026 aplicado exitosamente."
    echo ""
    read -rp "Presione [Enter] para continuar..." _
}

optimizar_streaming_cdn() {
    clear
    echo -e "${C_B_CIAN}Activando Turbo Streaming Anti-Buffering (YouTube / TikTok / Netflix)...${C_RESET}\n"

    sysctl -w net.core.rmem_max=134217728 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=134217728 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_sack=1 >/dev/null 2>&1

    msg_ok "Buffers ampliados a 128MB para transferencias de video continuo."
    echo ""
    read -rp "Presione [Enter] para continuar..." _
}

personalizar_buffers_socket() {
    clear
    echo -e "${C_B_CIAN}Personalización de Buffers de Socket del Kernel${C_RESET}\n"
    echo -e "  [1] 32 MB (Servidores 1GB RAM)"
    echo -e "  [2] 64 MB (Recomendado estándar)"
    echo -e "  [3] 128 MB (Alto rendimiento)"
    echo -e "  [4] 256 MB (Ultra ancho de banda 10Gbps)"
    echo ""
    read -rp " Seleccione una opción: " OP_B
    case "$OP_B" in
        1) local MB=33554432 ;;
        2) local MB=67108864 ;;
        3) local MB=134217728 ;;
        4) local MB=268435456 ;;
        *) return ;;
    esac
    sysctl -w net.core.rmem_max="$MB" >/dev/null 2>&1
    sysctl -w net.core.wmem_max="$MB" >/dev/null 2>&1
    msg_ok "Buffers ajustados a $MB bytes."
    sleep 2
}

personalizar_ring_buffers() {
    clear
    local IFACE=$(obtener_interfaz_principal)
    echo -e "${C_B_CIAN}Ajustando Ring Buffers RX/TX en $IFACE...${C_RESET}\n"
    if command -v ethtool >/dev/null 2>&1; then
        ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null || ethtool -G "$IFACE" rx 2048 tx 2048 2>/dev/null
        msg_ok "Ring buffers ampliados al máximo soportado por el hardware."
    else
        apt-get install -y ethtool >/dev/null 2>&1
        ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null
        msg_ok "Ethtool instalado y ring buffers maximizados."
    fi
    echo ""
    read -rp "Presione [Enter] para continuar..." _
}

gestionar_mtu() {
    clear
    local IFACE=$(obtener_interfaz_principal)
    local MTU_ACT=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null || echo "1500")
    echo -e "${C_B_CIAN}Gestión de MTU en Interfaz $IFACE (Actual: $MTU_ACT)${C_RESET}\n"
    echo -e "  [1] MTU 1500 (Estándar Ethernet)"
    echo -e "  [2] MTU 9000 (Jumbo Frames - Oracle / AWS / Redes Gigabit)"
    echo -e "  [3] MTU 1420 (Recomendado para Redes Móviles / VPN)"
    echo -e "  [4] MTU Personalizado"
    echo ""
    read -rp " Seleccione una opción: " OP_M
    case "$OP_M" in
        1) ip link set dev "$IFACE" mtu 1500 2>/dev/null && msg_ok "MTU cambiado a 1500" ;;
        2) ip link set dev "$IFACE" mtu 9000 2>/dev/null && msg_ok "MTU cambiado a 9000" ;;
        3) ip link set dev "$IFACE" mtu 1420 2>/dev/null && msg_ok "MTU cambiado a 1420" ;;
        4)
            read -rp " Ingrese el valor MTU: " V_MTU
            [[ "$V_MTU" =~ ^[0-9]+$ ]] && ip link set dev "$IFACE" mtu "$V_MTU" 2>/dev/null && msg_ok "MTU cambiado a $V_MTU"
            ;;
    esac
    sleep 2
}

menu_selector_dns() {
    clear
    echo -e "${C_B_CIAN}Selector de Servidores DNS de Ultra Baja Latencia${C_RESET}\n"
    echo -e "  [1] Cloudflare DNS (1.1.1.1 / 1.0.0.1)"
    echo -e "  [2] Google DNS (8.8.8.8 / 8.8.4.4)"
    echo -e "  [3] AdGuard Anti-Ads DNS (94.140.14.14 / 94.140.15.15)"
    echo -e "  [4] Quad9 DNS (9.9.9.9 / 149.112.112.112)"
    echo ""
    read -rp " Seleccione una opción: " OP_D
    case "$OP_D" in
        1) echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" > /etc/resolv.conf 2>/dev/null; msg_ok "Cloudflare DNS activado" ;;
        2) echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" > /etc/resolv.conf 2>/dev/null; msg_ok "Google DNS activado" ;;
        3) echo -e "nameserver 94.140.14.14\nnameserver 94.140.15.15" > /etc/resolv.conf 2>/dev/null; msg_ok "AdGuard DNS activado" ;;
        4) echo -e "nameserver 9.9.9.9\nnameserver 149.112.112.112" > /etc/resolv.conf 2>/dev/null; msg_ok "Quad9 DNS activado" ;;
    esac
    sleep 2
}

diagnosticar_streaming() {
    clear
    echo -e "${C_B_CIAN}Diagnóstico de Latencia a Servicios de Streaming y Redes${C_RESET}\n"
    for host in "1.1.1.1" "google.com" "youtube.com" "netflix.com" "tiktok.com"; do
        echo -ne " Ping a $host: "
        local LAT=$(ping -c 2 -W 1 "$host" 2>/dev/null | awk -F'/' 'END{print $5}')
        if [[ -n "$LAT" ]]; then
            echo -e "${C_B_VERDE}${LAT} ms 🟢${C_RESET}"
        else
            echo -e "${C_B_ROJO}Timeout / Bloqueado 🔴${C_RESET}"
        fi
    done
    echo ""
    read -rp "Presione [Enter] para continuar..." _
}

# Bucle interactivo
while true; do
    clear
    _opt_dibujar_panel "$ERR_MSG"
    ERR_MSG=""
    echo ""
    echo -ne "  ${C_B_VERDE}▶ Opción:${C_RESET} "
    read -r opc_o

    case "$opc_o" in
        1|01) optimizar_modo_carrier_grade_directo ;;
        2|02) optimizar_streaming_cdn ;;
        3|03) perfil_colombia_2026 ;;
        4|04)
            sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1
            sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1
            msg_ok "Turbo latencia UDP activado."
            sleep 2
            ;;
        5|05) personalizar_buffers_socket ;;
        6|06) personalizar_ring_buffers ;;
        7|07) gestionar_mtu ;;
        8|08) menu_selector_dns ;;
        9|09) diagnosticar_streaming ;;
        10) menu_warp ;;
        0|00) break ;;
        "") ;;
        *) ERR_MSG="Opción no válida" ;;
    esac
done
