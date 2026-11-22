#!/bin/bash
#==================================================
# Maxinet Network Premium v2.5
# ZiVPN UDP Manager [ Suite Completa 17 Funciones ]
# Portado y adaptado desde motor oficial v7
#==================================================

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null

DIR_ZIVPN="/etc/zivpn"
CONFIG_JSON="$DIR_ZIVPN/config.json"
CADUCIDAD_DB="$DIR_ZIVPN/caducidad.db"
LIMITES_DB="$DIR_ZIVPN/limites.db"
CONEX_DB="$DIR_ZIVPN/conexiones.db"
PASS_TXT="$BASE/zivpn/passwords.txt"

mkdir -p "$DIR_ZIVPN" "$BASE/zivpn" 2>/dev/null
touch "$CADUCIDAD_DB" "$LIMITES_DB" "$CONEX_DB" 2>/dev/null

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
C_B_MAGENTA="\033[1;35m"
C_TURQUESA="\033[38;5;45m"
C_DORADO="\033[38;5;220m"
C_GRIS="\033[38;5;245m"
ZV_B="$C_B_AZUL"

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
    local tipo="$1" titulo="$2" color_borde="${3:-$ZV_B}"
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
    local content="$1" color_borde="${2:-$ZV_B}"
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
    local content="$1" color_borde="${2:-$ZV_B}"
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

imprimir_linea_info() {
    local icono="$1" etiqueta="$2" separador="$3" valor="$4" color_borde="${5:-$ZV_B}" ancho_etiqueta="${6:-20}"
    local vis_etiq
    vis_etiq=$(ansi_ancho "$etiqueta")
    local pad_etiq=$(( ancho_etiqueta - vis_etiq ))
    (( pad_etiq < 0 )) && pad_etiq=0
    local sp_etiq=""
    (( pad_etiq > 0 )) && sp_etiq=$(printf '%*s' "$pad_etiq" '')
    local izq="${icono} ${C_B_BLANCO}${etiqueta}${sp_etiq} ${separador}${C_RESET} ${valor}"
    imprimir_linea_caja "  $izq" "$color_borde"
}

_titulo_seccion() {
    echo ""
    echo -e " ${C_DORADO}◆${C_RESET} ${C_B_BLANCO}$1${C_RESET}"
}

_zv_cabecera() {
    _titulo_seccion "$1"
    _borde_caja top "◈ MAXINET · $2 v2.5 ◈" "$ZV_B"
}

_zv_grupo() {
    _borde_caja sep "◆ $1 " "$ZV_B"
}

_zv_dato() {
    imprimir_linea_info " $1" "$2" "┃" "$3" "$ZV_B" "${4:-20}"
}

_zv_opcion_fila() {
    local izq
    izq=$(rellenar_ancho "$1" 32)
    imprimir_linea_caja "  ${izq}$2" "$ZV_B"
}

_zv_aviso() {
    imprimir_linea_caja "  ${1}" "$ZV_B"
}

_zv_pie() {
    _borde_caja bottom "" "$ZV_B"
    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

get_dev_interfaz() {
    local dev=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    [[ -z "$dev" ]] && dev=$(ip link show up 2>/dev/null | awk -F': ' '/state UP/ && $2!="lo"{print $2;exit}')
    echo "${dev:-eth0}"
}

configurar_firewall_zivpn() {
    local PUERTO="$1"
    [[ -z "$PUERTO" ]] && PUERTO="5667"
    local DEV=$(get_dev_interfaz)

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    while iptables -t nat -D PREROUTING -p udp -m udp --dport 6000:19999 -j DNAT --to-destination ":$PUERTO" 2>/dev/null; do :; done
    while iptables -t nat -D PREROUTING -i "$DEV" -p udp -m udp --dport 6000:19999 -j DNAT --to-destination ":$PUERTO" 2>/dev/null; do :; done
    while iptables -D INPUT -p udp --dport "$PUERTO" -j ACCEPT 2>/dev/null; do :; done

    iptables -I INPUT 1 -p udp --dport "$PUERTO" -j ACCEPT 2>/dev/null
    iptables -t nat -A PREROUTING -p udp -m udp --dport 6000:19999 -j REDIRECT --to-port "$PUERTO" 2>/dev/null
}

crear_auth_zivpn() {
    mkdir -p "$DIR_ZIVPN" 2>/dev/null
    cat > "$DIR_ZIVPN/auth.sh" << 'AUTHEOF'
#!/bin/bash
ADDR="${1:-}"
AUTH="${2:-}"
TX="${3:-0}"
DIR="/etc/zivpn"
CFG="$DIR/config.json"
CAD="$DIR/caducidad.db"
CONEX_DB="$DIR/conexiones.db"
AUTH_TEST="${MAXINET_AUTH_TEST:-0}"

[ -z "$AUTH" ] && exit 1

OK=0
if [ -f "$CFG" ] && command -v jq >/dev/null 2>&1; then
    if jq -e --arg p "$AUTH" '(.auth.config // .passwords // .config // []) | index($p) != null' "$CFG" >/dev/null 2>&1; then
        OK=1
    fi
fi

if [ "$OK" = 1 ] && [ -f "$CAD" ]; then
    EXP=$(awk -F':' -v k="$AUTH" '$1 == k { print $2; exit }' "$CAD" 2>/dev/null)
    if [ -n "$EXP" ] && [ "$EXP" != "Ilimitado" ]; then
        HOY=$(date +%Y-%m-%d 2>/dev/null)
        if [ -n "$HOY" ] && [ "$HOY" \> "$EXP" ]; then OK=0; fi
    fi
fi

FECHA=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
if [ "$OK" = 1 ]; then RES="ok"; else RES="rechazado"; fi

if [ "$AUTH_TEST" != "1" ]; then
    printf '%s|%s|%s|%s|%s\n' "$FECHA" "$ADDR" "$AUTH" "$TX" "$RES" >> "$CONEX_DB" 2>/dev/null
    chmod 600 "$CONEX_DB" 2>/dev/null
    if [ "$(wc -l < "$CONEX_DB" 2>/dev/null || echo 0)" -gt 20000 ]; then
        tail -n 10000 "$CONEX_DB" > "$CONEX_DB.pod" 2>/dev/null && mv -f "$CONEX_DB.pod" "$CONEX_DB" 2>/dev/null
    fi
fi

if [ "$OK" = 1 ]; then
    printf '%s\n' "$AUTH"
    exit 0
fi
exit 1
AUTHEOF
    chmod 700 "$DIR_ZIVPN/auth.sh" 2>/dev/null
    [[ -x "$DIR_ZIVPN/auth.sh" ]]
}

reinstalar_zivpn() {
    local SILENT=false
    [[ "$1" == "--silent" ]] && SILENT=true

    if [ "$SILENT" = false ]; then
        clear
        _titulo_seccion "⬇️ INSTALACIÓN · ZIVPN UDP OFICIAL"
        _borde_caja top "◈ MAXINET · INSTALAR v2.5 ◈" "$ZV_B"
        _zv_dato "📦" "Paquetes" "${C_DIM}jq · openssl · iptables${C_RESET}"
        _zv_dato "🔐" "Auth"     "${C_DIM}command (bitácora IP↔clave)${C_RESET}"
        _zv_dato "🚀" "Servicio" "${C_DIM}zivpn.service · Nice -20${C_RESET}"
        _borde_caja bottom "" "$ZV_B"
        echo ""
    fi

    local PUERTO="5667"
    if [[ -f "$CONFIG_JSON" ]]; then
        local P_ACT=$(jq -r '.listen' "$CONFIG_JSON" 2>/dev/null | tr -d ':')
        [[ -n "$P_ACT" && "$P_ACT" != "null" ]] && PUERTO="$P_ACT"
    fi

    if [ "$SILENT" = false ]; then
        read -rp " Puerto UDP para ZiVPN [Por defecto: $PUERTO]: " N_PORT
        [[ -n "$N_PORT" && "$N_PORT" =~ ^[0-9]+$ ]] && PUERTO="$N_PORT"
    fi

    msg_info "Deteniendo servicios previos..."
    systemctl stop zivpn.service >/dev/null 2>&1
    systemctl stop maxinet-zivpn.service >/dev/null 2>&1
    pkill -9 -f "zivpn" 2>/dev/null

    msg_info "Instalando dependencias (jq, openssl, iptables)..."
    apt-get update -y >/dev/null 2>&1
    apt-get install -y jq curl wget openssl iptables libc6-i386 >/dev/null 2>&1

    local ARCH=$(uname -m)
    local BIN_URL=""
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        msg_info "Arquitectura ARM64 detectada..."
        BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm64"
    else
        msg_info "Arquitectura x86_64 / AMD64 detectada..."
        BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
    fi

    mkdir -p "$DIR_ZIVPN" 2>/dev/null

    # Fallback local primero si existe en el repo de Maxinet
    if [[ -f "$BASE/vendor/usr-local-bin/zivpn" && -s "$BASE/vendor/usr-local-bin/zivpn" ]]; then
        cp -f "$BASE/vendor/usr-local-bin/zivpn" /usr/local/bin/zivpn 2>/dev/null
    fi

    if [[ ! -s /usr/local/bin/zivpn || $(wc -c < /usr/local/bin/zivpn 2>/dev/null || echo 0) -lt 1000000 ]]; then
        msg_info "Descargando binario oficial ZiVPN 1.4.9..."
        curl -sSL --retry 3 --connect-timeout 10 "$BIN_URL" -o /usr/local/bin/zivpn 2>/dev/null || \
        wget -q "$BIN_URL" -O /usr/local/bin/zivpn 2>/dev/null
    fi
    chmod +x /usr/local/bin/zivpn

    if [[ -x /usr/local/bin/zivpn ]]; then
        echo "1.4.9" > "$DIR_ZIVPN/version"
    fi

    msg_info "Generando certificados SSL (RSA 4096 ZiVPN)..."
    openssl req -new -newkey rsa:4096 -nodes -x509 -days 3650 \
        -subj "/C=US/ST=CA/L=LA/O=Maxinet/CN=zivpn" \
        -keyout "$DIR_ZIVPN/zivpn.key" -out "$DIR_ZIVPN/zivpn.crt" >/dev/null 2>&1
    chmod 600 "$DIR_ZIVPN/zivpn.key"
    chmod 644 "$DIR_ZIVPN/zivpn.crt"

    local PASS_INICIAL='["maxinet", "123", "2026"]'
    if [[ -f "$CONFIG_JSON" ]] && jq -e '.auth.config | length > 0' "$CONFIG_JSON" >/dev/null 2>&1; then
        PASS_INICIAL=$(jq -c '.auth.config' "$CONFIG_JSON")
    fi

    crear_auth_zivpn

    cat > "$CONFIG_JSON" << ZEOF
{
    "listen": ":$PUERTO",
    "cert": "$DIR_ZIVPN/zivpn.crt",
    "key": "$DIR_ZIVPN/zivpn.key",
    "obfs": "",
    "auth": {
        "mode": "command",
        "command": "$DIR_ZIVPN/auth.sh",
        "config": $PASS_INICIAL
    }
}
ZEOF
    chmod 600 "$CONFIG_JSON"

    cat > /etc/systemd/system/zivpn.service << EOF
[Unit]
Description=ZiVPN UDP Server [ Maxinet v2.5 ]
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$DIR_ZIVPN
ExecStart=/usr/local/bin/zivpn server -c $CONFIG_JSON
Restart=always
RestartSec=1s
Nice=-20
LimitNOFILE=1048576
LimitNPROC=512000
TasksMax=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

    ln -sf /etc/systemd/system/zivpn.service /etc/systemd/system/maxinet-zivpn.service 2>/dev/null

    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1

    systemctl daemon-reload
    systemctl enable zivpn.service >/dev/null 2>&1
    systemctl restart zivpn.service >/dev/null 2>&1

    configurar_firewall_zivpn "$PUERTO"

    sleep 2
    if systemctl is-active --quiet zivpn.service; then
        msg_ok "¡Servidor ZiVPN instalado y activo exitosamente en puerto $PUERTO UDP!"
    else
        msg_err "El servicio tuvo un problema al iniciar."
    fi

    if [ "$SILENT" = false ]; then
        echo ""
        read -rp " Presione [Enter] para continuar..." _
    fi
}

reiniciar_zivpn() {
    msg_info "Reiniciando servicio ZiVPN..."
    systemctl daemon-reload
    systemctl restart zivpn.service >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet zivpn.service; then
        msg_ok "Servicio ZiVPN reiniciado correctamente 🟢"
    else
        msg_err "Error al reiniciar ZiVPN 🔴"
    fi
    sleep 1
}

estado_zivpn() {
    clear
    [[ ! -f "$CONFIG_JSON" ]] && { msg_err "ZiVPN no está instalado."; sleep 2; return; }

    local STATUS="${C_B_ROJO}🔴 DETENIDO${C_RESET}"
    systemctl is-active --quiet zivpn.service && STATUS="${C_B_VERDE}🟢 ACTIVO${C_RESET}"

    local PUERTO=$(jq -r '.listen' "$CONFIG_JSON" 2>/dev/null | tr -d ':')
    [[ -z "$PUERTO" || "$PUERTO" == "null" ]] && PUERTO="5667"

    local CLAVES=$(jq '.auth.config | length' "$CONFIG_JSON" 2>/dev/null)
    [[ -z "$CLAVES" || "$CLAVES" == "null" ]] && CLAVES=0
    local MODO=$(jq -r '.auth.mode // "passwords"' "$CONFIG_JSON" 2>/dev/null)

    _zv_cabecera "📋 ESTADO DEL SERVICIO" "ESTADO"
    _zv_dato "🚦" "Servicio"     "$STATUS"
    _zv_dato "🌐" "Puerto UDP"   "${C_B_AMARILLO}${PUERTO}${C_RESET}  ${C_DIM}· hopping 6000-19999${C_RESET}"
    _zv_dato "🖥️" "Arquitectura" "$(uname -m)"
    _zv_dato "🔑" "Claves"       "${C_B_CIAN}${CLAVES}${C_RESET}  ${C_DIM}· auth: ${MODO}${C_RESET}"
    _zv_dato "📄" "Config"       "${C_DIM}${CONFIG_JSON}${C_RESET}"
    _borde_caja bottom "" "$ZV_B"
    echo ""
    _titulo_seccion "▶ SALIDA DE systemctl status"
    systemctl --no-pager --full status zivpn.service 2>/dev/null | head -n 14
    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

agregar_clave_zivpn() {
    clear
    [[ ! -f "$CONFIG_JSON" ]] && { msg_err "ZiVPN no está instalado."; sleep 2; return; }

    _zv_cabecera "➕ NUEVA CONTRASEÑA ZIVPN" "AGREGAR"
    _zv_dato "✏️" "Contraseña" "${C_DIM}visible al escribirla${C_RESET}"
    _zv_dato "✏️" "Vigencia"   "${C_DIM}días · vacío = ilimitado${C_RESET}"
    _zv_dato "✏️" "Límite"     "${C_DIM}GB · vacío = ilimitado${C_RESET}"
    _borde_caja bottom "" "$ZV_B"
    echo ""

    echo -ne " 🔑 Contraseña: "
    read PASS
    PASS=$(echo "$PASS" | tr -d '\r' | xargs)
    [[ -z "$PASS" ]] && { msg_err "La contraseña no puede estar vacía."; sleep 2; return; }

    if jq -e --arg p "$PASS" '.auth.config[] | select(.==$p)' "$CONFIG_JSON" >/dev/null 2>&1; then
        msg_warn "La contraseña ya existe."
        sleep 2
        return
    fi

    local TMP=$(mktemp)
    jq --arg p "$PASS" '.auth.config += [$p]' "$CONFIG_JSON" > "$TMP" && mv "$TMP" "$CONFIG_JSON"
    chmod 600 "$CONFIG_JSON"
    reiniciar_zivpn >/dev/null 2>&1

    echo -e " ${C_B_VERDE}✔${C_RESET} Contraseña ${C_B_AMARILLO}${PASS}${C_RESET} agregada al túnel.\n"

    echo -ne " 📅 Duración en días (Enter = ilimitado): "
    read DIAS
    DIAS=$(echo "$DIAS" | tr -d '\r' | xargs)
    if [[ -n "$DIAS" && "$DIAS" =~ ^[0-9]+$ ]]; then
        local FECHA_EXP=$(date -d "+$DIAS days" +"%Y-%m-%d" 2>/dev/null)
        sed -i "/^$PASS:/d" "$CADUCIDAD_DB" 2>/dev/null
        echo "$PASS:$FECHA_EXP" >> "$CADUCIDAD_DB"
    else
        sed -i "/^$PASS:/d" "$CADUCIDAD_DB" 2>/dev/null
        echo "$PASS:Ilimitado" >> "$CADUCIDAD_DB"
    fi

    echo -ne " 📦 Límite de tráfico en GB (Enter = ilimitado): "
    read GB
    GB=$(echo "$GB" | tr -d '\r' | xargs)
    if [[ -n "$GB" && "$GB" =~ ^[0-9]+$ ]]; then
        sed -i "/^$PASS:/d" "$LIMITES_DB" 2>/dev/null
        echo "$PASS:${GB}GB" >> "$LIMITES_DB"
    else
        sed -i "/^$PASS:/d" "$LIMITES_DB" 2>/dev/null
        echo "$PASS:Ilimitado" >> "$LIMITES_DB"
    fi

    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

eliminar_clave_zivpn() {
    clear
    [[ ! -f "$CONFIG_JSON" ]] && { msg_err "ZiVPN no está instalado."; sleep 2; return; }

    mapfile -t PASSLIST < <(jq -r '.auth.config[]' "$CONFIG_JSON" 2>/dev/null)
    if [[ ${#PASSLIST[@]} -eq 0 ]]; then
        msg_warn "No existen contraseñas registradas en ZiVPN."
        sleep 2
        return
    fi

    if [[ ${#PASSLIST[@]} -le 1 ]]; then
        _zv_cabecera "🗑️ ELIMINAR CONTRASEÑA" "ELIMINAR"
        _zv_aviso "${C_B_ROJO}⚠ ZiVPN necesita al menos 1 clave activa.${C_RESET}"
        _zv_aviso "Única clave: ${C_B_VERDE}$(truncar_texto "${PASSLIST[0]}" 44)${C_RESET}"
        _zv_pie
        return
    fi

    _zv_cabecera "🗑️ ELIMINAR CONTRASEÑA" "ELIMINAR"
    _zv_dato "🔑" "Claves" "${C_B_CIAN}${#PASSLIST[@]}${C_RESET}  ${C_DIM}· elige una para borrar${C_RESET}"
    _zv_grupo "SELECCIONA"

    local i pass exp
    for ((i=0; i<${#PASSLIST[@]}; i++)); do
        pass="${PASSLIST[$i]}"
        exp=$(grep "^$pass:" "$CADUCIDAD_DB" 2>/dev/null | cut -d: -f2)
        [[ -z "$exp" ]] && exp="Ilimitado"
        _zv_aviso "${C_B_CIAN}[$(printf '%02d' $((i+1)))]${C_RESET} 🔑 ${C_B_AMARILLO}$(truncar_texto "$pass" 30)${C_RESET} ${C_DIM}(${exp})${C_RESET}"
    done
    _zv_aviso "${C_B_ROJO}[00]${C_RESET} ↩ Cancelar y volver"
    _borde_caja bottom "" "$ZV_B"
    echo ""

    read -rp " Número a eliminar: " OP
    [[ -z "$OP" || "$OP" == "0" || "$OP" == "00" ]] && return

    if [[ ! "$OP" =~ ^[0-9]+$ ]] || (( OP < 1 || OP > ${#PASSLIST[@]} )); then
        msg_err "Opción inválida."
        sleep 1
        return
    fi

    local PASS_DEL="${PASSLIST[$((OP-1))]}"
    local TMP=$(mktemp)
    jq --arg p "$PASS_DEL" '.auth.config |= map(select(. != $p))' "$CONFIG_JSON" > "$TMP" && mv "$TMP" "$CONFIG_JSON"
    chmod 600 "$CONFIG_JSON"
    sed -i "/^$PASS_DEL:/d" "$CADUCIDAD_DB" 2>/dev/null
    sed -i "/^$PASS_DEL:/d" "$LIMITES_DB" 2>/dev/null
    [[ -s "$CONEX_DB" ]] && awk -F'|' -v p="$PASS_DEL" '$3 != p' "$CONEX_DB" > "$CONEX_DB.tmp" && mv "$CONEX_DB.tmp" "$CONEX_DB"

    reiniciar_zivpn
    msg_ok "Contraseña '$PASS_DEL' eliminada exitosamente."
    sleep 2
}

listar_claves_zivpn() {
    clear
    [[ ! -f "$CONFIG_JSON" ]] && { msg_err "ZiVPN no está instalado."; sleep 2; return; }

    local TOTAL=$(jq '.auth.config | length' "$CONFIG_JSON" 2>/dev/null || echo 0)
    local PUERTO=$(jq -r '.listen' "$CONFIG_JSON" 2>/dev/null | tr -d ':')
    [[ -z "$PUERTO" || "$PUERTO" == "null" ]] && PUERTO="5667"

    _zv_cabecera "🔑 CONTRASEÑAS ZIVPN" "CLAVES"
    _zv_dato "🔑" "Total" "${C_B_VERDE}${TOTAL}${C_RESET}  ${C_DIM}·${C_RESET}  UDP ${PUERTO}"
    _zv_grupo "LISTADO"
    imprimir_linea_caja "  ${C_B_BLANCO}$(rellenar_ancho 'N°' 4)$(rellenar_ancho 'CONTRASEÑA' 26)$(rellenar_ancho 'VENCE' 14)LÍMITE${C_RESET}" "$ZV_B"

    local i=1
    while IFS= read -r pass; do
        [[ -z "$pass" ]] && continue
        local exp=$(grep "^$pass:" "$CADUCIDAD_DB" 2>/dev/null | cut -d: -f2)
        [[ -z "$exp" ]] && exp="Ilimitado"
        local lim=$(grep "^$pass:" "$LIMITES_DB" 2>/dev/null | cut -d: -f2)
        [[ -z "$lim" ]] && lim="Sin límite"

        imprimir_linea_caja "  ${C_B_CIAN}$(printf '%02d' "$i")${C_RESET}  $(rellenar_ancho "$(truncar_texto "$pass" 24)" 26)$(rellenar_ancho "$exp" 14)${lim}" "$ZV_B"
        i=$(( i + 1 ))
    done < <(jq -r '.auth.config[]' "$CONFIG_JSON" 2>/dev/null)

    local IP_PUB=$(cat "$BASE/.pub_ip" 2>/dev/null || curl -s --max-time 2 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    local DOM_HOST=$(cat "$BASE/dominio" 2>/dev/null || echo "$IP_PUB")
    _zv_grupo "DATOS PARA APLICACIÓN"
    _zv_aviso "${C_DIM}udp server = ${DOM_HOST}${C_RESET}"
    _zv_aviso "${C_DIM}udp port   = ${PUERTO}${C_RESET}"
    _zv_pie
}

asignar_caducidad_zivpn() {
    clear
    _zv_cabecera "⏳ ASIGNAR CADUCIDAD" "CADUCIDAD"
    mapfile -t PASSLIST < <(jq -r '.auth.config[]' "$CONFIG_JSON" 2>/dev/null)
    [[ ${#PASSLIST[@]} -eq 0 ]] && { msg_err "No hay contraseñas registradas."; sleep 2; return; }

    _zv_dato "🔑" "Claves" "${C_B_CIAN}${#PASSLIST[@]}${C_RESET}  ${C_DIM}· elige una${C_RESET}"
    _zv_grupo "SELECCIONA"
    for ((i=0; i<${#PASSLIST[@]}; i++)); do
        _zv_aviso "${C_B_CIAN}[$(printf '%02d' $((i+1)))]${C_RESET} 🔑 $(truncar_texto "${PASSLIST[$i]}" 52)"
    done
    _borde_caja bottom "" "$ZV_B"
    echo ""
    read -rp " Número: " OP
    [[ ! "$OP" =~ ^[0-9]+$ ]] || (( OP < 1 || OP > ${#PASSLIST[@]} )) && return

    local PASS="${PASSLIST[$((OP-1))]}"
    read -rp " Días de validez para '$PASS' (ejemplo: 30): " DIAS
    [[ ! "$DIAS" =~ ^[0-9]+$ ]] && { msg_err "Número inválido."; sleep 2; return; }

    local FECHA_EXP=$(date -d "+$DIAS days" +"%Y-%m-%d" 2>/dev/null)
    sed -i "/^$PASS:/d" "$CADUCIDAD_DB" 2>/dev/null
    echo "$PASS:$FECHA_EXP" >> "$CADUCIDAD_DB"

    msg_ok "Caducidad para '$PASS' asignada al: ${C_B_VERDE}$FECHA_EXP${C_RESET} ($DIAS días)."
    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

eliminar_vencidas_zivpn() {
    clear
    _zv_cabecera "🧹 ELIMINAR CONTRASEÑAS VENCIDAS" "VENCIDAS"
    _zv_aviso "${C_DIM}Compara caducidad.db con la fecha actual y borra claves vencidas.${C_RESET}"
    _borde_caja bottom "" "$ZV_B"
    echo ""

    local HOY=$(date +"%Y-%m-%d")
    local BORRADAS=0

    while IFS=: read -r pass exp; do
        [[ -z "$pass" || -z "$exp" ]] && continue
        if [[ "$exp" != "Ilimitado" && "$HOY" > "$exp" ]]; then
            msg_warn "Contraseña '$pass' vencida el $exp. Eliminando..."
            local TMP=$(mktemp)
            jq --arg p "$pass" '.auth.config |= map(select(. != $p))' "$CONFIG_JSON" > "$TMP" && mv "$TMP" "$CONFIG_JSON"
            sed -i "/^$pass:/d" "$CADUCIDAD_DB" 2>/dev/null
            sed -i "/^$pass:/d" "$LIMITES_DB" 2>/dev/null
            [[ -s "$CONEX_DB" ]] && awk -F'|' -v p="$pass" '$3 != p' "$CONEX_DB" > "$CONEX_DB.tmp" && mv "$CONEX_DB.tmp" "$CONEX_DB"
            let BORRADAS++
        fi
    done < "$CADUCIDAD_DB"

    if [[ $BORRADAS -gt 0 ]]; then
        chmod 600 "$CONFIG_JSON"
        reiniciar_zivpn
        msg_ok "Se eliminaron $BORRADAS contraseñas vencidas."
    else
        msg_ok "No hay contraseñas vencidas en el sistema."
    fi
    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

asignar_limite_gb_zivpn() {
    clear
    _zv_cabecera "📦 ASIGNAR LÍMITE DE GB" "LÍMITE"
    mapfile -t PASSLIST < <(jq -r '.auth.config[]' "$CONFIG_JSON" 2>/dev/null)
    [[ ${#PASSLIST[@]} -eq 0 ]] && { msg_err "No hay contraseñas registradas."; sleep 2; return; }

    _zv_dato "🔑" "Claves" "${C_B_CIAN}${#PASSLIST[@]}${C_RESET}"
    _zv_grupo "SELECCIONA"
    for ((i=0; i<${#PASSLIST[@]}; i++)); do
        _zv_aviso "${C_B_CIAN}[$(printf '%02d' $((i+1)))]${C_RESET} 🔑 $(truncar_texto "${PASSLIST[$i]}" 52)"
    done
    _borde_caja bottom "" "$ZV_B"
    echo ""
    read -rp " Número: " OP
    [[ ! "$OP" =~ ^[0-9]+$ ]] || (( OP < 1 || OP > ${#PASSLIST[@]} )) && return

    local PASS="${PASSLIST[$((OP-1))]}"
    read -rp " Límite en GB para '$PASS' (ejemplo: 50): " GB
    [[ ! "$GB" =~ ^[0-9]+$ ]] && { msg_err "Cantidad inválida."; sleep 2; return; }

    sed -i "/^$PASS:/d" "$LIMITES_DB" 2>/dev/null
    echo "$PASS:${GB}GB" >> "$LIMITES_DB"

    msg_ok "Límite para '$PASS' asignado a: ${C_B_VERDE}${GB} GB${C_RESET}."
    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

consumo_bloqueos_zivpn() {
    clear
    local PUERTO=$(jq -r '.listen' "$CONFIG_JSON" 2>/dev/null | tr -d ':')
    [[ -z "$PUERTO" || "$PUERTO" == "null" ]] && PUERTO="5667"

    _zv_cabecera "📊 CONSUMO & BLOQUEOS" "CONSUMO"
    _zv_dato "🌐" "Puerto UDP" "${C_B_AMARILLO}${PUERTO}${C_RESET}"
    _zv_grupo "TRÁFICO EN IPTABLES"

    local TRAF=$(iptables -L -v -n 2>/dev/null | grep -E "dpt:$PUERTO|dpts:6000:19999")
    if [[ -n "$TRAF" ]]; then
        while IFS= read -r l; do
            imprimir_linea_caja "  $(truncar_texto "$l" 62)" "$ZV_B"
        done <<< "$TRAF"
    else
        _zv_aviso "${C_DIM}(sin tráfico registrado aún)${C_RESET}"
    fi
    _zv_pie
}

ver_conectados_zivpn() {
    clear
    _zv_cabecera "👥 CLIENTES ZIVPN CONECTADOS" "CONEXIONES"
    local PUERTO=$(jq -r '.listen' "$CONFIG_JSON" 2>/dev/null | tr -d ':')
    [[ -z "$PUERTO" || "$PUERTO" == "null" ]] && PUERTO="5667"

    _zv_dato "🌐" "Puerto UDP" "${C_B_AMARILLO}${PUERTO}${C_RESET}"
    _zv_grupo "CONEXIONES ACTIVAS"

    local SOCKS=$(ss -u -a 2>/dev/null | grep ":$PUERTO ")
    local LINEAS=0
    if [[ -s "$CONEX_DB" ]]; then
        while IFS='|' read -r fecha ip pass tx res; do
            [[ "$res" != "ok" ]] && continue
            imprimir_linea_caja "  ${C_B_VERDE}●${C_RESET} ${ip} 🔑 ${C_B_AMARILLO}${pass}${C_RESET} (${fecha})" "$ZV_B"
            LINEAS=$(( LINEAS + 1 ))
        done < <(tail -n 15 "$CONEX_DB")
    fi

    if [[ $LINEAS -eq 0 ]]; then
        _zv_aviso "${C_DIM}(sin sesiones recientes registradas en bitácora)${C_RESET}"
    fi
    _zv_pie
}

turbo_latencia_udp() {
    clear
    _zv_cabecera "⚡ TURBO LATENCIA UDP" "OPTIMIZACIÓN"
    _zv_aviso "Aplicando buffers de alta velocidad para streaming y juegos..."
    _borde_caja bottom "" "$ZV_B"
    echo ""

    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1
    sysctl -w net.core.rmem_default=33554432 >/dev/null 2>&1
    sysctl -w net.core.wmem_default=33554432 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_rmem_min=16384 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_wmem_min=16384 >/dev/null 2>&1

    msg_ok "Buffers UDP ampliados a 64MB y mínima latencia activada."
    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

alternar_auth_zivpn() {
    clear
    [[ -f "$CONFIG_JSON" ]] || { msg_err "No existe $CONFIG_JSON."; sleep 2; return; }

    local modo_actual=$(jq -r '.auth.mode // "passwords"' "$CONFIG_JSON" 2>/dev/null)
    [[ -z "$modo_actual" || "$modo_actual" == "null" ]] && modo_actual="passwords"

    _zv_cabecera "🔑 MODO DE AUTENTICACIÓN" "AUTH"
    _zv_dato "📌" "Modo actual" "${C_B_AMARILLO}${modo_actual}${C_RESET}"
    if [[ "$modo_actual" == "command" ]]; then
        _zv_dato "🎯" "Modo destino" "${C_B_ROJO}passwords${C_RESET} ${C_DIM}· sin bitácora IP↔clave${C_RESET}"
    else
        _zv_dato "🎯" "Modo destino" "${C_B_VERDE}command${C_RESET} ${C_DIM}· registra IP+clave${C_RESET}"
    fi
    _borde_caja bottom "" "$ZV_B"
    echo ""
    read -rp " ¿Cambiar modo y reiniciar ZiVPN? [s/N]: " R
    [[ ! "$R" =~ ^[Ss]$ ]] && return

    if [[ "$modo_actual" == "command" ]]; then
        local TMP=$(mktemp)
        jq '.auth.mode = "passwords" | del(.auth.command)' "$CONFIG_JSON" > "$TMP" && mv "$TMP" "$CONFIG_JSON"
        chmod 600 "$CONFIG_JSON"
        msg_ok "Auth cambiada a passwords."
    else
        crear_auth_zivpn
        local TMP=$(mktemp)
        jq '.auth.mode = "command" | .auth.command = "'"$DIR_ZIVPN"'/auth.sh"' "$CONFIG_JSON" > "$TMP" && mv "$TMP" "$CONFIG_JSON"
        chmod 600 "$CONFIG_JSON"
        msg_ok "Auth en modo command (registro en tiempo real activo)."
    fi
    reiniciar_zivpn
}

diagnostico_zivpn() {
    clear
    local PUERTO=$(jq -r '.listen' "$CONFIG_JSON" 2>/dev/null | tr -d ':')
    [[ -z "$PUERTO" || "$PUERTO" == "null" ]] && PUERTO="5667"

    _titulo_seccion "🩺 DIAGNÓSTICO EN VIVO · ZIVPN"
    echo ""

    echo -ne " [1] Binario /usr/local/bin/zivpn: "
    if [[ -x /usr/local/bin/zivpn ]]; then
        local sz=$(ls -lh /usr/local/bin/zivpn | awk '{print $5}')
        echo -e "${C_B_VERDE}PRESENTE ($sz) 🟢${C_RESET}"
    else
        echo -e "${C_B_ROJO}FALTA BINARIO 🔴${C_RESET}"
    fi

    echo -ne " [2] Certificados SSL (/etc/zivpn): "
    if [[ -f "$DIR_ZIVPN/zivpn.crt" && -f "$DIR_ZIVPN/zivpn.key" ]]; then
        echo -e "${C_B_VERDE}CORRECTOS (RSA 4096) 🟢${C_RESET}"
    else
        echo -e "${C_B_ROJO}FALTAN CERTIFICADOS 🔴${C_RESET}"
    fi

    echo -ne " [3] Configuración (/etc/zivpn/config.json): "
    if jq empty "$CONFIG_JSON" 2>/dev/null; then
        echo -e "${C_B_VERDE}JSON VÁLIDO 🟢${C_RESET}"
    else
        echo -e "${C_B_ROJO}ERROR EN JSON 🔴${C_RESET}"
    fi

    echo -ne " [4] Estado del Servicio (zivpn.service): "
    if systemctl is-active --quiet zivpn.service; then
        echo -e "${C_B_VERDE}ACTIVO / RUNNING 🟢${C_RESET}"
    else
        echo -e "${C_B_ROJO}INACTIVO 🔴${C_RESET}"
    fi

    echo -ne " [5] Escucha en Puerto UDP $PUERTO: "
    if ss -ulpn 2>/dev/null | grep -q ":$PUERTO "; then
        echo -e "${C_B_VERDE}ESCUCHANDO EN 0.0.0.0:$PUERTO UDP 🟢${C_RESET}"
    else
        echo -e "${C_B_ROJO}NO DETECTADO EN ESCUCHA 🔴${C_RESET}"
    fi

    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

ver_logs_zivpn() {
    clear
    _titulo_seccion "📜 LOGS EN VIVO · ZIVPN"
    echo -e " ${C_DIM}Ctrl+C para salir.${C_RESET}\n"
    journalctl -u zivpn.service -n 50 -f
}

info_servidor_zivpn() {
    clear
    local HOST=$(hostname)
    local IP=$(cat "$BASE/.pub_ip" 2>/dev/null || curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || echo "N/D")
    local OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    local KERNEL=$(uname -r)
    local RAM=$(free -h 2>/dev/null | awk '/Mem:/ {print $3" / "$2}')

    _zv_cabecera "🌐 INFORMACIÓN DEL SERVIDOR" "VPS"
    _zv_dato "🖥️" "Hostname" "${C_B_BLANCO}${HOST}${C_RESET}"
    _zv_dato "🐧" "Sistema"  "${C_B_BLANCO}${OS}${C_RESET}"
    _zv_dato "🧩" "Kernel"   "${C_B_BLANCO}${KERNEL}${C_RESET}"
    _zv_dato "💾" "Memoria"  "${C_B_VERDE}${RAM}${C_RESET}"
    _zv_dato "🌍" "IPv4"     "${C_B_CIAN}${IP}${C_RESET}"
    _zv_pie
}

desinstalar_zivpn() {
    clear
    _zv_cabecera "⛔ DESINSTALAR ZIVPN" "DESINSTALAR"
    _zv_aviso "${C_B_ROJO}⚠ Se detendrá el servicio y se eliminará ZiVPN.${C_RESET}"
    _borde_caja bottom "" "$ZV_B"
    echo ""
    read -rp " ¿Seguro que deseas desinstalar ZiVPN? [s/N]: " R
    [[ ! "$R" =~ ^[Ss]$ ]] && return

    systemctl stop zivpn.service >/dev/null 2>&1
    systemctl disable zivpn.service >/dev/null 2>&1
    pkill -9 -f "zivpn" 2>/dev/null
    rm -f /etc/systemd/system/zivpn.service /etc/systemd/system/maxinet-zivpn.service
    rm -rf /etc/zivpn
    rm -f /usr/local/bin/zivpn
    systemctl daemon-reload

    msg_ok "Servidor ZiVPN desinstalado correctamente."
    sleep 2
}

_zv_dibujar_menu() {
    local estado="$1" puerto="$2" claves="$3" host="$4" arch="$5" ver_bin="$6" err="$7"

    _zv_cabecera "⚡ ZIVPN MANAGER · TÚNEL UDP" "ZIVPN"
    imprimir_centro_caja "${estado}  ${C_DIM}·${C_RESET}  ${C_B_AMARILLO}UDP ${puerto}${C_RESET}  ${C_DIM}·${C_RESET}  ${C_B_CIAN}🔑 ${claves} claves${C_RESET}" "$ZV_B"

    local linea2="${C_B_BLANCO}${host}${C_RESET}  ${C_DIM}·${C_RESET}  ${arch}"
    [[ -n "$ver_bin" && "$ver_bin" != "N/D" ]] && linea2="${linea2}  ${C_DIM}·${C_RESET}  servidor ${ver_bin}"
    imprimir_centro_caja "$linea2" "$ZV_B"

    _zv_grupo "SERVICIO"
    _zv_opcion_fila "${C_B_CIAN}[01]${C_RESET} 📋 Estado del Servicio" "  ${C_B_CIAN}[02]${C_RESET} 🔄 Reiniciar Servicio"
    _zv_opcion_fila "${C_B_CIAN}[03]${C_RESET} 🩺 Diagnóstico en Vivo" "  ${C_B_CIAN}[04]${C_RESET} ⬇️ Reinstalar ZiVPN"

    _zv_grupo "CONTRASEÑAS"
    _zv_opcion_fila "${C_B_CIAN}[05]${C_RESET} ➕ Agregar Contraseña" "  ${C_B_CIAN}[06]${C_RESET} 🗑️ Eliminar Contraseña"
    _zv_opcion_fila "${C_B_CIAN}[07]${C_RESET} 📃 Listar Contraseñas" "  ${C_B_CIAN}[08]${C_RESET} ⏳ Asignar Caducidad"
    _zv_opcion_fila "${C_B_CIAN}[09]${C_RESET} 🧹 Eliminar Vencidas" "  ${C_B_CIAN}[10]${C_RESET} 📦 Asignar Límite GB"
    _zv_opcion_fila "${C_B_CIAN}[11]${C_RESET} 📊 Consumo & Bloqueos" "  ${C_B_CIAN}[12]${C_RESET} 👥 Ver Conectados"

    _zv_grupo "RED & AVANZADO"
    _zv_opcion_fila "${C_B_AMARILLO}[13]${C_RESET} ⚡ Turbo Latencia UDP" "  ${C_B_CIAN}[14]${C_RESET} 🔑 Modo Auth"
    _zv_opcion_fila "${C_B_CIAN}[15]${C_RESET} 📜 Ver Logs en Vivo" "  ${C_B_CIAN}[16]${C_RESET} 🌐 Info del Servidor"

    _zv_grupo "SISTEMA"
    _zv_opcion_fila "${C_B_ROJO}[17]${C_RESET} ⛔ Desinstalar ZiVPN" "  ${C_B_ROJO}[00]${C_RESET} ↩ Volver"

    [[ -n "$err" ]] && _zv_aviso "${C_B_ROJO}⚠ ${err}${C_RESET}"
    _borde_caja bottom "" "$ZV_B"
}

# Bucle principal de ZiVPN
while true; do
    clear
    IP_PUB=$(cat "$BASE/.pub_ip" 2>/dev/null || curl -4 -s --max-time 2 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    DOM_HOST=$(cat "$BASE/dominio" 2>/dev/null || echo "${IP_PUB:-127.0.0.1}")

    STATUS="${C_B_ROJO}🔴 DETENIDO${C_RESET}"
    systemctl is-active --quiet zivpn.service && STATUS="${C_B_VERDE}🟢 ACTIVO${C_RESET}"

    PUERTO="5667"
    if [[ -f "$CONFIG_JSON" ]]; then
        P_ACT=$(jq -r '.listen' "$CONFIG_JSON" 2>/dev/null | tr -d ':')
        [[ -n "$P_ACT" && "$P_ACT" != "null" ]] && PUERTO="$P_ACT"
    fi

    CLAVES=0
    [[ -f "$CONFIG_JSON" ]] && CLAVES=$(jq '.auth.config | length' "$CONFIG_JSON" 2>/dev/null)
    [[ -z "$CLAVES" || "$CLAVES" == "null" ]] && CLAVES=0

    VER_BIN=$(cat "$DIR_ZIVPN/version" 2>/dev/null || echo "1.4.9")
    ARCH=$(uname -m)

    _zv_dibujar_menu "$STATUS" "$PUERTO" "$CLAVES" "$DOM_HOST" "$ARCH" "$VER_BIN" "$ERR_MSG"
    ERR_MSG=""

    echo ""
    echo -e " ${C_DIM}Escribe el número y presiona ENTER${C_RESET}"
    echo -ne " ${C_B_VERDE}▶ Opción:${C_RESET} "
    read -r opc_z

    case "$opc_z" in
        1|01) estado_zivpn ;;
        2|02) reiniciar_zivpn ;;
        3|03) diagnostico_zivpn ;;
        4|04) reinstalar_zivpn ;;
        5|05) agregar_clave_zivpn ;;
        6|06) eliminar_clave_zivpn ;;
        7|07) listar_claves_zivpn ;;
        8|08) asignar_caducidad_zivpn ;;
        9|09) eliminar_vencidas_zivpn ;;
        10) asignar_limite_gb_zivpn ;;
        11) consumo_bloqueos_zivpn ;;
        12) ver_conectados_zivpn ;;
        13) turbo_latencia_udp ;;
        14) alternar_auth_zivpn ;;
        15) ver_logs_zivpn ;;
        16) info_servidor_zivpn ;;
        17) desinstalar_zivpn ;;
        0|00)
            if [[ "$FROM_MAIN" == "1" ]]; then
                exec bash "$BASE/menu.sh"
            else
                break
            fi
            ;;
        "") ;;
        *) ERR_MSG="Opción '$opc_z' no válida" ;;
    esac
done
