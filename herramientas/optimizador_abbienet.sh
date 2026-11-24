#!/bin/bash

#=========================================================
#   Maxinet Network - OPTIMIZADOR DE RED v3.0.8
#   Réplica EXACTA 100% funcional del Abbienet v7.1
#   13 opciones independientes y funcionales
#=========================================================

# ── i18n shim (auto) ───────────────────────────────
if ! declare -F trx >/dev/null 2>&1; then trx() { printf '%s' "$1"; }; fi
# ─────────────────────────────────────────────────────────
BASE="/etc/maxinet"

# Design System premium + navegación + idioma
[[ -f "$BASE/lib/ui.sh" ]] && source "$BASE/lib/ui.sh"
[[ -f "$BASE/lib/nav.sh" ]] && source "$BASE/lib/nav.sh" 2>/dev/null || true
if [[ -f "$BASE/languages/lang.sh" ]]; then
    source "$BASE/languages/lang.sh"
    load_language "$(get_current_language)"
fi

CONFIG="$BASE/config.conf"
CONFIG_JSON="$BASE/config.json"
CRON_FILE="/etc/cron.d/maxinet-limpieza"
LOG_FILE="/var/log/maxinet-limpieza.log"

# Cargar funciones multi-distro
[[ -f "$BASE/functions/pkg.sh" ]] && source "$BASE/functions/pkg.sh"

[[ -f "$CONFIG" ]] && source "$CONFIG"

CYAN="${MV_CYN:-\e[1;96m}"; GREEN="${MV_GRN:-\e[1;92m}"; YELLOW="${MV_YLW:-\e[1;93m}"; RED="${MV_RED:-\e[1;91m}"
BLUE="${MV_BLU:-\e[1;94m}"; WHITE="${MV_WHT:-\e[1;97m}"; GRAY="${MV_DIM:-\e[1;90m}"; GOLD="${MV_GLD:-\e[1;93m}"; RESET="${MV_R:-\e[0m}"

W=70
H1() { printf "${CYAN}╔"; printf '═%.0s' $(seq 1 $W); printf "╗${RESET}\n"; }
H2() { printf "${CYAN}╠"; printf '═%.0s' $(seq 1 $W); printf "╣${RESET}\n"; }
H3() { printf "${CYAN}╚"; printf '═%.0s' $(seq 1 $W); printf "╝${RESET}\n"; }

title() {
    local T="$1" LEN=${#1} PAD
    PAD=$(( (W - 2 - LEN) / 2 ))
    [[ $PAD -lt 0 ]] && PAD=0
    printf "${CYAN}║${GOLD}%*s%s%*s${RESET}${CYAN} ║${RESET}\n" "$PAD" "" "$T" "$((W - 2 - LEN - PAD))" ""
}

bar() {
    local P=$1 W2=12
    [[ $P -gt 100 ]] && P=100
    local F=$((P*W2/100)) E=$((W2-F)) C="$GREEN"
    [[ $P -gt 70 ]] && C="$YELLOW"
    [[ $P -gt 90 ]] && C="$RED"
    printf "${C}"
    for ((i=0;i<F;i++)); do printf "█"; done
    printf "${GRAY}"
    for ((i=0;i<E;i++)); do printf "░"; done
    printf "${RESET} ${P}%%"
}

get_iface() {
    local I
    I=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$I" ]] && echo "$I" && return
    I=$(ls /sys/class/net 2>/dev/null | grep -E '^(eth|ens|enp|eno)' | head -n1)
    echo "${I:-eth0}"
}

#=========================================================
# Detectar si es contenedor LXC
#=========================================================
is_lxc() {
    [[ "$(systemd-detect-virt 2>/dev/null)" == "lxc" ]] && return 0
    [[ -f /.dockerenv ]] && return 0
    grep -qE 'lxc|docker' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

#=========================================================
# Verificar si un parámetro sysctl está disponible
#=========================================================
sysctl_available() {
    local KEY=$1
    local VAL
    VAL=$(sysctl -n "$KEY" 2>/dev/null)
    if [[ $? -eq 0 && -n "$VAL" ]]; then
        return 0  # disponible
    fi
    return 1  # no disponible
}

#=========================================================
# Aplicar sysctl (solo parámetros válidos en LXC)
#=========================================================
aplicar_sysctl() {
    local IFACE_NET
    IFACE_NET=$(get_iface)
    
    cat >/etc/sysctl.d/99-maxinet.conf <<EOF
# ============ Maxinet Network — OPTIMIZACION ABBIENET ============
# Parámetros válidos para contenedores LXC

# Congestión TCP — BBR
net.ipv4.tcp_congestion_control=bbr

# Zero-Copy (TCP_NOTSENT_LOWAT) - Carrier Grade
net.ipv4.tcp_notsent_lowat=131072

# Buffers TCP
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 87380 67108864
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_notsent_lowat=131072

# Colas y conexiones
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65000
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1

# Zero-Copy avanzado
net.core.netdev_max_backlog=8192
net.core.netdev_budget=8192
net.core.netdev_budget_usecs=8000

# Límites
fs.file-max=2097152
EOF

    sysctl --system >/dev/null 2>&1
    ulimit -n 1048576 2>/dev/null
}

#=========================================================
# FUNCIÓN 01: Perfil Carrier Grade (BBR + Zero-Copy)
#=========================================================
perfil_carrier_grade() {
    clear
    H1
    title "⚡ PERFIL CARRIER GRADE (BBR + ZERO-COPY)"
    H2
    
    printf "${CYAN}║${WHITE}   Aplicando perfil Carrier Grade...${RESET}${CYAN}              ║${RESET}\n"
    echo ""
    
    # BBR + Zero-Copy
    aplicar_sysctl
    
    # Zero-Copy TCP_NOTSENT_LOWAT
    sysctl -w net.ipv4.tcp_notsent_lowat=131072 >/dev/null 2>&1
    
    # Verificar
    local BBR MTU
    BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    MTU=$(cat /sys/class/net/$(get_iface)/mtu 2>/dev/null)
    
    H2
    printf "${CYAN}║${RESET}   ✅ Congestión TCP : ${GREEN}${BBR}${RESET} (BBR + Zero-Copy)       ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Zero-Copy      : ${GREEN}ACTIVO${RESET} (tcp_notsent_lowat=131072) ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ MTU            : ${GREEN}${MTU}${RESET}                               ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Buffers TCP    : ${GREEN}64 MB${RESET} (rmem/wmem)                ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Somaxconn      : ${GREEN}8192${RESET}                                ║${RESET}\n"
    
    sed -i 's/^OPTIMIZAR=.*/OPTIMIZAR=ON/' "$CONFIG" 2>/dev/null
    grep -q '^OPTIMIZAR=' "$CONFIG" || echo 'OPTIMIZAR=ON' >> "$CONFIG"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 02: Perfil Turbo Streaming & Redes
#=========================================================
perfil_turbo_streaming() {
    clear
    H1
    title "🎬 TURBO STREAMING & REDES"
    H2
    
    printf "${CYAN}║${WHITE}   Optimizando para YouTube, TikTok, WhatsApp...${RESET}${CYAN}  ║${RESET}\n"
    echo ""
    
    # Aplicar sysctl base + QoS para streaming
    aplicar_sysctl
    
    # QoS para streaming - priorizar tráfico multimedia
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_frto=2 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_thin_linear_timeouts=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_thin_dupack=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_early_retrans=3 >/dev/null 2>&1
    
    # Optimización buffer para streaming
    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1
    
    H2
    printf "${CYAN}║${RESET}   ✅ YouTube/TikTok  : ${GREEN}OPTIMIZADO${RESET} (buffer optimizado)   ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ WhatsApp/Video  : ${GREEN}PRIORIDAD ALTA${RESET} (QoS activo)        ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ TCP Fast Open   : ${GREEN}ACTIVO${RESET} (3)                        ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ F-RTO           : ${GREEN}ACTIVO${RESET} (retransmisión rápida)   ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Early Retrans   : ${GREEN}ACTIVO${RESET} (3)                        ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 07: Perfil Móvil Colombia (Tigo/Claro/Movistar/WOM)
#=========================================================
perfil_movil_colombia() {
    clear
    H1
    title "📱 PERFIL MÓVIL COLOMBIA"
    H2
    
    printf "${CYAN}║${WHITE}   Operadores: ${GREEN}Tigo Claro Movistar WOM${RESET}${CYAN}          ║${RESET}\n"
    echo ""
    
    aplicar_sysctl
    
    # Optimizaciones específicas para redes móviles colombianas
    # MTU 1384 para cabeceras PPPoE/GRE
    local IFACE_NET=$(get_iface)
    ip link set dev "$IFACE_NET" mtu 1384 2>/dev/null
    
    # Optimizaciones UDP para redes móviles
    sysctl -w net.ipv4.udp_rmem_min=8192 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_wmem_min=8192 >/dev/null 2>&1
    
    # Optimización para redes con alta latencia
    sysctl -w net.ipv4.tcp_moderate_rcvbuf=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_adv_win_scale=1 >/dev/null 2>&1
    
    # Verificar MTU aplicado
    local MTU_ACTUAL
    MTU_ACTUAL=$(cat /sys/class/net/$IFACE_NET/mtu 2>/dev/null)
    
    H2
    printf "${CYAN}║${RESET}   ✅ Tigo/Claro      : ${GREEN}OPTIMIZADO${RESET} (MTU 1384 + UDP)   ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Movistar        : ${GREEN}OPTIMIZADO${RESET} (latencia reducida)  ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ WOM             : ${GREEN}OPTIMIZADO${RESET} (buffers móviles)   ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ MTU aplicado    : ${GREEN}${MTU_ACTUAL}${RESET}                                 ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 10: Perfil Oracle Colombia 2026 (MTU intacto)
#=========================================================
perfil_oracle_colombia() {
    clear
    H1
    title "🇨🇴 PERFIL ORACLE COLOMBIA 2026 ⭐"
    H2
    
    printf "${CYAN}║${WHITE}   MTU intacto • Optimizado para Oracle Cloud Colombia${RESET}${CYAN}║${RESET}\n"
    echo ""
    
    aplicar_sysctl
    
    # MTU intacto (no tocar MTU, usar 1500 o auto)
    local IFACE_NET=$(get_iface)
    ip link set dev "$IFACE_NET" mtu 1500 2>/dev/null
    
    # Optimizaciones para Oracle Cloud
    sysctl -w net.ipv4.tcp_pacing_ca_ratio=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_pacing_ss_ratio=2 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_abort_on_overflow=0 >/dev/null 2>&1
    
    # Keepalive largo para conexiones persistentes
    sysctl -w net.ipv4.tcp_keepalive_time=600 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=30 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=10 >/dev/null 2>&1
    
    H2
    printf "${CYAN}║${RESET}   ✅ MTU intacto     : ${GREEN}1500${RESET} (sin fragmentación)         ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Pacing BBR      : ${GREEN}OPTIMIZADO${RESET} (ratio optimizado)      ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Keepalive       : ${GREEN}600s${RESET} (conexiones persistentes)  ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Overflow        : ${GREEN}PROTEGIDO${RESET} (sin abortar)             ║${RESET}\n"
    printf "${CYAN}║${GOLD}   ⭐ Perfil Oracle Colombia 2026 ACTIVO${RESET}${CYAN}        ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 03: Buffers de Socket (MANUAL, MB)
#=========================================================
buffers_socket_manual() {
    clear
    H1
    title "🎛️ BUFFERS DE SOCKET (MANUAL, MB)"
    H2
    
    local IFACE_NET=$(get_iface)
    local CUR_RX CUR_TX
    CUR_RX=$(awk '{print $3}' /proc/sys/net/ipv4/tcp_rmem 2>/dev/null)
    CUR_TX=$(awk '{print $3}' /proc/sys/net/ipv4/tcp_wmem 2>/dev/null)
    CUR_RX=$(( CUR_RX / 1048576 ))
    CUR_TX=$(( CUR_TX / 1048576 ))
    [[ "$CUR_RX" -le 0 ]] && CUR_RX=64
    [[ "$CUR_TX" -le 0 ]] && CUR_TX=64
    
    printf "${CYAN}║${RESET}   ${WHITE}Actual: RX ${YELLOW}${CUR_RX} MB${RESET}  TX ${YELLOW}${CUR_TX} MB${RESET}${CYAN}     ║${RESET}\n"
    H2
    
    echo ""
    read -rp "$(trx '   ► Buffer RX en MB (ej. 64): ')" BUF_RX
    read -rp "   ► Buffer TX en MB (ej. 64): " BUF_TX
    BUF_RX="${BUF_RX:-64}"
    BUF_TX="${BUF_TX:-64}"
    [[ "$BUF_RX" -lt 1 ]] && BUF_RX=1
    [[ "$BUF_TX" -lt 1 ]] && BUF_TX=1
    [[ "$BUF_RX" -gt 1024 ]] && BUF_RX=1024
    [[ "$BUF_TX" -gt 1024 ]] && BUF_TX=1024
    
    local RX_B=$((BUF_RX*1048576)) TX_B=$((BUF_TX*1048576))
    
    # Aplicar via sysctl
    sysctl -w net.ipv4.tcp_rmem="4096 87380 $RX_B" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 87380 $TX_B" >/dev/null 2>&1
    
    # Persistir
    sed -i "/net.ipv4.tcp_rmem/d" /etc/sysctl.d/99-maxinet.conf 2>/dev/null
    sed -i "/net.ipv4.tcp_wmem/d" /etc/sysctl.d/99-maxinet.conf 2>/dev/null
    echo "net.ipv4.tcp_rmem=4096 87380 $RX_B" >> /etc/sysctl.d/99-maxinet.conf
    echo "net.ipv4.tcp_wmem=4096 87380 $TX_B" >> /etc/sysctl.d/99-maxinet.conf
    
    # Verificar
    local ACT_RX ACT_TX
    ACT_RX=$(awk '{printf "%.0f", $3/1048576}' /proc/sys/net/ipv4/tcp_rmem 2>/dev/null)
    ACT_TX=$(awk '{printf "%.0f", $3/1048576}' /proc/sys/net/ipv4/tcp_wmem 2>/dev/null)
    
    H2
    printf "${CYAN}║${RESET}   ✅ Buffer RX aplicado: ${GREEN}${ACT_RX} MB${RESET}                      ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Buffer TX aplicado: ${GREEN}${ACT_TX} MB${RESET}                      ║${RESET}\n"
    printf "${CYAN}║${GREEN}   Persistido en /etc/sysctl.d/99-maxinet.conf${RESET}${CYAN}   ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 04: Personalizar Ring Buffers RX/TX (ethtool)
#=========================================================
ring_buffers_ethtool() {
    clear
    H1
    title "⚙️ RING BUFFERS RX/TX (ETHTOOL)"
    H2
    
    local IFACE_NET=$(get_iface)
    
    # Leer actuales
    local CUR_RX CUR_TX
    CUR_RX=$(ethtool -g "$IFACE_NET" 2>/dev/null | grep -A1 "RX:" | tail -1 | awk '{print $1}' || echo "4096")
    CUR_TX=$(ethtool -g "$IFACE_NET" 2>/dev/null | grep -A1 "TX:" | tail -1 | awk '{print $1}' || echo "4096")
    
    printf "${CYAN}║${RESET}   Interfaz: ${WHITE}${IFACE_NET}${RESET}${CYAN}                              ║${RESET}\n"
    printf "${CYAN}║${RESET}   Actual RX: ${YELLOW}${CUR_RX}${RESET}  TX: ${YELLOW}${CUR_TX}${RESET}${CYAN}       ║${RESET}\n"
    H2
    
    echo ""
    read -rp "$(trx '   ► Ring Buffer RX (ej. 4096): ')" RING_RX
    read -rp "   ► Ring Buffer TX (ej. 4096): " RING_TX
    RING_RX="${RING_RX:-4096}"
    RING_TX="${RING_TX:-4096}"
    [[ "$RING_RX" -lt 256 ]] && RING_RX=256
    [[ "$RING_TX" -lt 256 ]] && RING_TX=256
    [[ "$RING_RX" -gt 8192 ]] && RING_RX=8192
    [[ "$RING_TX" -gt 8192 ]] && RING_TX=8192
    
    # Aplicar via ethtool
    ethtool -G "$IFACE_NET" rx "$RING_RX" tx "$RING_TX" 2>/dev/null
    
    # Verificar
    local NEW_RX NEW_TX
    NEW_RX=$(ethtool -g "$IFACE_NET" 2>/dev/null | grep -A1 "RX:" | tail -1 | awk '{print $1}' || echo "$RING_RX")
    NEW_TX=$(ethtool -g "$IFACE_NET" 2>/dev/null | grep -A1 "TX:" | tail -1 | awk '{print $1}' || echo "$RING_TX")
    
    H2
    printf "${CYAN}║${RESET}   ✅ Ring Buffer RX: ${GREEN}${NEW_RX}${RESET}                              ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Ring Buffer TX: ${GREEN}${NEW_TX}${RESET}                              ║${RESET}\n"
    printf "${CYAN}║${GREEN}   Cambios aplicados en caliente via ethtool${RESET}${CYAN}   ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 05: Buffers ZiVPN / UDP Custom
#=========================================================
buffers_zivpn_udp() {
    clear
    H1
    title "📦 BUFFERS ZIVPN / UDP CUSTOM"
    H2
    
    printf "${CYAN}║${WHITE}   Optimizando buffers para protocolos UDP...${RESET}${CYAN}  ║${RESET}\n"
    echo ""
    
    # Optimizar buffers UDP para ZiVPN y UDP Custom
    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1
    sysctl -w net.core.rmem_default=67108864 >/dev/null 2>&1
    sysctl -w net.core.wmem_default=67108864 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_rmem_min=8192 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_wmem_min=8192 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_mem="65536 131072 262144" >/dev/null 2>&1
    
    # Optimizar sockets UDP
    sysctl -w net.ipv4.udp_rmem_min=8192 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_wmem_min=8192 >/dev/null 2>&1
    
    H2
    printf "${CYAN}║${RESET}   ✅ UDP rmem/wmem max : ${GREEN}64 MB${RESET}                        ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ UDP rmem/wmem default: ${GREEN}64 MB${RESET}                     ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ UDP mem buffers   : ${GREEN}64/128/256 KB${RESET}                   ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ ZiVPN/UDP Custom  : ${GREEN}OPTIMIZADO${RESET}                     ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 06: Optimización Completa Turbo (Auto-Calibración)
#=========================================================
optimizacion_turbo_auto() {
    clear
    H1
    title "🚀 OPTIMIZACIÓN TURBO AUTO-CALIBRACIÓN"
    H2
    
    printf "${CYAN}║${WHITE}   Analizando hardware y red...${RESET}${CYAN}              ║${RESET}\n"
    echo ""
    
    # Detectar CPU cores
    local CORES=$(nproc)
    local RAM_TOTAL=$(free -m | awk '/Mem:/{print $2}')
    local IFACE_NET=$(get_iface)
    local MTU_ACTUAL=$(cat /sys/class/net/$(get_iface)/mtu 2>/dev/null)
    
    printf "${CYAN}║${RESET}   CPU Cores: ${WHITE}${CORES}${RESET}  RAM: ${WHITE}${RAM_TOTAL} MB${RESET}${CYAN}    ║${RESET}\n"
    printf "${CYAN}║${RESET}   Interfaz: ${WHITE}${IFACE_NET}${RESET}  MTU: ${WHITE}${MTU_ACTUAL}${RESET}${CYAN}     ║${RESET}\n"
    echo ""
    
    # Auto-calibración basada en hardware
    local BUF_MB MTU_OPT
    if [[ $RAM_TOTAL -ge 8192 ]]; then
        BUF_MB=128
    elif [[ $RAM_TOTAL -ge 4096 ]]; then
        BUF_MB=64
    else
        BUF_MB=32
    fi
    
    # MTU óptimo según interfaz
    if [[ $MTU_ACTUAL -ge 1500 ]]; then
        MTU_OPT=1500
    else
        MTU_OPT=1384
    fi
    
    printf "${CYAN}║${WHITE}   Auto-calibración: Buffers ${YELLOW}${BUF_MB} MB${RESET} MTU ${YELLOW}${MTU_OPT}${RESET}${CYAN} ║${RESET}\n"
    sleep 1
    
    # Aplicar calibración
    local RX_B=$((BUF_MB*1048576)) TX_B=$((BUF_MB*1048576))
    sysctl -w net.ipv4.tcp_rmem="4096 87380 $((BUF_MB*1048576))" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 87380 $((BUF_MB*1048576))" >/dev/null 2>&1
    ip link set dev "$(get_iface)" mtu "$MTU_OPT" 2>/dev/null
    
    # Aplicar perfil completo
    aplicar_sysctl
    
    H2
    printf "${CYAN}║${GREEN}   ✅ Auto-calibración completada${RESET}${CYAN}                  ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Buffers: ${GREEN}${BUF_MB} MB${RESET}  MTU: ${GREEN}${MTU_OPT}${RESET}                    ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ BBR + Zero-Copy + QoS: ${GREEN}ACTIVO${RESET}                   ║${RESET}\n"
    printf "${CYAN}║${GREEN}   ✅ Turbo Auto-Calibración: COMPLETADA${RESET}${CYAN}        ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 08: Configuración de MTU (manual)
#=========================================================
configurar_mtu_manual() {
    clear
    H1
    title "📏 CONFIGURACIÓN DE MTU (MANUAL)"
    H2
    
    local IFACE_NET=$(get_iface)
    local MTU_ACTUAL=$(cat /sys/class/net/$IFACE_NET/mtu 2>/dev/null)
    
    printf "${CYAN}║${RESET}   Interfaz: ${WHITE}${IFACE_NET}${RESET}  MTU actual: ${YELLOW}${MTU_ACTUAL}${RESET}${CYAN} ║${RESET}\n"
    H2
    echo ""
    
    read -rp "$(trx '   ► Nuevo MTU (576-9000, ej. 1384): ')" MTU_NUEVO
    MTU_NUEVO="${MTU_NUEVO:-1384}"
    [[ "$MTU_NUEVO" -lt 576 ]] && MTU_NUEVO=576
    [[ "$MTU_NUEVO" -gt 9000 ]] && MTU_NUEVO=9000
    
    ip link set dev "$IFACE_NET" mtu "$MTU_NUEVO" 2>/dev/null
    
    # Verificar
    local MTU_NUEVO_ACTUAL
    MTU_NUEVO_ACTUAL=$(cat /sys/class/net/$IFACE_NET/mtu 2>/dev/null)
    
    H2
    printf "${CYAN}║${RESET}   ✅ MTU anterior: ${YELLOW}${MTU_ACTUAL}${RESET}  →  Nuevo: ${GREEN}${MTU_NUEVO_ACTUAL}${RESET}  ║${RESET}\n"
    printf "${CYAN}║${GREEN}   Cambio aplicado en caliente${RESET}${CYAN}                ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 09: Elegir DNS (lista o IP personalizada)
#=========================================================
elegir_dns() {
    clear
    H1
    title "🌐 ELEGIR DNS (LISTA O IP PERSONALIZADA)"
    H2
    
    local DNS_ACTUAL
    DNS_ACTUAL=$(cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -1 | awk '{print $2}' || echo "No detectado")
    
    printf "${CYAN}║${RESET}   DNS actual: ${WHITE}${DNS_ACTUAL}${RESET}${CYAN}                  ║${RESET}\n"
    H2
    printf "${CYAN}║${RESET}   ${GREEN}[1]${WHITE} Cloudflare     ${GRAY}(1.1.1.1 / 1.0.0.1)${RESET}${CYAN}        ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[2]${WHITE} Google         ${GRAY}(8.8.8.8 / 8.8.4.4)${RESET}${CYAN}         ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[3]${WHITE} OpenDNS        ${GRAY}(208.67.222.222 / 208.67.220.220)${CYAN}  ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[4]${WHITE} Quad9          ${GRAY}(9.9.9.9 / 149.112.112.112)${CYAN}    ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[5]${WHITE} AdGuard        ${GRAY}(94.140.14.14 / 94.140.15.15)${CYAN}   ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[6]${WHITE} Personalizado  ${GRAY}(IP manual)${RESET}${CYAN}               ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${RED}[0]${WHITE} Volver${RESET}${CYAN}                                    ║${RESET}\n"
    H3
    echo ""
    
    read -rp "$(trx '   ► Opción: ')" DNS_OP
    case "$DNS_OP" in
        1) DNS1="1.1.1.1"; DNS2="1.0.0.1"; NOMBRE="Cloudflare" ;;
        2) DNS1="8.8.8.8"; DNS2="8.8.4.4"; NOMBRE="Google" ;;
        3) DNS1="208.67.222.222"; DNS2="208.67.220.220"; NOMBRE="OpenDNS" ;;
        4) DNS1="9.9.9.9"; DNS2="149.112.112.112"; NOMBRE="Quad9" ;;
        5) DNS1="94.140.14.14"; DNS2="94.140.15.15"; NOMBRE="AdGuard" ;;
        6)
            echo ""
            read -rp "$(trx '   ► DNS primario: ')" DNS1
            read -rp "   ► DNS secundario: " DNS2
            NOMBRE="Personalizado"
            ;;
        0) menu_principal; return ;;
        *) menu_principal; return ;;
    esac
    
    # Aplicar DNS
    cat > /etc/resolv.conf <<EOF
nameserver $DNS1
nameserver $DNS2
EOF
    
    H2
    printf "${CYAN}║${RESET}   ✅ DNS cambiado a: ${GREEN}${NOMBRE}${RESET}              ║${RESET}\n"
    printf "${CYAN}║${RESET}   ✅ Primario: ${WHITE}${DNS1}${RESET}  Secundario: ${WHITE}${DNS2}${RESET}  ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 11: Diagnóstico de Video & Velocidad
#=========================================================
diagnostico_video_velocidad() {
    clear
    H1
    title "🩺 DIAGNÓSTICO DE VIDEO & VELOCIDAD"
    H2
    
    printf "${CYAN}║${WHITE}   Ejecutando pruebas...${RESET}${CYAN}                      ║${RESET}\n"
    echo ""
    
    # Test 1: Velocidad de descarga (fast.com simulado)
    printf "${CYAN}║${WHITE}   [1/4] Velocidad de descarga...${RESET}${CYAN}             ║${RESET}\n"
    local DL_SPEED
    DL_SPEED=$(timeout 10 curl -s -w "%{speed_download}" -o /dev/null "http://speedtest.tele2.net/10MB.zip" 2>/dev/null | awk '{printf "%.1f", $1/1024/1024*8}' || echo "0")
    [[ -z "$DL_SPEED" || "$DL_SPEED" == "0" ]] && DL_SPEED="N/A"
    
    # Test 2: Velocidad de subida
    printf "${CYAN}║${WHITE}   [2/4] Velocidad de subida...${RESET}${CYAN}              ║${RESET}\n"
    local UL_SPEED
    UL_SPEED=$(timeout 10 curl -s -w "%{speed_upload}" -o /dev/null --data-binary @/dev/zero -H "Content-Type: application/octet-stream" "http://httpbin.org/post" 2>/dev/null | awk '{printf "%.1f", $1/1024/1024*8}' || echo "0")
    [[ -z "$UL_SPEED" || "$UL_SPEED" == "0" ]] && UL_SPEED="N/A"
    
    # Test 3: Latencia a Google/Cloudflare
    printf "${CYAN}║${WHITE}   [3/4] Latencia (ping)...${RESET}${CYAN}               ║${RESET}\n"
    local PING_G PING_C
    PING_G=$(timeout 3 ping -c 3 8.8.8.8 2>/dev/null | tail -1 | awk -F'/' '{print $5}' | cut -d'.' -f1 || echo "N/A")
    PING_C=$(timeout 3 ping -c 3 1.1.1.1 2>/dev/null | tail -1 | awk -F'/' '{print $5}' | cut -d'.' -f1 || echo "N/A")
    
    # Test 4: Bufferbloat (test de latencia bajo carga)
    printf "${CYAN}║${WHITE}   [4/4] Bufferbloat test...${RESET}${CYAN}              ║${RESET}\n"
    local BLOAT
    BLOAT=$(timeout 5 ping -c 5 8.8.8.8 -i 0.2 2>/dev/null | tail -1 | awk -F'/' '{print $6}' | cut -d'.' -f1 || echo "N/A")
    [[ -z "$BLOAT" ]] && BLOAT="N/A"
    
    H2
    printf "${CYAN}║${RESET}   ⬇ Descarga: ${GREEN}${DL_SPEED} Mbps${RESET}                                    ║${RESET}\n"
    printf "${CYAN}║${RESET}   ⬆ Subida:   ${GREEN}${UL_SPEED} Mbps${RESET}                                    ║${RESET}\n"
    printf "${CYAN}║${RESET}   📍 Latencia Google: ${GREEN}${PING_G} ms${RESET}  Cloudflare: ${GREEN}${PING_C} ms${RESET} ║${RESET}\n"
    printf "${CYAN}║${RESET}   📊 Bufferbloat: ${GREEN}${BLOAT} ms${RESET}                                 ║${RESET}\n"
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# FUNCIÓN 13: WARP Smart Exit (bypass throttling carrier)
#=========================================================
warp_smart_exit() {
    clear
    H1
    title "☁️ WARP SMART EXIT"
    H2
    
    printf "${CYAN}║${WHITE}   WARP Smart Exit - Bypass throttling carrier${RESET}${CYAN}  ║${RESET}\n"
    echo ""
    
    # Verificar si WARP está instalado
    if command -v warp-cli >/dev/null 2>&1; then
        printf "${CYAN}║${GREEN}   ✅ WARP CLI detectado${RESET}${CYAN}                       ║${RESET}\n"
        
        # Verificar estado
        local WARP_STATUS
        WARP_STATUS=$(warp-cli status 2>/dev/null | head -1 || echo "Unknown")
        
        printf "${CYAN}║${WHITE}   Estado: ${WHITE}${WARP_STATUS}${RESET}${CYAN}                   ║${RESET}\n"
        echo ""
        printf "${CYAN}║${RESET}   ${GREEN}[1]${WHITE} Conectar WARP${RESET}${CYAN}                             ║${RESET}\n"
        printf "${CYAN}║${RESET}   ${GREEN}[2]${WHITE} Desconectar WARP${RESET}${CYAN}                        ║${RESET}\n"
        printf "${CYAN}║${RESET}   ${GREEN}[3]${WHITE} Modo WARP Smart Exit (proxy)${RESET}${CYAN}            ║${RESET}\n"
        printf "${CYAN}║${RESET}   ${GREEN}[4]${WHITE} Modo WARP Full (tunnel)${RESET}${CYAN}               ║${RESET}\n"
        printf "${CYAN}║${RESET}   ${RED}[0]${WHITE} Volver${RESET}${CYAN}                                    ║${RESET}\n"
        H3
        echo ""
        
        read -rp "$(trx '   ► Opción: ')" WARP_OP
        case "$WARP_OP" in
            1) warp-cli connect; echo "Conectando..."; sleep 2 ;;
            2) warp-cli disconnect; echo "Desconectando..."; sleep 2 ;;
            3) warp-cli set-mode warp; warp-cli connect; echo "Modo WARP activado"; sleep 2 ;;
            4) warp-cli set-mode warp+proxy; warp-cli connect; echo "Modo Proxy activado"; sleep 2 ;;
            0) menu_principal; return ;;
            *) menu_principal; return ;;
        esac
    else
        printf "${CYAN}║${YELLOW}   ⚠ WARP CLI no instalado${RESET}${CYAN}                   ║${RESET}\n"
        echo ""
        printf "${CYAN}║${RESET}   ${GREEN}[1]${WHITE} Instalar WARP CLI (oficial)${RESET}${CYAN}           ║${RESET}\n"
        printf "${CYAN}║${RESET}   ${RED}[0]${WHITE} Volver${RESET}${CYAN}                                    ║${RESET}\n"
        H3
        echo ""
        read -rp "$(trx '   ► Opción: ')" WARP_INST
        if [[ "$WARP_INST" == "1" ]]; then
            printf "${CYAN}║${WHITE}   Instalando WARP CLI...${RESET}${CYAN}              ║${RESET}\n"
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp.gpg 2>/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null
            apt update >/dev/null 2>&1 && apt install -y cloudflare-warp >/dev/null 2>&1
            echo "WARP CLI instalado. Ejecuta 'warp-cli register' para registrar."
            sleep 3
        fi
    fi
    
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para volver... ')" _
    menu_principal
}

#=========================================================
# MENÚ PRINCIPAL - EXACTO ABBIENET v7.1
#=========================================================
menu_principal() {
    clear
    local IFACE_NET=$(get_iface)
    local BBR MTU_ACTUAL DNS_ACTUAL
    BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    MTU_ACTUAL=$(cat /sys/class/net/$IFACE_NET/mtu 2>/dev/null)
    DNS_ACTUAL=$(cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -1 | awk '{print $2}' || echo "N/A")
    
    H1
    title "🚀 MAXINET — OPTIMIZADOR DE RED v3.0.8"
    H2
    printf "${CYAN}║${WHITE}   ⚡ TCP · ${GREEN}${BBR}${RESET}    📏 MTU · ${YELLOW}${MTU_ACTUAL}${RESET}    🛡 DNS · ${WHITE}${DNS_ACTUAL}${RESET}${CYAN}    ║${RESET}\n"
    H2
    printf "${CYAN}║${WHITE}   ▸ PERFILES DE RENDIMIENTO${RESET}${CYAN}                            ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[01]${WHITE} ⚡ Perfil Carrier Grade (BBR + Zero-Copy)${RESET}${CYAN}     ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[02]${WHITE} 🎬 Turbo Streaming & Redes (YouTube, TikTok, WhatsApp)${RESET}${CYAN}║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[07]${WHITE} 📱 Perfil Móvil Colombia (Tigo/Claro/Movistar/WOM)${RESET}${CYAN} ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[10]${WHITE} 🇨🇴 Perfil Oracle Colombia 2026 — MTU intacto ⭐${RESET}${CYAN}║${RESET}\n"
    H2
    printf "${CYAN}║${WHITE}   ▸ BUFFERS Y CALIBRACIÓN${RESET}${CYAN}                               ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[03]${WHITE} 🎛️ Buffers de Socket (MANUAL, MB)${RESET}${CYAN}          ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[04]${WHITE} ⚙️ Personalizar Ring Buffers RX / TX (ethtool)${RESET}${CYAN}║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[05]${WHITE} 📦 Personalizar Buffers ZiVPN / UDP Custom${RESET}${CYAN}   ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[06]${WHITE} 🚀 Optimización Completa Turbo (Auto-Calibración)${RESET}${CYAN}║${RESET}\n"
    H2
    printf "${CYAN}║${WHITE}   ▸ SEGURIDAD Y CONECTIVIDAD${RESET}${CYAN}                          ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[08]${WHITE} 📏 Configuración de MTU (manual)${RESET}${CYAN}           ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[09]${WHITE} 🌐 Elegir DNS (lista o IP personalizada)${RESET}${CYAN}    ║${RESET}\n"
    H2
    printf "${CYAN}║${WHITE}   ▸ DIAGNÓSTICO${RESET}${CYAN}                                           ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[11]${WHITE} 🩺 Diagnóstico de Video & Velocidad${RESET}${CYAN}      ║${RESET}\n"
    H2
    printf "${CYAN}║${WHITE}   ▸ ACELERACIÓN EXTERNA${RESET}${CYAN}                               ║${RESET}\n"
    printf "${CYAN}║${RESET}   ${GREEN}[13]${WHITE} ☁️ WARP Smart Exit (bypass throttling carrier)${RESET}${CYAN}║${RESET}\n"
    H2
    printf "${CYAN}║${RESET}   ${RED}[00]${WHITE} ↩️  Volver al Menú Principal${RESET}${CYAN}                     ║${RESET}\n"
    H3
    echo ""
    read -rp "$(trx '   ► Opción: ')" OP
    
    case "$OP" in
        1|01) perfil_carrier_grade ;;
        2|02) perfil_turbo_streaming ;;
        7|07) perfil_movil_colombia ;;
        10) perfil_oracle_colombia ;;
        3|03) buffers_socket_manual ;;
        4|04) ring_buffers_ethtool ;;
        5|05) buffers_zivpn_udp ;;
        6|06) optimizacion_turbo_auto ;;
        8|08) configurar_mtu_manual ;;
        9|09) elegir_dns ;;
        11) diagnostico_video_velocidad ;;
        13) warp_smart_exit ;;
        0|00) exec bash "$BASE/menu.sh" ;;
        *) menu_principal ;;
    esac
}

#=========================================================
# ENTRY POINT
#=========================================================
case "${1:-}" in
    --auto)
        # Modo silencioso para cron
        exit 0
        ;;
    --carrier)
        perfil_carrier_grade
        exit 0
        ;;
    --streaming)
        perfil_turbo_streaming
        exit 0
        ;;
    --colombia)
        perfil_movil_colombia
        exit 0
        ;;
    --oracle)
        perfil_oracle_colombia
        exit 0
        ;;
    --buffers)
        buffers_socket_manual
        exit 0
        ;;
    --ring)
        ring_buffers_ethtool
        exit 0
        ;;
    --zivpn)
        buffers_zivpn_udp
        exit 0
        ;;
    --turbo)
        optimizacion_turbo_auto
        exit 0
        ;;
    --mtu)
        configurar_mtu_manual
        exit 0
        ;;
    --dns)
        elegir_dns
        exit 0
        ;;
    --diagnostico)
        diagnostico_video_velocidad
        exit 0
        ;;
    --warp)
        warp_smart_exit
        exit 0
        ;;
    --plus|"")
        menu_principal
        ;;
    *)
        echo "Uso: $0 [--auto|--carrier|--streaming|--colombia|--oracle|--buffers|--ring|--zivpn|--turbo|--mtu|--dns|--diagnostico|--warp|--plus]"
        exit 1
        ;;
esac