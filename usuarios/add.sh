#!/bin/bash
#==================================================
# Maxinet Network Premium v2.6
# Asistente Interactivo de Creación de Usuario SSH
# Integración nativa con tarjeta en vivo (70 cols)
#==================================================

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
DB_USERS="$BASE/usuarios.db"

mkdir -p "$BASE" 2>/dev/null
touch "$DB_USERS" 2>/dev/null

# Cargar sistema de interfaz y colores
source "$BASE/lib/ui.sh" 2>/dev/null || true
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null

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

# Medición segura de caracteres visibles (ignora códigos ANSI)
ansi_ancho() {
    local str="$1"
    local clean
    clean=$(printf '%b' "$str" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" 2>/dev/null)
    if [[ -z "$clean" ]]; then
        clean=$(printf '%s' "$str" | sed 's/\\033\[[0-9;]*m//g' | sed 's/\\e\[[0-9;]*m//g')
    fi
    echo "${#clean}"
}

BOX_INNER=68

_borde_caja() {
    local tipo="$1"
    local titulo="$2"
    local color_borde="${3:-$C_B_AZUL}"
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
    local content="$1"
    local color_borde="${2:-$C_B_AZUL}"
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
    local content="$1"
    local color_borde="${2:-$C_B_AZUL}"
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
    local icono="$1"
    local etiqueta="$2"
    local separador="$3"
    local valor="$4"
    local color_borde="${5:-$C_B_AZUL}"
    local ancho_etiqueta="${6:-16}"

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

# Helpers del formulario reactivo
_UC_ETIQUETA=16
_UC_PUNTOS="${C_GRIS}· · · · · · · · · · · · · · · · · · · ·${C_RESET}"

_uc_valor() {
    if [[ -n "$1" ]]; then
        echo -e "${C_B_AMARILLO}$1${C_RESET}"
    else
        echo -e "$_UC_PUNTOS"
    fi
}

_uc_consumo_display() {
    if [[ -z "$U_GB" ]]; then
        echo ""
    elif [[ "$U_GB" -eq 0 ]] 2>/dev/null; then
        echo "Ilimitado"
    else
        echo "${U_GB} GB"
    fi
}

_uc_dibujar_formulario() {
    local B_AZUL="$C_B_AZUL"
    local err="$1"

    _titulo_seccion "👤 CREAR USUARIO SSH / VPN"
    _borde_caja top "◈ NUEVO USUARIO MAXINET ◈" "$B_AZUL"

    imprimir_linea_info " 👤" "Usuario"    "┃" "$(_uc_valor "$U_USUARIO")" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 🔑" "Contraseña" "┃" "$(_uc_valor "$U_PASS")" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📅" "Vigencia"   "┃" "$(_uc_valor "${U_DIAS:+$U_DIAS días}")" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📶" "Conexiones" "┃" "$(_uc_valor "${U_LIMITE:+$U_LIMITE dispositivo(s)}")" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📦" "Consumo"    "┃" "$(_uc_valor "$(_uc_consumo_display)")" "$B_AZUL" "$_UC_ETIQUETA"

    _borde_caja sep "" "$B_AZUL"
    imprimir_linea_caja "  ${C_TURQUESA}✏️   Escribe el valor y presiona Enter · vacío = acepta defecto${C_RESET}" "$B_AZUL"
    _borde_caja bottom "" "$B_AZUL"

    [[ -n "$err" ]] && echo -e "\n ${C_B_ROJO}❌ $err${C_RESET}"
    return 0
}

_uc_pedir_campos() {
    # 1) Nombre de Usuario
    while true; do
        clear
        _uc_dibujar_formulario "$U_ERR"
        U_ERR=""
        echo -ne " ${C_B_CIAN}👤 Nombre de usuario (letras, números, - y _):${C_RESET} "
        read -r U_USUARIO
        [[ -z "$U_USUARIO" ]] && { U_ERR="El nombre no puede estar vacío."; continue; }
        if [[ ! "$U_USUARIO" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            U_ERR="Solo letras, números, guiones y guiones bajos."
            continue
        fi
        if id "$U_USUARIO" &>/dev/null; then
            U_ERR="El usuario ya existe en el sistema."
            continue
        fi
        break
    done

    # 2) Contraseña
    clear
    _uc_dibujar_formulario
    echo -ne " ${C_B_CIAN}🔑 Contraseña (Enter = 123):${C_RESET} "
    read -r U_PASS
    [[ -z "$U_PASS" ]] && U_PASS="123"

    # 3) Días de validez
    clear
    _uc_dibujar_formulario
    echo -ne " ${C_B_CIAN}📅 Días de validez [30]:${C_RESET} "
    read -r U_DIAS
    [[ -z "$U_DIAS" ]] && U_DIAS="30"
    if [[ ! "$U_DIAS" =~ ^[0-9]+$ ]] || [[ "$U_DIAS" -le 0 ]]; then
        U_DIAS=30
    fi

    # 4) Límite de conexiones simultáneas
    clear
    _uc_dibujar_formulario
    echo -ne " ${C_B_CIAN}📶 Conexiones simultáneas [1]:${C_RESET} "
    read -r U_LIMITE
    [[ -z "$U_LIMITE" ]] && U_LIMITE="1"
    if [[ ! "$U_LIMITE" =~ ^[0-9]+$ ]] || [[ "$U_LIMITE" -lt 0 ]]; then
        U_LIMITE=1
    fi

    # 5) Límite de consumo en GB
    clear
    _uc_dibujar_formulario
    echo -ne " ${C_B_CIAN}📦 Límite de consumo GB (0 = Ilimitado) [0]:${C_RESET} "
    read -r U_GB
    [[ -z "$U_GB" ]] && U_GB="0"
    if [[ ! "$U_GB" =~ ^[0-9]+$ ]] || [[ "$U_GB" -lt 0 ]]; then
        U_GB=0
    fi
}

_uc_dibujar_resumen() {
    local B_AZUL="$C_B_AZUL"
    local IP_PUB=$(cat "$BASE/.pub_ip" 2>/dev/null || curl -s --max-time 2 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    local DOMINIO=$(cat "$BASE/dominio" 2>/dev/null || echo "${IP_PUB:-127.0.0.1}")

    _titulo_seccion "📋 CONFIRMAR DATOS DEL USUARIO"
    _borde_caja top "◈ RESUMEN DE LA CUENTA MAXINET ◈" "$B_AZUL"

    imprimir_linea_info " 👤" "Usuario"    "┃" "${C_B_BLANCO}${U_USUARIO}${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 🔑" "Contraseña" "┃" "${C_B_BLANCO}${U_PASS}${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📅" "Expira"     "┃" "${C_B_BLANCO}${EXP_DATE} (${U_DIAS} días)${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📶" "Conexiones" "┃" "${C_B_BLANCO}${U_LIMITE} dispositivo(s)${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📦" "Consumo"    "┃" "${C_B_BLANCO}$(_uc_consumo_display)${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 🌐" "Servidor"   "┃" "${C_B_VERDE}${DOMINIO}${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"

    _borde_caja sep "" "$B_AZUL"
    imprimir_centro_caja "  ${C_B_VERDE}[S]${C_RESET} Crear  ·  ${C_B_AMARILLO}[E]${C_RESET} Editar  ·  ${C_B_ROJO}[X]${C_RESET} Cancelar  " "$B_AZUL"
    _borde_caja bottom "" "$B_AZUL"
    return 0
}

_uc_dibujar_exito() {
    local B_AZUL="$C_B_AZUL"
    local IP_PUB=$(cat "$BASE/.pub_ip" 2>/dev/null || curl -s --max-time 2 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    local DOMINIO=$(cat "$BASE/dominio" 2>/dev/null || echo "${IP_PUB:-127.0.0.1}")

    _titulo_seccion "🎉 USUARIO CREADO CON ÉXITO"
    _borde_caja top "◈ ✅ CREDENCIALES MAXINET ◈" "$B_AZUL"

    imprimir_linea_info " 👤" "Usuario"      "┃" "${C_B_AMARILLO}${U_USUARIO}${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 🔑" "Contraseña"   "┃" "${C_B_AMARILLO}${U_PASS}${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 🌐" "Servidor"     "┃" "${C_B_VERDE}${DOMINIO}${C_RESET} (${IP_PUB})" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📅" "Expira"       "┃" "${C_B_BLANCO}${EXP_DATE} (${U_DIAS} días)${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📶" "Dispositivos" "┃" "${C_B_BLANCO}${U_LIMITE}${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"
    imprimir_linea_info " 📦" "Consumo"      "┃" "${C_B_BLANCO}$(_uc_consumo_display)${C_RESET}" "$B_AZUL" "$_UC_ETIQUETA"

    _borde_caja sep "🔌 PUERTOS DE CONEXIÓN" "$B_AZUL"
    imprimir_linea_caja "   ${C_B_CIAN}SSH${C_RESET} 22 · ${C_B_CIAN}Dropbear${C_RESET} 90/109/143 · ${C_B_CIAN}SSL/TLS${C_RESET} 443 · ${C_B_CIAN}BadVPN${C_RESET} 7200/7300" "$B_AZUL"
    imprimir_linea_caja "   ${C_B_CIAN}WebSocket${C_RESET} 80/8080 · ${C_B_CIAN}UDP Custom${C_RESET} 36712 · ${C_B_CIAN}ZiVPN${C_RESET} 5667" "$B_AZUL"
    _borde_caja bottom "" "$B_AZUL"
    return 0
}

crear_usuario_ssh() {
    U_USUARIO=""; U_PASS=""; U_DIAS=""; U_LIMITE=""; U_GB=""; U_ERR=""
    local EXP_DATE=""

    _uc_pedir_campos

    while true; do
        EXP_DATE=$(date -d "+$U_DIAS days" +"%Y-%m-%d" 2>/dev/null || date -v+"${U_DIAS}"d +"%Y-%m-%d" 2>/dev/null)
        clear
        _uc_dibujar_resumen
        echo ""
        echo -ne " ${C_B_CIAN}Elige una opción [S/E/X]:${C_RESET} "
        read -r OPC
        OPC=$(echo "$OPC" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        case "$OPC" in
            s|si|sí) break ;;
            e|edit|editar)
                _uc_pedir_campos
                ;;
            x|c|cancelar|"")
                clear
                echo -e "\n ${C_B_AMARILLO}⚠️ Creación cancelada — no se creó ningún usuario.${C_RESET}\n"
                sleep 2
                return 0
                ;;
        esac
    done

    # Registrar shells para PAM
    grep -qxF '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
    grep -qxF '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

    # Crear usuario de sistema para túneles VPN
    useradd -M -s /bin/false -e "$EXP_DATE" "$U_USUARIO" 2>/dev/null || useradd -M -s /bin/false "$U_USUARIO" 2>/dev/null
    echo "$U_USUARIO:$U_PASS" | chpasswd 2>/dev/null
    usermod -U "$U_USUARIO" 2>/dev/null
    chage -E "$EXP_DATE" "$U_USUARIO" 2>/dev/null

    # Registrar en base de datos de Maxinet
    sed -i "/^$U_USUARIO:/d" "$DB_USERS" 2>/dev/null
    echo "$U_USUARIO:$U_PASS:$EXP_DATE:$U_LIMITE" >> "$DB_USERS"

    # Si se especificó cuota GB, registrar en límites de tráfico
    if [[ "$U_GB" -gt 0 ]] 2>/dev/null; then
        local LIM_FILE="$BASE/trafico/limites_gb.db"
        mkdir -p "$BASE/trafico" 2>/dev/null
        touch "$LIM_FILE" 2>/dev/null
        sed -i "/^$U_USUARIO:/d" "$LIM_FILE" 2>/dev/null
        echo "$U_USUARIO:$U_GB" >> "$LIM_FILE"
    fi

    clear
    _uc_dibujar_exito
    echo ""
    read -rp " Presione [Enter] para continuar..." _
}

# Ejecución principal
crear_usuario_ssh
