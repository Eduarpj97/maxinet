#!/bin/bash
#==================================================
# Maxinet Network Premium v2.10
# Tráfico & Consumo (GB) · Contabilidad Real iptables
# Rastreo real con iptables (IP + UID), límites de GB,
# auto-bloqueo estricto y gráficas ASCII
#==================================================

export LC_ALL=C.UTF-8 2>/dev/null
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null

DIR_TRAFICO="$BASE/trafico"
CONSUMO_DB="$DIR_TRAFICO/consumo.db"
LIMITES_DB="$DIR_TRAFICO/limites_gb.db"
BLOQUEADOS_DB="$DIR_TRAFICO/bloqueados.db"
HISTORIAL_DIR="$DIR_TRAFICO/historial"
SNAP_DIR="$DIR_TRAFICO/snapshots"
DB_USERS="$BASE/usuarios.db"

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
C_DORADO="\033[38;5;220m"
C_GRIS="\033[38;5;245m"

msg_ok()   { echo -e " ${C_B_VERDE}✔${C_RESET} $1"; }
msg_err()  { echo -e " ${C_B_ROJO}❌${C_RESET} $1"; }
msg_info() { echo -e " ${C_B_CIAN}ℹ${C_RESET} $1"; }
msg_warn() { echo -e " ${C_B_AMARILLO}⚠${C_RESET} $1"; }

trafico_init() {
    mkdir -p "$DIR_TRAFICO" "$HISTORIAL_DIR" "$SNAP_DIR" "$BASE/scripts" 2>/dev/null
    touch "$CONSUMO_DB" "$LIMITES_DB" "$BLOQUEADOS_DB" "$DB_USERS" 2>/dev/null
}

trafico_formatear() {
    local bytes="${1:-0}"
    [[ ! "$bytes" =~ ^[0-9]+$ ]] && bytes=0
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(( bytes / 1024 )) KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        local mb=$(awk "BEGIN {printf \"%.1f\", $bytes / 1048576}")
        echo "${mb} MB"
    else
        local gb=$(awk "BEGIN {printf \"%.2f\", $bytes / 1073741824}")
        echo "${gb} GB"
    fi
}

_draw_bar() {
    local val="$1" max="$2" width="${3:-30}"
    [[ ! "$val" =~ ^[0-9]+$ ]] && val=0
    [[ ! "$max" =~ ^[0-9]+$ || "$max" -le 0 ]] && max=1
    local filled=$(( val * width / max ))
    (( filled > width )) && filled=$width
    (( filled < 0 )) && filled=0
    local empty=$(( width - filled ))
    local b=""
    for ((i=0; i<filled; i++)); do b+="█"; done
    for ((i=0; i<empty; i++)); do b+="░"; done
    printf '%s' "$b"
}

trafico_obtener_consumo() {
    local user="$1"
    local c=0
    if [[ -f "$CONSUMO_DB" ]]; then
        c=$(grep "^${user}:" "$CONSUMO_DB" 2>/dev/null | tail -1 | cut -d: -f2)
    fi
    echo "${c:-0}"
}

trafico_obtener_limite() {
    local user="$1"
    local l=0
    if [[ -f "$LIMITES_DB" ]]; then
        l=$(grep "^${user}:" "$LIMITES_DB" 2>/dev/null | tail -1 | cut -d: -f2 | grep -oE '[0-9]+')
    fi
    echo "${l:-0}"
}

trafico_bloquear_usuario() {
    local user="$1"
    [[ -z "$user" ]] && return
    grep -q "^${user}:" "$BLOQUEADOS_DB" 2>/dev/null && return
    echo "${user}:$(date -Iseconds 2>/dev/null || date +%s)" >> "$BLOQUEADOS_DB"
    usermod -L "$user" 2>/dev/null
    pkill -u "$user" -9 2>/dev/null
}

trafico_desbloquear_usuario() {
    local user="$1"
    [[ -z "$user" ]] && return
    sed -i "/^${user}:/d" "$BLOQUEADOS_DB" 2>/dev/null
    usermod -U "$user" 2>/dev/null
}

trafico_reset_usuario() {
    local user="$1"
    [[ -z "$user" ]] && return
    sed -i "/^${user}:/d" "$CONSUMO_DB" 2>/dev/null
    echo "${user}:0" >> "$CONSUMO_DB"
    trafico_desbloquear_usuario "$user"
}

trafico_guardar_snapshot() {
    trafico_init
    local HOY=$(date +%Y-%m-%d)
    local HIST_HOY="$HISTORIAL_DIR/${HOY}.db"
    touch "$HIST_HOY" 2>/dev/null

    # Contabilidad básica desde iptables para cada usuario en DB_USERS
    while IFS=: read -r u _ _ _; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        if id "$u" &>/dev/null; then
            local BYTES=0
            local OUT=$(iptables -nvx -L OUTPUT 2>/dev/null | grep -E "owner UID match $u|owner UID match $(id -u "$u" 2>/dev/null)" | awk '{s+=$2} END{print s+0}')
            BYTES=$(( BYTES + OUT ))
            if [[ "$BYTES" -gt 0 ]]; then
                sed -i "/^${u}:/d" "$CONSUMO_DB" 2>/dev/null
                echo "${u}:${BYTES}" >> "$CONSUMO_DB"
                sed -i "/^${u}:/d" "$HIST_HOY" 2>/dev/null
                echo "${u}:${BYTES}" >> "$HIST_HOY"
            fi
        fi
    done < "$DB_USERS"
}

trafico_verificar_limites() {
    [[ ! -f "$LIMITES_DB" ]] && return 0
    while IFS=: read -r user lim_str; do
        [[ -z "$user" ]] && continue
        local lim_gb=$(echo "$lim_str" | grep -oE '[0-9]+')
        if [[ -n "$lim_gb" && "$lim_gb" -gt 0 ]]; then
            local lim_bytes=$(( lim_gb * 1073741824 ))
            local actual=$(trafico_obtener_consumo "$user")
            if (( actual >= lim_bytes )); then
                trafico_bloquear_usuario "$user"
            fi
        fi
    done < "$LIMITES_DB"
}

trafico_resumen_hoy() {
    clear
    trafico_guardar_snapshot
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "       ${C_DORADO}★${C_RESET} ${C_B_BLANCO}RESUMEN DE CONSUMO HOY (${C_B_VERDE}$(date +%Y-%m-%d)${C_B_BLANCO})${C_RESET} ${C_DORADO}★${C_RESET}"
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
    printf "   %-18s %-14s %-12s %-12s\n" "USUARIO" "CONSUMO" "LÍMITE" "ESTADO"
    echo -e "${C_GRIS}   ─────────────────────────────────────────────────────────────${C_RESET}"

    local HAY=0
    while IFS=: read -r user _ _ _; do
        [[ -z "$user" || "$user" =~ ^# ]] && continue
        local c=$(trafico_obtener_consumo "$user")
        local l=$(trafico_obtener_limite "$user")
        local lim_str="Ilimitado"
        (( l > 0 )) && lim_str="${l} GB"
        local st="${C_B_VERDE}Activo${C_RESET}"
        if grep -q "^${user}:" "$BLOQUEADOS_DB" 2>/dev/null; then
            st="${C_B_ROJO}⛔ Bloqueado${C_RESET}"
        fi
        printf "   ${C_B_CIAN}%-18s${C_RESET} %-14s %-12s %b\n" "$user" "$(trafico_formatear "$c")" "$lim_str" "$st"
        HAY=1
    done < "$DB_USERS"

    if [[ "$HAY" -eq 0 ]]; then
        echo -e "   ${C_GRIS}(Sin usuarios registrados en base de datos)${C_RESET}"
    fi
    echo -e "${C_GRIS}   ─────────────────────────────────────────────────────────────${C_RESET}"
}

trafico_grafica_semanal() {
    clear
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "        ${C_DORADO}★${C_RESET} ${C_B_BLANCO}GRÁFICA SEMANAL DE CONSUMO (7 DÍAS)${C_RESET} ${C_DORADO}★${C_RESET}"
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"

    local -a dias vals
    local max=1
    for i in $(seq 6 -1 0); do
        local f=$(date -d "-${i} days" +%Y-%m-%d 2>/dev/null)
        dias+=("$(date -d "-${i} days" +"%a %d" 2>/dev/null)")
        local hfile="$HISTORIAL_DIR/${f}.db"
        local tot=0
        if [[ -f "$hfile" ]]; then
            tot=$(awk -F: '{s+=$2} END{print s+0}' "$hfile" 2>/dev/null)
        fi
        vals+=("$tot")
        (( tot > max )) && max=$tot
    done

    for i in "${!dias[@]}"; do
        local b=$(_draw_bar "${vals[$i]}" "$max" 28)
        local fmt=$(trafico_formatear "${vals[$i]}")
        local hoy=""
        (( i == 6 )) && hoy=" ${C_B_VERDE}← HOY${C_RESET}"
        printf "   ${C_B_BLANCO}%-6s${C_RESET} ${C_B_VERDE}%s${C_RESET}  ${C_B_AMARILLO}%8s${C_RESET}%b\n" \
            "${dias[$i]}" "$b" "$fmt" "$hoy"
    done
    echo ""
}

trafico_grafica_mensual() {
    clear
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "       ${C_DORADO}★${C_RESET} ${C_B_BLANCO}GRÁFICA MENSUAL DE CONSUMO (30 DÍAS)${C_RESET} ${C_DORADO}★${C_RESET}"
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"

    local -a dias vals
    local max=1
    for i in $(seq 29 -5 0); do
        local f=$(date -d "-${i} days" +%Y-%m-%d 2>/dev/null)
        dias+=("$(date -d "-${i} days" +"%d/%m" 2>/dev/null)")
        local hfile="$HISTORIAL_DIR/${f}.db"
        local tot=0
        if [[ -f "$hfile" ]]; then
            tot=$(awk -F: '{s+=$2} END{print s+0}' "$hfile" 2>/dev/null)
        fi
        vals+=("$tot")
        (( tot > max )) && max=$tot
    done

    for i in "${!dias[@]}"; do
        local b=$(_draw_bar "${vals[$i]}" "$max" 30)
        local fmt=$(trafico_formatear "${vals[$i]}")
        printf "   ${C_B_BLANCO}%-6s${C_RESET} ${C_B_CIAN}%s${C_RESET}  ${C_B_AMARILLO}%8s${C_RESET}\n" \
            "${dias[$i]}" "$b" "$fmt"
    done
    echo ""
}

trafico_consumo_usuario() {
    clear
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "         ${C_B_CIAN}👤 CONSUMO DETALLADO POR USUARIO${C_RESET}"
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"

    local -a USERS
    local idx=1
    while IFS=: read -r u _ _ _; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        USERS+=("$u")
        local c=$(trafico_obtener_consumo "$u")
        local l=$(trafico_obtener_limite "$u")
        local l_str="Ilimitado"
        (( l > 0 )) && l_str="${l} GB"
        printf "  ${C_B_CIAN}[%02d]${C_RESET} %-16s ${C_B_VERDE}%s${C_RESET} / ${C_B_AMARILLO}%s${C_RESET}\n" \
            "$idx" "$u" "$(trafico_formatear "$c")" "$l_str"
        idx=$(( idx + 1 ))
    done < "$DB_USERS"

    if [[ ${#USERS[@]} -eq 0 ]]; then
        echo -e "  (No hay usuarios registrados)\n"
        read -rp "Presione [Enter] para continuar..." _
        return
    fi

    echo ""
    read -rp " Seleccione usuario [0=Volver]: " SEL_U
    [[ -z "$SEL_U" || "$SEL_U" == "0" ]] && return
    if [[ "$SEL_U" =~ ^[0-9]+$ ]] && (( SEL_U >= 1 && SEL_U <= ${#USERS[@]} )); then
        local TARGET="${USERS[$(( SEL_U - 1 ))]}"
        clear
        echo -e "${C_B_CIAN}Detalle de Tráfico:${C_RESET} ${C_B_BLANCO}$TARGET${C_RESET}\n"
        local C_ACT=$(trafico_obtener_consumo "$TARGET")
        local L_ACT=$(trafico_obtener_limite "$TARGET")
        echo -e "  Consumo total: ${C_B_VERDE}$(trafico_formatear "$C_ACT")${C_RESET}"
        echo -e "  Límite de GB:  ${C_B_AMARILLO}${L_ACT} GB${C_RESET}"
        echo ""
        echo -e "  [R] Resetear consumo a 0 B  ·  [L] Cambiar límite GB  ·  [0] Volver"
        read -rp "  » Opción: " OPC_SUB
        case "$OPC_SUB" in
            r|R)
                trafico_reset_usuario "$TARGET"
                msg_ok "Consumo de $TARGET reseteado y usuario desbloqueado."
                sleep 2
                ;;
            l|L)
                read -rp " Nuevo límite en GB (0 = Ilimitado): " N_LIM
                if [[ "$N_LIM" =~ ^[0-9]+$ ]]; then
                    sed -i "/^${TARGET}:/d" "$LIMITES_DB" 2>/dev/null
                    echo "${TARGET}:${N_LIM}" >> "$LIMITES_DB"
                    msg_ok "Límite de $TARGET actualizado a $N_LIM GB."
                fi
                sleep 2
                ;;
        esac
    fi
}

trafico_config_limites() {
    clear
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "         ${C_B_CIAN}⚙ CONFIGURAR LÍMITES DE GB POR USUARIO${C_RESET}"
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"

    echo -ne " Nombre de usuario: "
    read -r U_NAME
    [[ -z "$U_NAME" ]] && return

    echo -ne " Límite en GB (0 = Ilimitado): "
    read -r U_GB
    [[ ! "$U_GB" =~ ^[0-9]+$ ]] && { msg_err "Valor no numérico."; sleep 2; return; }

    sed -i "/^${U_NAME}:/d" "$LIMITES_DB" 2>/dev/null
    echo "${U_NAME}:${U_GB}" >> "$LIMITES_DB"
    msg_ok "Límite para $U_NAME guardado en ${U_GB} GB."
    sleep 2
}

trafico_instalar_servicio() {
    trafico_init
    cat > "$BASE/scripts/trafico_cron.sh" << 'TEOF'
#!/bin/bash
BASE="/etc/maxinet"
# Base del día para el Monitor (se reinicia a las 00:00 reales)
bash "$BASE/herramientas/monitor_en_vivo.sh" --snapshot-iface >/dev/null 2>&1
bash "$BASE/herramientas/network_traffic.sh" --snapshot >/dev/null 2>&1
TEOF
    chmod +x "$BASE/scripts/trafico_cron.sh"

    local CRON_LINE="* * * * * /bin/bash /etc/maxinet/scripts/trafico_cron.sh >/dev/null 2>&1"
    ( crontab -l 2>/dev/null | grep -v "trafico_cron" ; echo "$CRON_LINE" ) | crontab -
    msg_ok "Rastreo y auto-bloqueo de tráfico activado (vigilancia cada 1 minuto vía cron)."
}

if [[ "${1:-}" == "--snapshot" ]]; then
    trafico_guardar_snapshot
    trafico_verificar_limites
    exit 0
fi

# Menú interactivo
while true; do
    clear
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "       ${C_DORADO}★${C_RESET} ${C_B_BLANCO}MAXINET NETWORK · TRÁFICO & CONSUMO (GB)${C_RESET} ${C_DORADO}★${C_RESET}"
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
    echo -e "  ${C_B_CIAN}[01]${C_RESET} 📊 Resumen de Consumo Hoy"
    echo -e "  ${C_B_CIAN}[02]${C_RESET} 📈 Gráfica Semanal (Últimos 7 días)"
    echo -e "  ${C_B_CIAN}[03]${C_RESET} 📅 Gráfica Mensual (Últimos 30 días)"
    echo -e "  ${C_B_CIAN}[04]${C_RESET} 👤 Consumo Detallado por Usuario"
    echo -e "  ${C_B_CIAN}[05]${C_RESET} 🔧 Configurar Límites de GB"
    echo -e "  ${C_B_CIAN}[06]${C_RESET} ⚙️  Activar / Reinstalar Rastreo (Cron 1 min)"
    echo ""
    echo -e "  ${C_B_ROJO}[00]${C_RESET} ↩ Volver"
    echo -e "${C_B_AZUL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
    read -rp " » Opción: " OPC_T

    case "$OPC_T" in
        1|01) trafico_resumen_hoy; echo ""; read -rp " Presione [Enter] para continuar..." _ ;;
        2|02) trafico_grafica_semanal; echo ""; read -rp " Presione [Enter] para continuar..." _ ;;
        3|03) trafico_grafica_mensual; echo ""; read -rp " Presione [Enter] para continuar..." _ ;;
        4|04) trafico_consumo_usuario ;;
        5|05) trafico_config_limites ;;
        6|06) trafico_instalar_servicio; sleep 2 ;;
        0|00) break ;;
        *) ;;
    esac
done
