#!/bin/bash
# ===================================================================
# Maxinet Network v3.0 - MONITOR DE CONEXIONES Y ESTADO EN VIVO
# 100% DATOS REALES (Solo Lectura / Pasivo)
# Sin Simulación: Kernel Conntrack [ASSURED] + Journal + Process Table
# ===================================================================

export LC_ALL=C.UTF-8 2>/dev/null
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
DB_USERS="$BASE/usuarios.db"
DIR_TRAFICO="$BASE/trafico"
DIR_ZIVPN="/etc/zivpn"
ZIVPN_CONEX="$DIR_ZIVPN/conexiones.db"
BASELINE="$DIR_TRAFICO/iface_dia.db"

mkdir -p "$BASE" "$DIR_TRAFICO" "$DIR_ZIVPN" 2>/dev/null
touch "$DB_USERS" "$ZIVPN_CONEX" 2>/dev/null
[[ -f "$DB_USERS" ]] || DB_USERS="/dev/null"

[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null || true
[[ -f "$BASE/lib/ui.sh" ]] && source "$BASE/lib/ui.sh" 2>/dev/null || true
[[ -f "$BASE/herramientas/conexiones.sh" ]] && source "$BASE/herramientas/conexiones.sh" 2>/dev/null || true

# Paleta ANSI Maxinet Nebula
CY="\033[1;36m"
BL="\033[1;34m"
GR="\033[1;32m"
YW="\033[1;33m"
RD="\033[1;31m"
WH="\033[1;37m"
MG="\033[1;35m"
GY="\033[38;5;245m"
DK="\033[38;5;240m"
GD="\033[38;5;220m"
LM="\033[38;5;118m"
TQ="\033[38;5;45m"
OR="\033[38;5;208m"
RS="\033[0m"

# Timeout adaptativo según arquitectura (ARM64 vs x86_64)
ARCH=$(uname -m 2>/dev/null)
case "$ARCH" in
    aarch64|arm64) TO=5 ;;
    *) TO=2 ;;
esac

_barra_progreso() {
    local pct="${1:-0}" ancho="${2:-20}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    [[ "$ancho" =~ ^[0-9]+$ ]] || ancho=20
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0
    local filled=$(( pct * ancho / 100 ))
    local empty=$(( ancho - filled ))
    local bar=""
    local col="$GR"
    (( pct >= 60 )) && col="$YW"
    (( pct >= 85 )) && col="$RD"
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    printf "${col}%s${RS} %3d%%" "$bar" "$pct"
}

_fmt_bytes() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if (( bytes >= 1073741824 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b / 1073741824 }'
    elif (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b / 1048576 }'
    elif (( bytes >= 1024 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f KB", b / 1024 }'
    else
        printf "%d B" "$bytes"
    fi
}

_srv_estado() {
    local activo="${1:-0}" proto="${2:-}" puerto="${3:-}"
    if [[ "$activo" -eq 1 ]]; then
        printf "${GR}●${RS} %-12s : ${WH}%-14s${RS} ${GR}EN FUNCIONAMIENTO${RS}" "$proto" "$puerto"
    else
        printf "${RD}●${RS} %-12s : ${WH}%-14s${RS} ${RD}DETENIDO${RS}" "$proto" "$puerto"
    fi
}

_abb_celda() {
    local s="${1:-}" ancho="${2:-10}"
    [[ "$ancho" =~ ^[0-9]+$ ]] || ancho=10
    local n=${#s}
    if (( n > ancho )); then
        printf '%s' "${s:0:ancho}"
    elif (( n < ancho )); then
        printf '%s%*s' "$s" $(( ancho - n )) ''
    else
        printf '%s' "$s"
    fi
}

_abb_rep() {
    local c="$1" n="${2:-0}" out=""
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    while (( n-- > 0 )); do out+="$c"; done
    printf '%s' "$out"
}

_ssh_ultimos_logins() {
    command -v journalctl >/dev/null 2>&1 || return 0
    timeout ${TO}s journalctl -u ssh -u sshd -u dropbear -u dropbear_custom \
        --since "30 days ago" -o short-unix --no-pager -q -n 5000 2>/dev/null | awk '
        /Accepted (password|publickey) for [^ ]+/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "for" && (i+1) <= NF) {
                    u = $(i+1)
                    ep = substr($1, 1, index($1, " ") - 1) + 0
                    if (match($0, /^[0-9]+/)) ep = substr($0, RSTART, RLENGTH) + 0
                    if (ep > ult[u]) ult[u] = ep
                }
            }
        }
        /dropbear.*Password auth succeeded for/ {
            match($0, /for '\''[^'\'']+'\''/)
            if (RLENGTH > 6) {
                u = substr($0, RSTART + 5, RLENGTH - 6)
                ep = 0
                if (match($0, /^[0-9]+/)) ep = substr($0, RSTART, RLENGTH) + 0
                if (ep > ult[u]) ult[u] = ep
            }
        }
        END {
            for (u in ult) {
                if (ult[u] > 0)
                    printf "%s|%s\n", u, strftime("%Y-%m-%d %H:%M:%S", ult[u])
            }
        }'
}

_ssh_pintar_tabla() {
    local -a filas=("$@")
    [[ ${#filas[@]} -eq 0 ]] && return 0
    local max="${SSH_TABLA_MAX:-25}" shown=0
    local w_u=16 w_p=14 w_e=12 w_l=8 w_d=19
    local pad="   "
    local top="┌$(_abb_rep '─' $((w_u+2)))┬$(_abb_rep '─' $((w_p+2)))┬$(_abb_rep '─' $((w_e+2)))┬$(_abb_rep '─' $((w_l+2)))┬$(_abb_rep '─' $((w_d+2)))┐"
    local mid="├$(_abb_rep '─' $((w_u+2)))┼$(_abb_rep '─' $((w_p+2)))┼$(_abb_rep '─' $((w_e+2)))┼$(_abb_rep '─' $((w_l+2)))┼$(_abb_rep '─' $((w_d+2)))┤"
    local bot="└$(_abb_rep '─' $((w_u+2)))┴$(_abb_rep '─' $((w_p+2)))┴$(_abb_rep '─' $((w_e+2)))┴$(_abb_rep '─' $((w_l+2)))┴$(_abb_rep '─' $((w_d+2)))┘"

    echo -e "${pad}${GY}${top}${RS}"
    printf "${pad}${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS}\n" \
        "$(_abb_celda 'USUARIO' "$w_u")" "$(_abb_celda 'CONTRASEÑA' "$w_p")" \
        "$(_abb_celda 'EXPIRACIÓN' "$w_e")" "$(_abb_celda 'LÍMITE' "$w_l")" \
        "$(_abb_celda 'ÚLTIMO LOGIN' "$w_d")"
    echo -e "${pad}${GY}${mid}${RS}"

    local line u p e l d
    for line in "${filas[@]}"; do
        IFS='|' read -r u p e l d <<< "$line"
        [[ -z "$u" ]] && continue
        [[ "$shown" -ge "$max" ]] && break
        shown=$(( shown + 1 ))
        printf "${pad}${GY}│${RS} ${YW}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${CY}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${GR}%s${RS} ${GY}│${RS}\n" \
            "$(_abb_celda "$u" "$w_u")" "$(_abb_celda "$p" "$w_p")" \
            "$(_abb_celda "$e" "$w_e")" "$(_abb_celda "$l" "$w_l")" \
            "$(_abb_celda "$d" "$w_d")"
    done
    echo -e "${pad}${GY}${bot}${RS}"
}

_udp_hace() {
    local ult="${1:-}" vacio="${2:-en vivo}" tseg edad dd ahora
    [[ -z "$ult" || "$ult" == "—" || "$ult" == "nunca" ]] && { printf '%s' "$vacio"; return 0; }
    [[ "$ult" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] || { printf '%s' "$vacio"; return 0; }
    ahora=$(date +%s 2>/dev/null)
    tseg=$(date -d "$ult" +%s 2>/dev/null)
    if [[ -n "$tseg" && -n "$ahora" ]]; then
        edad=$(( ahora - tseg ))
        (( edad < 0 )) && edad=0
        if (( edad < 60 )); then printf 'hace %ds' "$edad"; return 0; fi
        if (( edad < 3600 )); then printf 'hace %dm' $(( edad / 60 )); return 0; fi
        if (( edad < 86400 )); then printf 'hace %dh' $(( edad / 3600 )); return 0; fi
        dd=$(( edad / 86400 )); (( dd > 99 )) && dd=99
        printf 'hace %dd' "$dd"
        return 0
    fi
    printf '%s' "$vacio"
}

_udp_evento_reciente() {
    local ts="${1:-}" ventana="${2:-120}" ahora seg
    [[ -z "$ts" ]] && return 0
    ahora=$(date +%s 2>/dev/null) || return 0
    seg=$(date -d "$ts" +%s 2>/dev/null) || return 0
    (( ahora - seg <= ventana )) && (( seg - ahora <= 120 ))
}

_udp_custom_pintar_tabla() {
    local -a filas=("$@")
    [[ ${#filas[@]} -eq 0 ]] && return 0

    local pad="   " max="${UDP_TABLA_MAX:-25}" shown=0
    local usuario n ips nip ult nv uev tcol marca hace est cell nip_txt
    local n_on=0 n_off=0 n_ip_on=0 _ip
    local w_user=16 w_n=8 w_ult=19 w_est=18
    declare -A _ips_on=()

    local top mid bot
    top="┌$(_abb_rep '─' $((w_user+2)))┬$(_abb_rep '─' $((w_n+2)))┬$(_abb_rep '─' $((w_ult+2)))┬$(_abb_rep '─' $((w_est+2)))┐"
    mid="├$(_abb_rep '─' $((w_user+2)))┼$(_abb_rep '─' $((w_n+2)))┼$(_abb_rep '─' $((w_ult+2)))┼$(_abb_rep '─' $((w_est+2)))┤"
    bot="└$(_abb_rep '─' $((w_user+2)))┴$(_abb_rep '─' $((w_n+2)))┴$(_abb_rep '─' $((w_ult+2)))┴$(_abb_rep '─' $((w_est+2)))┘"

    echo -e "${pad}${GY}${top}${RS}"
    printf "${pad}${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS} ${WH}%s${RS} ${GY}│${RS}\n" \
        "$(_abb_celda 'USUARIO SSH' "$w_user")" "$(_abb_celda 'DISP.' "$w_n")" \
        "$(_abb_celda 'ÚLTIMA CONEXIÓN' "$w_ult")" "$(_abb_celda 'ESTADO' "$w_est")"
    echo -e "${pad}${GY}${mid}${RS}"

    for line in "${filas[@]}"; do
        IFS='|' read -r usuario n ips nip ult nv uev <<< "$line"
        [[ -z "$usuario" ]] && continue
        [[ "$shown" -ge "$max" ]] && break
        shown=$(( shown + 1 ))
        if [[ "${nv:-0}" -gt 0 ]]; then
            marca="●"; tcol="$GR"
            n_on=$(( n_on + 1 ))
            hace=$(_udp_hace "$ult" "en vivo")
            nip_txt="${nv:-0}"
            if (( ${nv:-0} >= ${nip:-0} )); then
                for _ip in $ips; do [[ -n "$_ip" ]] && _ips_on["$_ip"]=1; done
            fi
            est="$(_abb_celda "${marca} ${hace}" "$w_est")"
        else
            marca="○"; tcol="$GY"
            n_off=$(( n_off + 1 ))
            hace=$(_udp_hace "${uev:-$ult}" "nunca")
            nip_txt=0
            est="$(_abb_celda "${marca} apagada ${hace}" "$w_est")"
        fi
        cell=$(_abb_celda "$usuario" "$w_user")
        printf "${pad}${GY}│${RS} ${YW}%s${RS} ${GY}│${RS} ${WH}%8s${RS} ${GY}│${RS} ${CY}%s${RS} ${GY}│${RS} ${tcol}%s${RS} ${GY}│${RS}\n" \
            "$cell" "$nip_txt" "$(_abb_celda "${ult:-—}" "$w_ult")" "$est"
    done

    echo -e "${pad}${GY}${bot}${RS}"
    n_ip_on="${UDP_TABLA_IPS_ON:-}"
    [[ "$n_ip_on" =~ ^[0-9]+$ ]] || n_ip_on=${#_ips_on[@]}
    local ventana="${UDP_VENTANA_UDP:-120}"
    local leyenda="● = actividad reciente · ○ = apagada"
    echo -e "${pad}${GY}${n_ip_on} IP(s) conectada(s) · ${n_on} usuario(s) en línea · ${n_off} apagada(s) · ${leyenda}${RS}"
}

_udp_merge_evidencia() {
    local db="${1:-}" cache="${2:-}" entrada cache_iso="" regs=""
    entrada=$(cat)

    if [[ -n "$cache" && -s "$cache" ]]; then
        cache_iso=$(awk -F'|' '$1 != "" && $2 ~ /^[0-9]+$/ {
            printf "%s|%s\n", $1, strftime("%Y-%m-%d %H:%M:%S", $2 + 0)
        }' "$cache" 2>/dev/null)
    fi

    if [[ -n "$db" && -f "$db" ]]; then
        regs=$(awk -F: '$1!="" && $1!~/^#/ && $1!="root" {print $1}' "$db" 2>/dev/null | tr -d ' \t\r')
    fi

    printf '%s\n__CACHE__\n%s\n__REGS__\n%s\n' "$entrada" "$cache_iso" "$regs" | awk -F'|' '
        $0 == "__CACHE__" { sec = 1; next }
        $0 == "__REGS__"  { sec = 2; next }
        sec == 0 {
            if ($1 == "" || $1 ~ /^#/) next
            u = $1
            if (!(u in grp)) {
                order[++n] = u; grp[u] = 1
                nses[u] = 0; ips[u] = ""; nip[u] = 0; ult[u] = ""; nv[u] = 0
            }
            nses[u] += $2 + 0
            if ($3 != "" && index(" " ips[u] " ", " " $3 " ") == 0)
                ips[u] = (ips[u] == "" ? $3 : ips[u] " " $3)
            nip[u] += $4 + 0
            if ($5 > ult[u]) ult[u] = $5
            nv[u] += $6 + 0
            next
        }
        sec == 1 {
            if ($1 == "" || $2 == "") next
            if ($2 > cult[$1]) cult[$1] = $2
            next
        }
        sec == 2 { if ($0 != "") reg[$0] = 1; next }
        END {
            for (i = 1; i <= n; i++) {
                u = order[i]
                if (u == "" || u == "root" || !(u in reg)) continue
                t = ult[u]
                if (cult[u] > t) t = cult[u]
                printf "%s|%d|%s|%d|%s|%d\n", u, nses[u], ips[u], nip[u], t, nv[u]
            }
            for (u in cult) {
                if (u in grp) continue
                if (u == "" || u == "root" || !(u in reg)) continue
                printf "%s|0||0|%s|0\n", u, cult[u]
            }
        }'
}

_detectar_udp_custom() {
    local CT_FILE="$1" UDP_PORT="$2" SERVER_IPS="$3" ZIVPN_PORT="${4:-5667}"
    local awk_filter='
        BEGIN {
            split(srv_ips, sarr, " ")
            for (s in sarr) if (sarr[s] != "") local_ips[sarr[s]] = 1
            local_ips["127.0.0.1"] = 1
            local_ips["0.0.0.0"] = 1
        }
        /udp/ && !/UNREPLIED/ {
            src1 = ""; dst1 = ""; sport1 = 0; dport1 = 0
            src2 = ""; dst2 = ""; sport2 = 0; dport2 = 0
            seen_src = 0; seen_dst = 0; seen_sp = 0; seen_dp = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^src=/) {
                    split($i, a, "=")
                    if (seen_src == 0) { src1 = a[2]; seen_src = 1 }
                    else if (seen_src == 1) { src2 = a[2]; seen_src = 2 }
                }
                else if ($i ~ /^dst=/) {
                    split($i, a, "=")
                    if (seen_dst == 0) { dst1 = a[2]; seen_dst = 1 }
                    else if (seen_dst == 1) { dst2 = a[2]; seen_dst = 2 }
                }
                else if ($i ~ /^sport=/) {
                    split($i, a, "=")
                    if (seen_sp == 0) { sport1 = a[2] + 0; seen_sp = 1 }
                    else if (seen_sp == 1) { sport2 = a[2] + 0; seen_sp = 2 }
                }
                else if ($i ~ /^dport=/) {
                    split($i, a, "=")
                    if (seen_dp == 0) { dport1 = a[2] + 0; seen_dp = 1 }
                    else if (seen_dp == 1) { dport2 = a[2] + 0; seen_dp = 2 }
                }
            }
            if (src1 in local_ips) next
            if (src1 ~ /^(127\.|0\.|169\.254\.)/) next
            if (src1 ~ /^(8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1|1\.0\.0\.1)/) next
            if (dport1 == 53 || sport1 == 53 || sport2 == 53 || dport2 == 53) next
            if (dport1 == zv_port || sport2 == zv_port || dport1 == 5667 || sport2 == 5667) next
            if ((dport1 >= 6000 && dport1 <= 29999) || (sport2 >= 6000 && sport2 <= 29999)) next
            if (dport1 == 7100 || dport1 == 7200 || dport1 == 7300 || dport1 == 9900) next
            if (sport2 == 7100 || sport2 == 7200 || sport2 == 7300 || sport2 == 9900) next
            if (dport1 == 22 || dport1 == 90 || dport1 == 109 || dport1 == 143) next
            if (sport2 == 22 || sport2 == 90 || sport2 == 109 || sport2 == 143) next

            is_uc = 0
            if (dport1 == uc_port || sport2 == uc_port || dport1 == 36712 || sport2 == 36712 || dport1 == 2100 || sport2 == 2100) is_uc = 1
            if (dport1 > 0 && dport1 != 53 && dport1 != 5300) is_uc = 1
            if (!is_uc) next
            print src1
        }
    '
    local results=""
    if [[ -n "$CT_FILE" && -r "$CT_FILE" ]]; then
        results=$(awk -v uc_port="$UDP_PORT" -v zv_port="$ZIVPN_PORT" -v srv_ips="$SERVER_IPS" "$awk_filter" "$CT_FILE" 2>/dev/null)
    fi
    if [[ -z "$results" ]] && command -v conntrack &>/dev/null; then
        results=$(conntrack -L -p udp 2>/dev/null | awk -v uc_port="$UDP_PORT" -v zv_port="$ZIVPN_PORT" -v srv_ips="$SERVER_IPS" "$awk_filter" 2>/dev/null)
    fi
    [[ -n "$results" ]] && echo "$results" | sort -u
}

_udp_recolectar() {
    ACTIVE_UDP_IPS=()
    UDP_GROUPS=()
    UDP_SINREG=()
    UDP_C=0
    UDP_MODO="journal"

    declare -gA UDP_ULTIMO_EVENTO=()
    declare -g UDP_VENTANA_UDP=120
    if declare -F zivpn_umbral_frescura >/dev/null 2>&1; then
        UDP_VENTANA_UDP=$(zivpn_umbral_frescura 2>/dev/null)
        [[ "$UDP_VENTANA_UDP" =~ ^[0-9]+$ ]] || UDP_VENTANA_UDP=120
    fi

    declare -F maxinet_ct_precachear >/dev/null 2>&1 && maxinet_ct_precachear

    local UDP_UMBRAL=5
    if declare -F zivpn_modo_en_linea >/dev/null 2>&1; then
        UDP_MODO=$(zivpn_modo_en_linea "$UDP_CUSTOM_PORT")
    fi

    declare -A UDP_CT_FLUJO=() UDP_CT_DESDE=()
    if [[ "$UDP_MODO" == "kernel" ]] && declare -F zivpn_flujos_kernel >/dev/null 2>&1; then
        local ct_ip ct_cport ct_desde
        while IFS='|' read -r ct_ip ct_cport ct_desde; do
            [[ -z "$ct_ip" ]] && continue
            UDP_CT_FLUJO["$ct_ip"]=1
            [[ -n "$ct_desde" && -z "${UDP_CT_DESDE[$ct_ip]:-}" ]] && UDP_CT_DESDE["$ct_ip"]="$ct_desde"
        done < <(zivpn_flujos_kernel "$UDP_CUSTOM_PORT" 2>/dev/null)
    fi

    declare -A UDP_CACHE_IP=() UDP_CACHE_EP=() UDP_IP_DUENO=()
    local udp_cache_pre="${DIR_TRAFICO}/udp_ultima.db"
    if [[ -s "$udp_cache_pre" ]]; then
        local cu ce cip
        while IFS='|' read -r cu ce cip; do
            [[ -z "$cu" || -z "$cip" ]] && continue
            [[ -n "${UDP_REGISTRADOS[$cu]:-}" ]] || continue
            UDP_CACHE_IP["$cu"]="$cip"
            UDP_CACHE_EP["$cu"]="$ce"
            if [[ -z "${UDP_IP_DUENO[$cip]:-}" ]]; then
                UDP_IP_DUENO["$cip"]="$cu"
            elif [[ "${UDP_IP_DUENO[$cip]}" != "$cu" ]]; then
                UDP_IP_DUENO["$cip"]="*"
            fi
        done < "$udp_cache_pre"
    fi

    declare -A UDP_BEST_STATE=() UDP_BEST_DESDE=() UDP_BEST_ULTIMO=() UDP_BEST_PORT=() UDP_BEST_USER=() UDP_BEST_IP=()
    declare -A UDP_SEEN_USER_IP=()
    declare -A USER_SEEN_IP=() USER_SEEN_DESDE=()
    declare -A UDP_UIKEY_LATEST=() UDP_UIKEY_LATEST_DESDE=()
    local u_user u_ip u_puerto u_desde u_estado u_ultimo u_key u_uikey
    while IFS='|' read -r u_user u_ip u_puerto u_desde u_estado u_ultimo; do
        [[ -z "$u_ip" ]] && continue
        u_key="${u_user}|${u_ip}|${u_puerto}"
        u_uikey="${u_user}|${u_ip}"
        UDP_SEEN_USER_IP["$u_uikey"]=1
        if [[ -n "$u_user" && "$u_user" != "N/D" ]]; then
            USER_SEEN_IP["$u_user"]="$u_ip"
            [[ -n "$u_desde" ]] && USER_SEEN_DESDE["$u_user"]="$u_desde"
        fi
        if [[ -z "${UDP_BEST_STATE[$u_key]+x}" ]] \
            || [[ -z "${UDP_BEST_DESDE[$u_key]}" && -n "$u_desde" ]] \
            || [[ "$u_desde" > "${UDP_BEST_DESDE[$u_key]}" ]]; then
            UDP_BEST_STATE["$u_key"]="$u_estado"
            UDP_BEST_DESDE["$u_key"]="$u_desde"
            UDP_BEST_ULTIMO["$u_key"]="$u_ultimo"
            UDP_BEST_PORT["$u_key"]="$u_puerto"
            UDP_BEST_USER["$u_key"]="$u_user"
            UDP_BEST_IP["$u_key"]="$u_ip"
        fi
        if [[ "$u_estado" == "conectado" ]]; then
            local _prev_desde="${UDP_UIKEY_LATEST_DESDE[$u_uikey]:-}"
            if [[ -z "$_prev_desde" || "$u_desde" > "$_prev_desde" ]]; then
                UDP_UIKEY_LATEST["$u_uikey"]="$u_key"
                UDP_UIKEY_LATEST_DESDE["$u_uikey"]="$u_desde"
            fi
        fi
        if [[ -n "$u_user" && "$u_user" != "N/D" && -n "$u_ultimo" ]]; then
            if [[ -z "${UDP_ULTIMO_EVENTO[$u_user]:-}" || "$u_ultimo" > "${UDP_ULTIMO_EVENTO[$u_user]}" ]]; then
                UDP_ULTIMO_EVENTO["$u_user"]="$u_ultimo"
            fi
        fi
    done < <(conexiones_udp_custom 6 2>/dev/null)

    # Dedup por user|ip: solo el puerto más reciente se mantiene como conectado
    for u_key in "${!UDP_BEST_STATE[@]}"; do
        [[ "${UDP_BEST_STATE[$u_key]}" == "conectado" ]] || continue
        u_uikey="${UDP_BEST_USER[$u_key]}|${UDP_BEST_IP[$u_key]}"
        local _latest="${UDP_UIKEY_LATEST[$u_uikey]:-}"
        if [[ -n "$_latest" && "$_latest" != "$u_key" ]]; then
            UDP_BEST_STATE["$u_key"]="desconectado"
        fi
    done

    declare -A SEEN_UDP_LIVE=() SEEN_SINREG=() UDP_IP_VIVA=()
    declare -A USER_LIVE_COUNT=() USER_LAST_IP=() USER_LAST_DESDE=()
    local u_rows="" u_viva="" cv _tiene_ssh=0
    for u_key in "${!UDP_BEST_STATE[@]}"; do
        u_user="${UDP_BEST_USER[$u_key]}"
        u_ip="${UDP_BEST_IP[$u_key]}"
        u_puerto="${UDP_BEST_PORT[$u_key]}"
        u_desde="${UDP_BEST_DESDE[$u_key]}"
        u_estado="${UDP_BEST_STATE[$u_key]}"
        u_ultimo="${UDP_BEST_ULTIMO[$u_key]}"

        _tiene_ssh=0
        if [[ -n "$u_user" && -n "${SSH_ONLINE[$u_user]:-}" && "${SSH_ONLINE[$u_user]}" -gt 0 ]]; then
            _tiene_ssh=1
        fi

        u_viva="no"
        if [[ "$UDP_MODO" == "journal" ]]; then
            if [[ "$u_estado" == "conectado" ]] && _udp_evento_reciente "$u_ultimo" "$UDP_VENTANA_UDP"; then
                u_viva="si"
            elif [[ "$_tiene_ssh" -eq 1 ]] && _udp_evento_reciente "$u_ultimo" "$UDP_VENTANA_UDP"; then
                u_viva="si"
            fi
        elif [[ "$u_estado" == "conectado" ]]; then
            cv="N/D"
            declare -F conntrack_ip_viva >/dev/null 2>&1 && cv=$(conntrack_ip_viva "$u_ip" "$UDP_UMBRAL")
            if [[ "$cv" == "si" ]]; then
                u_viva="si"
            elif [[ "$_tiene_ssh" -eq 1 ]] && _udp_evento_reciente "$u_ultimo" "$UDP_VENTANA_UDP"; then
                u_viva="si"
            fi
        elif [[ "$_tiene_ssh" -eq 1 ]]; then
            cv="N/D"
            declare -F conntrack_ip_viva >/dev/null 2>&1 && cv=$(conntrack_ip_viva "$u_ip" "$UDP_UMBRAL")
            if [[ "$cv" == "si" ]]; then
                u_viva="si"
            fi
        fi

        if [[ "$u_viva" == "si" ]]; then
            UDP_IP_VIVA["$u_ip"]=1
            [[ -n "${UDP_CT_DESDE[$u_ip]:-}" ]] && u_desde="${UDP_CT_DESDE[$u_ip]}"
            if [[ -z "${SEEN_UDP_LIVE[$u_ip]:-}" ]]; then
                SEEN_UDP_LIVE["$u_ip"]=1
                ACTIVE_UDP_IPS+=("$u_ip")
            fi
            if [[ -n "$u_user" && "$u_user" != "N/D" ]]; then
                USER_LIVE_COUNT["$u_user"]=$(( ${USER_LIVE_COUNT["$u_user"]:-0} + 1 ))
                USER_LAST_IP["$u_user"]="$u_ip"
                [[ -n "$u_desde" ]] && USER_LAST_DESDE["$u_user"]="$u_desde"
            fi
        fi

        if [[ -n "$u_user" && "$u_user" != "N/D" && -n "${UDP_REGISTRADOS[$u_user]:-}" ]]; then
            u_rows+="${u_user}|${u_ip}|${u_puerto}|${u_desde}|${u_viva}"$'\n'
        elif [[ "$u_viva" == "si" && -z "${SEEN_SINREG[$u_ip]:-}" ]]; then
            SEEN_SINREG["$u_ip"]=1
            UDP_SINREG+=("$u_ip")
        fi
    done

    # Journal rotado: rescate honesto si la IP es unívoca
    local cu ckey
    for cu in "${!UDP_CACHE_IP[@]}"; do
        ckey="${cu}|${UDP_CACHE_IP[$cu]}"
        [[ -n "${UDP_SEEN_USER_IP[$ckey]:-}" ]] && continue
        u_ip="${UDP_CACHE_IP[$cu]}"
        [[ "${UDP_IP_DUENO[$u_ip]:-}" == "$cu" ]] || continue
        [[ -n "${UDP_IP_VIVA[$u_ip]:-}" ]] && continue
        [[ "$UDP_MODO" == "journal" ]] && continue
        u_viva="no"
        if [[ -n "${SSH_ONLINE[$cu]:-}" && "${SSH_ONLINE[$cu]}" -gt 0 ]]; then
            u_viva="si"
        elif declare -F conntrack_ip_viva >/dev/null 2>&1; then
            cv=$(conntrack_ip_viva "$u_ip" "$UDP_UMBRAL")
            [[ "$cv" == "si" ]] && u_viva="si"
        fi
        [[ "$u_viva" == "si" ]] || continue
        u_desde="${UDP_CT_DESDE[$u_ip]:-}"
        [[ -z "$u_desde" && -n "${UDP_CACHE_EP[$cu]:-}" ]] && \
            u_desde=$(date -d "@${UDP_CACHE_EP[$cu]}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        UDP_IP_VIVA["$u_ip"]=1
        if [[ -z "${SEEN_UDP_LIVE[$u_ip]:-}" ]]; then
            SEEN_UDP_LIVE["$u_ip"]=1
            ACTIVE_UDP_IPS+=("$u_ip")
        fi
        u_rows+="${cu}|${u_ip}||${u_desde}|si"$'\n'
        USER_LIVE_COUNT["$cu"]=$(( ${USER_LIVE_COUNT["$cu"]:-0} + 1 ))
    done

    # Reconciliación con procesos SSH / Dropbear reales
    local r_user n_ssh n_cur diff i ref_ip ref_desde
    for r_user in "${!SSH_ONLINE[@]}"; do
        n_ssh="${SSH_ONLINE[$r_user]:-0}"
        [[ "$n_ssh" -gt 0 ]] || continue
        [[ -n "${UDP_REGISTRADOS[$r_user]:-}" ]] || continue
        n_cur="${USER_LIVE_COUNT[$r_user]:-0}"
        if [[ "$n_ssh" -gt "$n_cur" && "$n_cur" -gt 0 ]]; then
            diff=$(( n_ssh - n_cur ))
            ref_ip="${USER_LAST_IP[$r_user]:-${UDP_CACHE_IP[$r_user]:-127.0.0.1}}"
            ref_desde="${USER_LAST_DESDE[$r_user]:-$(date '+%Y-%m-%d %H:%M:%S')}"
            for (( i = 0; i < diff; i++ )); do
                u_rows+="${r_user}|${ref_ip}||${ref_desde}|si"$'\n'
            done
            USER_LIVE_COUNT["$r_user"]=$n_ssh
        fi
    done

    # Reconciliación multidispositivo con flujos de socket kernel conntrack [ASSURED]
    local ct_full_dump=""
    if [[ -n "${MAXINET_CT_DUMP_OK:-${ABBIENET_CT_DUMP_OK:-}}" ]]; then
        ct_full_dump="${MAXINET_CT_DUMP:-$ABBIENET_CT_DUMP}"
    elif [[ -z "${MAXINET_CT_NO_BIN:-${ABBIENET_CT_NO_BIN:-}}" ]] && command -v conntrack >/dev/null 2>&1; then
        ct_full_dump=$(conntrack -L -p udp 2>/dev/null)
    elif [[ -r /proc/net/nf_conntrack ]]; then
        ct_full_dump=$(cat /proc/net/nf_conntrack 2>/dev/null)
    fi

    if [[ -n "$ct_full_dump" ]]; then
        declare -A UDP_IP_DEV_COUNT=()
        local c_ip c_cnt
        while IFS='|' read -r c_ip c_cnt; do
            [[ -n "$c_ip" && "$c_cnt" -gt 0 ]] && UDP_IP_DEV_COUNT["$c_ip"]="$c_cnt"
        done < <(printf '%s\n' "$ct_full_dump" | awk -v uc_port="$UDP_CUSTOM_PORT" '
            /UNREPLIED/ { next }
            !/ASSURED/ { next }
            {
                src1 = ""; sport1 = 0; sport2 = 0; nsp = 0
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^src=/) { if (src1 == "") { split($i, a, "="); src1 = a[2] } }
                    else if ($i ~ /^sport=/) {
                        split($i, a, "=")
                        if (nsp == 0) { sport1 = a[2] + 0; nsp = 1 }
                        else { sport2 = a[2] + 0 }
                    }
                }
                if (src1 != "" && sport1 > 0 && (sport2 == uc_port + 0 || sport2 == 36712)) {
                    pairs[src1 "|" sport1] = src1
                }
            }
            END {
                for (p in pairs) {
                    ip = pairs[p]
                    count[ip]++
                }
                for (ip in count) {
                    print ip "|" count[ip]
                }
            }')
        local u_dev_ip n_ct_dev
        for r_user in "${!UDP_REGISTRADOS[@]}"; do
            u_dev_ip="${USER_LAST_IP[$r_user]:-${USER_SEEN_IP[$r_user]:-${UDP_CACHE_IP[$r_user]:-}}}"
            [[ -n "$u_dev_ip" ]] || continue
            local _dueno="${UDP_IP_DUENO[$u_dev_ip]:-}"
            if [[ "$_dueno" == "*" || ( -n "$_dueno" && "$_dueno" != "$r_user" ) ]]; then continue; fi
            n_ct_dev="${UDP_IP_DEV_COUNT[$u_dev_ip]:-0}"
            [[ "$n_ct_dev" -gt 0 ]] || continue
            n_cur="${USER_LIVE_COUNT[$r_user]:-0}"
            [[ "$n_cur" -gt 0 ]] || continue
            if [[ "$n_ct_dev" -gt "$n_cur" ]]; then
                diff=$(( n_ct_dev - n_cur ))
                ref_desde="${USER_LAST_DESDE[$r_user]:-${USER_SEEN_DESDE[$r_user]:-$(date '+%Y-%m-%d %H:%M:%S')}}"
                for (( i = 0; i < diff; i++ )); do
                    u_rows+="${r_user}|${u_dev_ip}||${ref_desde}|si"$'\n'
                done
                USER_LIVE_COUNT["$r_user"]=$n_ct_dev
                UDP_IP_VIVA["$u_dev_ip"]=1
                if [[ -z "${SEEN_UDP_LIVE[$u_dev_ip]:-}" ]]; then
                    SEEN_UDP_LIVE["$u_dev_ip"]=1
                    ACTIVE_UDP_IPS+=("$u_dev_ip")
                fi
            fi
        done
    fi

    # Flujos vivos no atribuidos reportados honestamente como sin registro
    local ct_live_ip
    for ct_live_ip in "${!UDP_CT_FLUJO[@]}"; do
        [[ -n "${UDP_IP_VIVA[$ct_live_ip]:-}" ]] && continue
        if declare -F conntrack_ip_viva >/dev/null 2>&1; then
            cv=$(conntrack_ip_viva "$ct_live_ip" "$UDP_UMBRAL")
            [[ "$cv" == "si" ]] || continue
        fi
        UDP_IP_VIVA["$ct_live_ip"]=1
        if [[ -z "${SEEN_SINREG[$ct_live_ip]:-}" ]]; then
            SEEN_SINREG["$ct_live_ip"]=1
            UDP_SINREG+=("$ct_live_ip")
        fi
        if [[ -z "${SEEN_UDP_LIVE[$ct_live_ip]:-}" ]]; then
            SEEN_UDP_LIVE["$ct_live_ip"]=1
            ACTIVE_UDP_IPS+=("$ct_live_ip")
        fi
    done

    if declare -F zivpn_agrupar >/dev/null 2>&1; then
        mapfile -t UDP_GROUPS < <(printf '%s' "$u_rows" | zivpn_agrupar | sort -t'|' -k6,6rn -k5,5r)
    fi
    UDP_C=${#ACTIVE_UDP_IPS[@]}
}

badvpn_tuneles_vivos() {
    local out
    if [[ -n "${MAXINET_SS_DUMP:-${ABBIENET_SS_DUMP:-}}" ]]; then
        out="${MAXINET_SS_DUMP:-$ABBIENET_SS_DUMP}"
    elif command -v ss >/dev/null 2>&1; then
        out=$(timeout ${TO}s ss -tni 'sport = :7100 or sport = :7200 or sport = :7300 or sport = :9900' 2>/dev/null)
    fi
    [[ -n "$out" ]] || { echo 0; return; }
    printf '%s\n' "$out" | awk '
        /ESTAB/ { is_estab = 1 }
        is_estab && /last(rcv|_data_recv):[0-9]+/ {
            match($0, /last(rcv|_data_recv):[0-9]+/)
            v = substr($0, RSTART, RLENGTH)
            sub(/^[^:]*:/, "", v)
            if (v + 0 <= 120000) count++
            is_estab = 0
        }
        END { print count + 0 }'
}

# ═══════════════════════════════════════════════════════════════════
# PANTALLA PRINCIPAL DEL MONITOR
# ═══════════════════════════════════════════════════════════════════

mostrar_conectados() {
    if [[ "${1:-}" == "--check" ]]; then return 0; fi

    if [[ ! -r /proc/net/nf_conntrack && ! -r /proc/net/ip_conntrack ]]; then
        modprobe nf_conntrack 2>/dev/null || /sbin/modprobe nf_conntrack 2>/dev/null || true
        sysctl -qw net.netfilter.nf_conntrack_acct=1 2>/dev/null || true
    fi
    sysctl -qw net.netfilter.nf_conntrack_udp_timeout=180 2>/dev/null || true
    sysctl -qw net.netfilter.nf_conntrack_udp_timeout_stream=180 2>/dev/null || true
    sysctl -qw net.netfilter.nf_conntrack_timestamp=1 2>/dev/null || true

    local K_MSG=""

    while true; do
        clear
        local HOY=$(date +"%d/%m/%Y %H:%M:%S")

        local SERVER_IPS=$(timeout ${TO}s hostname -I 2>/dev/null || echo "")
        local EXTRA_IPS=$(timeout ${TO}s ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ' || echo "")
        local PUB_IP=""
        [[ -f "$BASE/config.conf" ]] && PUB_IP=$(grep -oP 'SERVER_PUB_IP="\K[^"]+' "$BASE/config.conf" 2>/dev/null || echo "")
        SERVER_IPS="$SERVER_IPS $EXTRA_IPS $PUB_IP 127.0.0.1 0.0.0.0"
        local HOSTNAME_SRV=$(timeout ${TO}s hostname 2>/dev/null || echo "VPS")

        local CT_FILE=""
        [[ -r /proc/net/nf_conntrack ]] && CT_FILE="/proc/net/nf_conntrack"
        [[ -z "$CT_FILE" && -r /proc/net/ip_conntrack ]] && CT_FILE="/proc/net/ip_conntrack"

        local UPTIME_STR="—"
        if [[ -f /proc/uptime ]]; then
            local up_secs=$(awk '{printf "%d", $1}' /proc/uptime)
            local up_d=$(( up_secs / 86400 ))
            local up_h=$(( (up_secs % 86400) / 3600 ))
            local up_m=$(( (up_secs % 3600) / 60 ))
            [[ "$up_d" -gt 0 ]] && UPTIME_STR="${up_d}d ${up_h}h ${up_m}m" || UPTIME_STR="${up_h}h ${up_m}m"
        fi

        local CPU_USE="—"
        if command -v top &>/dev/null; then
            CPU_USE=$(timeout ${TO}s top -bn1 2>/dev/null | awk '/^%Cpu|^Cpu/{gsub(/[^0-9.]/, "", $2); print $2; exit}')
            [[ -z "$CPU_USE" ]] && CPU_USE=$(grep 'cpu ' /proc/stat 2>/dev/null | awk '{usage=($2+$4)*100/($2+$4+$5); printf "%.1f", usage}')
        fi
        [[ -z "$CPU_USE" ]] && CPU_USE="0.0"

        local RAM_TOTAL=0 RAM_USED=0 RAM_PCT=0
        if [[ -f /proc/meminfo ]]; then
            RAM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)
            local RAM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
            [[ -z "$RAM_FREE" ]] && RAM_FREE=$(awk '/MemFree/{print $2}' /proc/meminfo)
            RAM_USED=$(( RAM_TOTAL - RAM_FREE ))
            [[ "$RAM_TOTAL" -gt 0 ]] && RAM_PCT=$(( RAM_USED * 100 / RAM_TOTAL ))
        fi
        local RAM_TOTAL_MB=$(( RAM_TOTAL / 1024 ))
        local RAM_USED_MB=$(( RAM_USED / 1024 ))

        # Cuentas SSH Registradas y Sesiones
        local -a ALL_SSH_USERS=()
        local -a SSH_TABLA=()
        declare -A SEEN_USERS=()
        declare -A USER_LAST_LOGIN=()

        if [[ -f "$DB_USERS" ]]; then
            while IFS=: read -r d_user d_pass d_exp d_lim _; do
                [[ -z "$d_user" || "$d_user" =~ ^# || "$d_user" == "root" ]] && continue
                d_user=$(echo "$d_user" | tr -d ' \t\r\n')
                [[ -z "$d_user" || -n "${SEEN_USERS[$d_user]:-}" ]] && continue
                SEEN_USERS["$d_user"]=1
                ALL_SSH_USERS+=("$d_user")
                d_pass=$(printf '%s' "$d_pass" | tr -d '\r\n')
                d_exp=$(printf '%s' "$d_exp" | tr -d ' \t\r\n')
                d_lim=$(printf '%s' "$d_lim" | tr -d ' \t\r\n')
                [[ -z "$d_exp" ]] && d_exp="Ilimitado"
                [[ -z "$d_lim" || "$d_lim" == "0" ]] && d_lim="∞"
                SSH_TABLA+=("${d_user}|${d_pass:-N/D}|${d_exp}|${d_lim}|—")
            done < "$DB_USERS"
        fi

        if [[ ${#ALL_SSH_USERS[@]} -gt 0 ]]; then
            while IFS='|' read -r l_user l_ts; do
                [[ -n "$l_user" && -n "$l_ts" ]] && USER_LAST_LOGIN["$l_user"]="$l_ts"
            done < <(_ssh_ultimos_logins)
            local -a SSH_TABLA_F=()
            local st st_u st_p st_e st_l
            for st in "${SSH_TABLA[@]}"; do
                IFS='|' read -r st_u st_p st_e st_l _ <<< "$st"
                SSH_TABLA_F+=("${st_u}|${st_p}|${st_e}|${st_l}|${USER_LAST_LOGIN[$st_u]:-—}")
            done
            SSH_TABLA=("${SSH_TABLA_F[@]}")
        fi

        local TOTAL_CUENTAS_SSH=${#ALL_SSH_USERS[@]}
        local TOTAL_SSH=0
        local -a SSH_USERS_ONLINE=()
        declare -A SSH_ONLINE=()
        if [[ ${#ALL_SSH_USERS[@]} -gt 0 ]] && command -v ps &>/dev/null; then
            local ps_out=$(timeout ${TO}s ps -ef 2>/dev/null)
            for d_user in "${ALL_SSH_USERS[@]}"; do
                local u_conns=$(printf '%s\n' "$ps_out" | grep -E "(sshd:\s*${d_user}@|sshd:\s*${d_user}\s|dropbear.*${d_user})" | grep -v grep | wc -l)
                if [ "$u_conns" -gt 0 ]; then
                    TOTAL_SSH=$(( TOTAL_SSH + u_conns ))
                    SSH_USERS_ONLINE+=("${d_user}:${u_conns}")
                    SSH_ONLINE["$d_user"]="$u_conns"
                fi
            done
        fi

        # ZiVPN Config
        local ZIVPN_SVC_ACTIVE=0
        (timeout ${TO}s systemctl is-active zivpn.service &>/dev/null || timeout ${TO}s pgrep -x zivpn &>/dev/null) && ZIVPN_SVC_ACTIVE=1
        local ZIVPN_PORT=""
        [[ -f "$DIR_ZIVPN/config.json" ]] && ZIVPN_PORT=$(grep -oP '"listen":\s*":?\K[0-9]+' "$DIR_ZIVPN/config.json" 2>/dev/null | head -1)
        [[ -z "$ZIVPN_PORT" ]] && ZIVPN_PORT=5667

        # UDP Custom Config
        local UDP_SVC_ACTIVE=0
        (timeout ${TO}s systemctl is-active udp-custom.service &>/dev/null || timeout ${TO}s systemctl is-active udp-custom &>/dev/null || timeout ${TO}s pgrep -f "udp-custom" &>/dev/null) && UDP_SVC_ACTIVE=1

        local UDP_INSTALADO=0
        [[ -f /root/udp/config.json || -f /etc/UDPCustom/config.json || -f /etc/systemd/system/udp-custom.service || "$UDP_SVC_ACTIVE" -eq 1 ]] && UDP_INSTALADO=1

        local CONEXIONES_DISP=1
        declare -F conexiones_udp_custom >/dev/null 2>&1 || CONEXIONES_DISP=0

        local -a ACTIVE_UDP_IPS=()
        local -a UDP_GROUPS=()
        local -a UDP_SINREG=()
        local UDP_C=0
        local UDP_USR_ON=0
        local UDP_MODO="journal"
        local UDP_CUSTOM_PORT=""
        [[ -f /root/udp/config.json ]] && UDP_CUSTOM_PORT=$(grep -oP '"listen":\s*":?\K[0-9]+' /root/udp/config.json 2>/dev/null | head -1)
        [[ -z "$UDP_CUSTOM_PORT" ]] && UDP_CUSTOM_PORT=36712

        declare -A UDP_REGISTRADOS=()
        if [[ "$UDP_INSTALADO" -eq 1 && -f "$DB_USERS" ]]; then
            local r_user
            while IFS=: read -r r_user _ _ _ _; do
                r_user=$(printf '%s' "$r_user" | tr -d ' \t\r\n')
                [[ -z "$r_user" || "$r_user" =~ ^# || "$r_user" == "root" ]] && continue
                UDP_REGISTRADOS["$r_user"]=1
            done < "$DB_USERS"
        fi

        if [[ "$UDP_SVC_ACTIVE" -eq 1 && "$CONEXIONES_DISP" -eq 1 ]]; then
            _udp_recolectar
        fi

        if [[ "$UDP_INSTALADO" -eq 1 ]]; then
            local udp_cache="${DIR_TRAFICO}/udp_ultima.db"
            mapfile -t UDP_GROUPS < <(printf '%s\n' "${UDP_GROUPS[@]}" \
                | _udp_merge_evidencia "$DB_USERS" "$udp_cache" \
                | awk -F'|' '{ print ($6 + 0 > 0 ? 1 : 0) "|" $0 }' \
                | LC_ALL=C sort -t'|' -k1,1r -k6,6r \
                | cut -d'|' -f2-)
        fi

        local g_line g_nv
        for g_line in "${UDP_GROUPS[@]}"; do
            IFS='|' read -r _ _ _ _ _ g_nv <<< "$g_line"
            [[ "${g_nv:-0}" -gt 0 ]] && UDP_USR_ON=$(( UDP_USR_ON + 1 ))
        done

        local -a UDP_GROUPS_UI=()
        local _ug _uu
        for _ug in "${UDP_GROUPS[@]}"; do
            _uu="${_ug%%|*}"
            UDP_GROUPS_UI+=("${_ug}|${UDP_ULTIMO_EVENTO[$_uu]:-}")
        done

        # Sesiones ZiVPN 100% REAL
        local -a ZIVPN_GROUPS=()
        local ZIVPN_USR=0
        local ZIVPN_PASS_ON=0
        if [[ "$ZIVPN_SVC_ACTIVE" -eq 1 && "$CONEXIONES_DISP" -eq 1 ]]; then
            local z_sesiones
            z_sesiones=$(zivpn_sesiones_reales 6 "$ZIVPN_PORT" 2>/dev/null)
            if [[ -n "$z_sesiones" ]]; then
                mapfile -t ZIVPN_GROUPS < <(printf '%s\n' "$z_sesiones" | zivpn_agrupar)
                declare -A ZIVPN_SEEN_IP=()
                local zg_line zg_pass zg_ses zg_ips zg_nip zg_ult zg_nv
                for zg_line in "${ZIVPN_GROUPS[@]}"; do
                    IFS='|' read -r zg_pass zg_ses zg_ips zg_nip zg_ult zg_nv <<< "$zg_line"
                    if [[ "${zg_nv:-0}" -gt 0 ]]; then
                        ZIVPN_PASS_ON=$(( ZIVPN_PASS_ON + 1 ))
                        for z_ip in $zg_ips; do
                            [[ -n "$z_ip" && -z "${ZIVPN_SEEN_IP[$z_ip]:-}" ]] && {
                                ZIVPN_SEEN_IP["$z_ip"]=1
                                ZIVPN_USR=$(( ZIVPN_USR + 1 ))
                            }
                        done
                    fi
                done
            fi
        fi

        # BadVPN Túneles
        local BADVPN_ACTIVOS=0
        BADVPN_ACTIVOS=$(badvpn_tuneles_vivos)

        # Tráfico de interfaz del día
        local IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
        [[ -z "$IFACE" ]] && IFACE="eth0"
        local RX_RAW=0 TX_RAW=0
        if [[ -r /proc/net/dev ]]; then
            read -r RX_RAW TX_RAW < <(awk -v iface="${IFACE}:" '$1 == iface { print $2, $10 }' /proc/net/dev 2>/dev/null)
        fi
        [[ -z "$RX_RAW" ]] && RX_RAW=0
        [[ -z "$TX_RAW" ]] && TX_RAW=0
        local B_RX=0 B_TX=0
        if [[ -f "$BASELINE" ]]; then
            read -r B_RX B_TX < "$BASELINE" 2>/dev/null
        fi
        [[ "$B_RX" =~ ^[0-9]+$ ]] || B_RX=0
        [[ "$B_TX" =~ ^[0-9]+$ ]] || B_TX=0
        local D_RX=$(( RX_RAW >= B_RX ? RX_RAW - B_RX : RX_RAW ))
        local D_TX=$(( TX_RAW >= B_TX ? TX_RAW - B_TX : TX_RAW ))
        local D_TOT=$(( D_RX + D_TX ))
        local TOT_VPS=$(( RX_RAW + TX_RAW ))

        # ═════════════════════════════════════════════════════════════════
        # RENDERIZADO VISUAL MAXINET NEBULA
        # ═════════════════════════════════════════════════════════════════
        if declare -F mv_brand_header >/dev/null 2>&1; then
            mv_brand_header "📡 MONITOR DE CONEXIONES EN VIVO" "v3.0 · 100% Datos Reales del Kernel"
        else
            echo ""
            echo -e "  ${BL}╔══════════════════════════════════════════════════════════════════════╗${RS}"
            echo -e "  ${BL}║${RS}        ${GD}⟐  M A X I N E T   N E T W O R K   v3.0  ⟐${RS}                     ${BL}║${RS}"
            echo -e "  ${BL}║${RS}              ${CY}Monitor de Conexiones · 100% Datos Reales${RS}                 ${BL}║${RS}"
            echo -e "  ${BL}╚══════════════════════════════════════════════════════════════════════╝${RS}"
            echo ""
        fi

        [[ -n "$K_MSG" ]] && { echo -e "  $K_MSG"; echo ""; K_MSG=""; }

        # SERVICIOS Y RESUMEN
        echo -e "  ${CY}─── 🚀 ESTADO DE PROTOCOLOS VPN ───────────────────────────────────────${RS}"
        echo -e "   $(_srv_estado "$UDP_SVC_ACTIVE" "UDP Custom" ":36712")    ${WH}${UDP_C} activo(s)${RS}    $(_barra_progreso $(( UDP_C * 10 )) 12)"
        echo -e "   $(_srv_estado "$ZIVPN_SVC_ACTIVE" "ZiVPN (UDP)" ":5667")     ${WH}${ZIVPN_USR} en línea${RS}     $(_barra_progreso $(( ZIVPN_USR * 10 )) 12)"
        echo -e "   $(_srv_estado $(( BADVPN_ACTIVOS > 0 ? 1 : 0 )) "BadVPN Gate" ":7100-9900")  ${WH}${BADVPN_ACTIVOS} túnel(es)${RS}   $(_barra_progreso $(( BADVPN_ACTIVOS * 10 )) 12)"
        echo -e "   $(_srv_estado $(( TOTAL_SSH > 0 ? 1 : 0 )) "OpenSSH/Drop" ":22/90")       ${WH}${TOTAL_SSH} sesión(es)${RS}  $(_barra_progreso $(( TOTAL_SSH * 10 )) 12)"
        echo ""
        echo -e "   ${WH}👥 Cuentas SSH registradas : ${TOTAL_CUENTAS_SSH} (${#SSH_USERS_ONLINE[@]} en línea)${RS}"
        echo ""

        # PANEL UDP CUSTOM
        echo -e "  ${CY}─── 🚀 UDP CUSTOM · Estado, Sesiones y Credenciales ───────────────────${RS}"
        echo -e "   ${GR}●${RS} Estado del Servicio : $([[ $UDP_SVC_ACTIVE -eq 1 ]] && echo -e "${GR}EN FUNCIONAMIENTO (Puerto :${UDP_CUSTOM_PORT})${RS}" || echo -e "${RD}DETENIDO${RS}")"
        echo -e "   ${WH}⚡ Usuarios conectados : ${UDP_C} IP(s) conectada(s) · ${UDP_USR_ON} usuario(s) en línea${RS}"
        echo ""

        if [[ "$UDP_INSTALADO" -eq 1 && ${#UDP_GROUPS_UI[@]} -gt 0 ]]; then
            _udp_custom_pintar_tabla "${UDP_GROUPS_UI[@]}"
        elif [[ "$UDP_INSTALADO" -eq 1 ]]; then
            echo -e "   ${GY}┌──────────────────┬──────────┬─────────────────────┬────────────────────┐${RS}"
            echo -e "   ${GY}│${RS} ${WH}USUARIO SSH     ${RS} ${GY}│${RS} ${WH}DISP.   ${RS} ${GY}│${RS} ${WH}ÚLTIMA CONEXIÓN     ${RS} ${GY}│${RS} ${WH}ESTADO             ${RS} ${GY}│${RS}"
            echo -e "   ${GY}├──────────────────┼──────────┼─────────────────────┼────────────────────┤${RS}"
            echo -e "   ${GY}│${RS} ${GY}(sin sesiones registradas en la ventana actual)${RS}"
            echo -e "   ${GY}└──────────────────┴──────────┴─────────────────────┴────────────────────┘${RS}"
        else
            echo -e "   ${GY}· UDP Custom no instalado en este servidor${RS}"
        fi
        echo ""

        # PANEL ZIVPN
        echo -e "  ${CY}─── ⚡ ZIVPN · Estado, Sesiones y Credenciales ─────────────────────────${RS}"
        echo -e "   ${GR}●${RS} Estado del Servicio : $([[ $ZIVPN_SVC_ACTIVE -eq 1 ]] && echo -e "${GR}EN FUNCIONAMIENTO (Puerto :${ZIVPN_PORT})${RS}" || echo -e "${RD}DETENIDO${RS}")"
        echo -e "   ${WH}⚡ Usuarios conectados : ${ZIVPN_USR} conectado(s) · ${ZIVPN_PASS_ON} contraseña(s) en línea${RS}"
        echo ""

        if [[ "$ZIVPN_SVC_ACTIVE" -eq 1 && ${#ZIVPN_GROUPS[@]} -gt 0 ]]; then
            printf '%s\n' "${ZIVPN_GROUPS[@]}" | zivpn_pintar_tabla 3 "kernel"
        elif [[ "$ZIVPN_SVC_ACTIVE" -eq 1 ]]; then
            echo -e "   ${GY}┌──────────────────┬──────────┬─────────────────────┬────────────────────┐${RS}"
            echo -e "   ${GY}│${RS} ${WH}CONTRASEÑA      ${RS} ${GY}│${RS} ${WH}DISP.   ${RS} ${GY}│${RS} ${WH}ÚLTIMA CONEXIÓN     ${RS} ${GY}│${RS} ${WH}ESTADO             ${RS} ${GY}│${RS}"
            echo -e "   ${GY}├──────────────────┼──────────┼─────────────────────┼────────────────────┤${RS}"
            echo -e "   ${GY}│${RS} ${GY}(sin contraseñas activas en este instante)${RS}"
            echo -e "   ${GY}└──────────────────┴──────────┴─────────────────────┴────────────────────┘${RS}"
        else
            echo -e "   ${GY}· ZiVPN no instalado o detenido${RS}"
        fi
        echo ""

        # PANEL TRÁFICO Y SISTEMA
        echo -e "  ${CY}─── 📊 TRÁFICO DEL DÍA (desde 00:00) ───────────────────────────────────${RS}"
        local p_dia=0
        (( TOT_VPS > 0 )) && p_dia=$(( D_TOT * 100 / TOT_VPS ))
        (( p_dia > 100 )) && p_dia=100
        echo -e "      ${YW}▼ Descarga : $(_fmt_bytes "$D_RX")${RS}"
        echo -e "      ${GR}▲ Subida   : $(_fmt_bytes "$D_TX")${RS}"
        echo -e "      ${CY}────────────────────────────────────${RS}"
        echo -e "      ${MG}◆ Total día: $(_fmt_bytes "$D_TOT")${RS}     $(_barra_progreso "$p_dia" 16)"
        echo -e "      ${MG}◆ Total VPS: $(_fmt_bytes "$TOT_VPS")${RS}     ${GY}(interfaz ${IFACE})${RS}"
        echo ""

        echo -e "  ${CY}─── 🖥 SISTEMA ─────────────────────────────────────────────────────────${RS}"
        echo -e "      ${WH}CPU  : ${CPU_USE}%  $(_barra_progreso "${CPU_USE%.*}" 16)${RS}"
        echo -e "      ${WH}RAM  : ${RAM_PCT}%  $(_barra_progreso "$RAM_PCT" 16)  ${RAM_USED_MB}MB / ${RAM_TOTAL_MB}MB${RS}"
        echo -e "      ${WH}Uptime : ${UPTIME_STR} · Fecha: ${HOY}${RS}"
        echo ""

        echo -e "  ${BL}══════════════════════════════════════════════════════════════════════${RS}"
        echo -e "   ${CY}[ENTER]/[R] Actualizar${RS}    ${CY}[K] Purgar flujos ZiVPN ociosos${RS}    ${RD}[0] Volver${RS}"
        echo -e "  ${BL}══════════════════════════════════════════════════════════════════════${RS}"
        echo -ne "   ► "

        if ! read -r OPC_M; then break; fi
        case "$OPC_M" in
            ""|r|R) ;;
            k|K)
                local p_out
                p_out=$(purgar_flujos_zivpn_muertos "$ZIVPN_PORT")
                K_MSG="${GR}✔ Flujos ZiVPN purgados exitosamente: ${p_out} entrada(s) eliminada(s).${RS}"
                ;;
            0|q|Q) break ;;
            *) ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════
# WATCHDOG Y GESTIÓN DE SERVICIOS
# ═══════════════════════════════════════════════════════════════════

verificar_y_limpiar() {
    [[ ! -f "$DB_USERS" ]] && return 0
    local HOY_SEC=$(date +%s)

    while IFS=: read -r u pass exp lim _; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        case "$u" in
            ubuntu|opc|snapd*|root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|systemd-*|_apt|sshd|messagebus|polkitd|kvm|render|tss|redis) continue ;;
        esac

        # 1. Comprobar expiración
        if [[ -n "$exp" && "$exp" != "Ilimitado" && "$exp" != "0" ]]; then
            local EXP_SEC
            if [[ "$exp" =~ ^[0-9]+$ ]]; then
                EXP_SEC="$exp"
            else
                EXP_SEC=$(date -d "$exp" +%s 2>/dev/null || echo 0)
            fi
            if [[ "$EXP_SEC" -gt 0 && "$EXP_SEC" -le "$HOY_SEC" ]]; then
                pkill -u "$u" 2>/dev/null
                usermod -L "$u" 2>/dev/null
                continue
            fi
        fi

        # 2. Comprobar límite de conexiones simultáneas por usuario SSH
        if [[ -n "$lim" && "$lim" =~ ^[0-9]+$ && "$lim" -gt 0 ]]; then
            local PIDS=($(ps -ef 2>/dev/null | grep -E "sshd:\s*${u}(\s+\[priv\]|@|\s*$)|dropbear.*${u}" | grep -v grep | grep -v "dropbear -p" | awk '{print $2}'))
            local NUM_CONNS=${#PIDS[@]}

            if [ "$NUM_CONNS" -gt "$lim" ]; then
                local EXCESO=$(( NUM_CONNS - lim ))
                for (( i=0; i<EXCESO; i++ )); do
                    kill -9 "${PIDS[$i]}" 2>/dev/null
                done
            fi
        fi
    done < "$DB_USERS"
}

_actualizar_baseline() {
    local IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [[ -z "$IFACE" ]] && IFACE="eth0"
    local RX_RAW=0 TX_RAW=0
    if [[ -r /proc/net/dev ]]; then
        read -r RX_RAW TX_RAW < <(awk -v iface="${IFACE}:" '$1 == iface { print $2, $10 }' /proc/net/dev 2>/dev/null)
    fi
    mkdir -p "$DIR_TRAFICO" 2>/dev/null
    echo "${RX_RAW:-0} ${TX_RAW:-0}" > "$BASELINE" 2>/dev/null
}

activar_servicio_monitor() {
    cat > /etc/systemd/system/maxinet-monitor.service << 'EOF'
[Unit]
Description=Maxinet User Limit & Expiration Watchdog Daemon
After=network.target

[Service]
Type=simple
User=root
ExecStart=/bin/bash -c "while true; do /etc/maxinet/herramientas/monitor_en_vivo.sh --check; sleep 15; done"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable maxinet-monitor.service >/dev/null 2>&1
    systemctl restart maxinet-monitor.service >/dev/null 2>&1
}

detener_servicio_monitor() {
    systemctl stop maxinet-monitor.service >/dev/null 2>&1
    systemctl disable maxinet-monitor.service >/dev/null 2>&1
}

# ═══════════════════════════════════════════════════════════════════
# MANEJO DE ARGUMENTOS CLI
# ═══════════════════════════════════════════════════════════════════
case "${1:-}" in
    --check)          verificar_y_limpiar; exit 0 ;;
    --snapshot-iface) _actualizar_baseline; exit 0 ;;
    --install-service) activar_servicio_monitor; exit 0 ;;
    --stop-service)   detener_servicio_monitor; exit 0 ;;
    --status)
        printf 'monitor=%s\n' "$(systemctl is-active maxinet-monitor.service 2>/dev/null || echo inactive)"
        printf 'udp=%s\n' "$(conexiones_udp_custom_activas 6 2>/dev/null | wc -l)"
        printf 'badvpn=%s\n' "$(badvpn_tuneles_vivos)"
        exit 0
        ;;
    --help|-h)
        echo "Uso: $0 [--check|--snapshot-iface|--install-service|--stop-service|--status]"
        echo "  Sin argumentos: panel interactivo (Monitor Conectados En Vivo)."
        exit 0
        ;;
esac

# Si no hay tty (ej. pipe o cron sin argumentos), renderizar 1 vez y salir
if [[ ! -t 0 ]]; then
    mostrar_conectados
    exit 0
fi

# Bucle interactivo
mostrar_conectados
