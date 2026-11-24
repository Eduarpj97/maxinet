#!/bin/bash

#=========================================================
#   Maxinet Network - TRÁFICO & USO v3.1.4
#   Réplica funcional de Abbienet v7.2.5+ (módulo trafico.sh)
#   Contabilidad real via iptables/conntrack/journal — CERO datos simulados
#=========================================================

# ── i18n shim (auto) ───────────────────────────────
if ! declare -F trx >/dev/null 2>&1; then trx() { printf '%s' "$1"; }; fi
# ─────────────────────────────────────────────────────────

BASE="/etc/maxinet"
DIR_TRAFICO="$BASE/trafico"
DIR_HISTORIAL="$DIR_TRAFICO/historial"
DIR_SNAPSHOTS="$DIR_TRAFICO/snapshots"

DB_CONSUMO="$DIR_TRAFICO/consumo.db"
DB_LIMITES="$DIR_TRAFICO/limites_gb.db"
DB_BLOQUEADOS="$DIR_TRAFICO/bloqueados.db"
DB_IP_MAP="$DIR_TRAFICO/ip_map.db"
DB_UDP_ULTIMA="$DIR_TRAFICO/udp_ultima.db"

USUARIOS_DB="$BASE/usuarios.db"
CONFIG="$BASE/config.conf"

# Design System premium + navegación + idioma
[[ -f "$BASE/lib/ui.sh" ]] && source "$BASE/lib/ui.sh"
[[ -f "$BASE/lib/nav.sh" ]] && source "$BASE/lib/nav.sh" 2>/dev/null || true
if [[ -f "$BASE/languages/lang.sh" ]]; then
    source "$BASE/languages/lang.sh"
    load_language "$(get_current_language)"
fi

# Cargar funciones multi-distro
[[ -f "$BASE/functions/pkg.sh" ]] && source "$BASE/functions/pkg.sh"

[[ -f "$CONFIG" ]] && source "$CONFIG"

# Colores estilo Abbienet/Maxinet
CYAN="${MV_CYN:-\e[1;96m}"
GREEN="${MV_GRN:-\e[1;92m}"
YELLOW="${MV_YLW:-\e[1;93m}"
RED="${MV_RED:-\e[1;91m}"
BLUE="${MV_BLU:-\e[1;94m}"
MAGENTA="${MV_MAG:-\e[1;95m}"
WHITE="${MV_WHT:-\e[1;97m}"
GRAY="${MV_DIM:-\e[1;90m}"
GOLD="${MV_GLD:-\e[1;93m}"
RESET="${MV_R:-\e[0m}"

# ── Timeout adaptativo (ARM más lento) ──────────────
TRAF_TO=3
case "$(uname -m)" in
    aarch64|arm64|armv7l|armv8l|armv6l) TRAF_TO=5 ;;
esac

# ── Helpers de formato ──────────────────────────────
human() {
    local B=$1
    [[ -z "$B" ]] && B=0
    awk "BEGIN{
        if ($B >= 1073741824) printf \"%.2f GB\", $B/1073741824;
        else if ($B >= 1048576) printf \"%.2f MB\", $B/1048576;
        else if ($B >= 1024) printf \"%.2f KB\", $B/1024;
        else printf \"%d B\", $B;
    }"
}

speed_fmt() {
    local B=$1
    [[ -z "$B" ]] && B=0
    local BIT=$(( B * 8 ))
    awk "BEGIN{
        if ($BIT >= 1000000) printf \"%.2f Mbps\", $BIT/1000000;
        else if ($BIT >= 1000) printf \"%.2f Kbps\", $BIT/1000;
        else printf \"%d bps\", $BIT;
    }"
}

bar_pct() {
    local USED=$1 LIMIT=$2 W=${3:-30}
    if [[ $LIMIT -le 0 ]]; then
        printf "${GRAY}%*s${RESET}" $W "" | sed 's/ /░/g'
        printf " ∞"
        return
    fi
    local P=$(( USED * 100 / LIMIT ))
    [[ $P -gt 100 ]] && P=100
    local F=$(( P * W / 100 ))
    local E=$(( W - F ))
    local C="$GREEN"
    [[ $P -ge 80 ]] && C="$YELLOW"
    [[ $P -ge 100 ]] && C="$RED"
    printf "${C}"
    for ((i=0;i<F;i++)); do printf "▓"; done
    printf "${GRAY}"
    for ((i=0;i<E;i++)); do printf "░"; done
    printf "${RESET} %3d%%" "$P"
}

bar_pct40() {
    local USED=$1 LIMIT=$2
    bar_pct "$USED" "$LIMIT" 40
}

# ── Caché por render (PID) ──────────────────────────
TRAF_CACHE_DIR="/tmp/abbienet_traf.$$"
TRAF_CT_FILE="${TRAF_CACHE_DIR}.ct"
TRAF_IPT_FILE="${TRAF_CACHE_DIR}.ipt"
TRAF_CAND_FILE="${TRAF_CACHE_DIR}.cand"
TRAF_JOURNAL_FILE="${TRAF_CACHE_DIR}.journal"
TRAF_DONE_FILE="${TRAF_CACHE_DIR}.done"
TRAF_INIT_USERS=()

# Limpiar cachés huérfanas >30 min
cleanup_orphan_caches() {
    find /tmp -maxdepth 1 -name 'abbienet_traf.*' -mmin +30 -exec rm -rf {} + 2>/dev/null
}

invalidate_live_cache() {
    rm -f "$TRAF_DONE_FILE" "$TRAF_IPT_FILE" "$TRAF_CT_FILE" "$TRAF_CAND_FILE" "$TRAF_JOURNAL_FILE"
}

# ── Inicialización de directorios y saneo ───────────
trafico_init() {
    mkdir -p "$DIR_HISTORIAL" "$DIR_SNAPSHOTS" 2>/dev/null
    touch "$DB_CONSUMO" "$DB_LIMITES" "$DB_BLOQUEADOS" "$DB_IP_MAP" "$DB_UDP_ULTIMA" 2>/dev/null
    chmod 644 "$DB_CONSUMO" "$DB_LIMITES" "$DB_BLOQUEADOS" "$DB_IP_MAP" "$DB_UDP_ULTIMA" 2>/dev/null

    # Sanear limites_gb.db: eliminar entradas no numéricas
    if [[ -s "$DB_LIMITES" ]]; then
        awk -F: '$2 ~ /^[0-9]+$/ {print}' "$DB_LIMITES" > "${DB_LIMITES}.tmp" && mv "${DB_LIMITES}.tmp" "$DB_LIMITES"
    fi

    cleanup_orphan_caches
}

# ── Detectar interfaz principal ─────────────────────
get_iface() {
    if [[ -n "$NET_IFACE" ]]; then
        echo "$NET_IFACE"
        return
    fi
    local IFACE
    IFACE=$(timeout ${TRAF_TO}s ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$IFACE" ]] && echo "$IFACE" && return
    IFACE=$(ls /sys/class/net 2>/dev/null | grep -E '^(eth|ens|enp|eno)' | head -n1)
    echo "${IFACE:-eth0}"
}

# ── Obtener mapa iptables (bytes por cadena) ────────
# Lee iptables-save -c UNA sola vez por render
get_iptables_map() {
    [[ -f "$TRAF_IPT_FILE" ]] && return 0
    timeout ${TRAF_TO}s iptables-save -c 2>/dev/null > "$TRAF_IPT_FILE" || {
        echo "" > "$TRAF_IPT_FILE"
        return 1
    }
}

# Bytes de una cadena (desde mapa cacheado)
get_chain_bytes() {
    local CHAIN=$1
    get_iptables_map || return 1
    # Formato: -A CHAIN ... -c PKTS BYTES
    awk -v chain="$CHAIN" '$1=="-A" && $2==chain {for(i=1;i<=NF;i++) if($i=="-c"){print $(i+2); exit}}' "$TRAF_IPT_FILE"
}

# ── Inicializar usuario (cadenas ABN + reglas) ──────
trafico_init_usuario() {
    local USER=$1
    [[ -z "$USER" ]] && return 1
    [[ " ${TRAF_INIT_USERS[*]} " == *" $USER "* ]] && return 0

    local CHAIN_IN="ABN_${USER}_IN"
    local CHAIN_OUT="ABN_${USER}_OUT"

    # Crear cadenas con RETURN final
    iptables -N "$CHAIN_IN" 2>/dev/null
    iptables -N "$CHAIN_OUT" 2>/dev/null
    iptables -C "$CHAIN_IN" -j RETURN 2>/dev/null || iptables -A "$CHAIN_IN" -j RETURN 2>/dev/null
    iptables -C "$CHAIN_OUT" -j RETURN 2>/dev/null || iptables -A "$CHAIN_OUT" -j RETURN 2>/dev/null

    TRAF_INIT_USERS+=("$USER")
    return 0
}

# ── Leer conntrack (caché por render) ───────────────
read_conntrack() {
    [[ -f "$TRAF_CT_FILE" ]] && { cat "$TRAF_CT_FILE"; return; }

    local OUT=""
    # Orden: nf_conntrack → ip_conntrack → conntrack -L
    if [[ -r /proc/net/nf_conntrack ]]; then
        OUT=$(timeout ${TRAF_TO}s cat /proc/net/nf_conntrack 2>/dev/null)
    elif [[ -r /proc/net/ip_conntrack ]]; then
        OUT=$(timeout ${TRAF_TO}s cat /proc/net/ip_conntrack 2>/dev/null)
    else
        OUT=$(timeout ${TRAF_TO}s conntrack -L 2>/dev/null)
    fi
    echo "$OUT" > "$TRAF_CT_FILE"
    cat "$TRAF_CT_FILE"
}

# ── Sincronizar IPs (atribución IP → usuario) ───────
TRAF_SYNC_DONE=0
trafico_sincronizar_ips() {
    [[ $TRAF_SYNC_DONE -eq 1 ]] && return 0

    timeout ${TRAF_TO}s sysctl -w net.netfilter.nf_conntrack_acct=1 >/dev/null 2>&1

    # IPs del servidor (excluir)
    local SERVER_IPS
    SERVER_IPS=$(timeout ${TRAF_TO}s hostname -I 2>/dev/null | tr ' ' '\n' | sort -u | tr '\n' ' ')

    # Caché de journal (una sola vez, 200 líneas, 6h)
    if [[ ! -f "$TRAF_JOURNAL_FILE" ]]; then
        timeout ${TRAF_TO}s journalctl -u ssh -u sshd -u dropbear -u abbienet-udp -u udp-custom --since "6 hours ago" -o short-unix -n 200 2>/dev/null > "$TRAF_JOURNAL_FILE" || echo "" > "$TRAF_JOURNAL_FILE"
    fi

    # Candidatas desde conntrack (puertos VPN)
    local UDP_CUSTOM_PORT="${UDP_CUSTOM_PORT:-36712}"
    local ZIVPN_PORT="${ZIVPN_PORT:-5667}"
    local CANDIDATAS
    CANDIDATAS=$(read_conntrack | awk -v ports="2100 7100 7200 7300 9900 $UDP_CUSTOM_PORT $ZIVPN_PORT" '
        BEGIN { split(ports, p, " ") }
        {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^dport=/) { dport=substr($i,7) }
                if ($i ~ /^sport=/) { sport=substr($i,7) }
                if ($i ~ /^dst=/) { dst=substr($i,5) }
                if ($i ~ /^src=/) { src=substr($i,5) }
            }
            for (port in p) {
                if (dport == p[port] || sport == p[port]) {
                    if (src !~ /^127\./ && src != "0.0.0.0") print src
                    if (dst !~ /^127\./ && dst != "0.0.0.0") print dst
                }
            }
        }' | sort -u)

    # Excluir IPs del servidor
    for sip in $SERVER_IPS; do
        CANDIDATAS=$(echo "$CANDIDATAS" | grep -v "^${sip}$")
    done

    echo "$CANDIDATAS" > "$TRAF_CAND_FILE"

    # Procesar cada IP candidata
    while IFS= read -r IP; do
        [[ -z "$IP" ]] && continue

        # ¿Ya tiene dueño válido en ip_map.db?
        local EXISTING_USER
        EXISTING_USER=$(awk -F: -v ip="$IP" '$1==ip && $2!="root" && $2!="" {print $2; exit}' "$DB_IP_MAP" 2>/dev/null)
        if [[ -n "$EXISTING_USER" ]]; then
            continue
        fi

        local USER=""

        # A. Buscar en journal cacheado
        if [[ -s "$TRAF_JOURNAL_FILE" ]]; then
            USER=$(grep -E "Accepted (password|publickey) for .* from $IP|auth succeeded for .* $IP|session opened for user .* $IP" "$TRAF_JOURNAL_FILE" | tail -1 | sed -E 's/.*for ([^ ]+) from.*/\1/; s/.*user ([^ ]+).*/\1/' | head -1)
        fi

        # B. SSH sessions vivas (who + ss + ps)
        if [[ -z "$USER" ]]; then
            # who
            local WHO_LINE
            WHO_LINE=$(who 2>/dev/null | grep "($IP)" | head -1)
            if [[ -n "$WHO_LINE" ]]; then
                USER=$(echo "$WHO_LINE" | awk '{print $1}')
            fi
        fi
        if [[ -z "$USER" ]]; then
            # ss -tnp + ps
            local SS_PID
            SS_PID=$(timeout ${TRAF_TO}s ss -tnp state established 2>/dev/null | grep ":$IP:" | head -1 | sed -E 's/.*pid=([0-9]+).*/\1/')
            if [[ -n "$SS_PID" ]]; then
                USER=$(timeout ${TRAF_TO}s ps -o user= -p "$SS_PID" 2>/dev/null | head -1 | tr -d ' ')
            fi
        fi

        # C. ZiVPN (conexiones.db)
        if [[ -z "$USER" && -f /etc/zivpn/conexiones.db ]]; then
            local ZIVPN_USER
            ZIVPN_USER=$(tac /etc/zivpn/conexiones.db 2>/dev/null | head -500 | awk -F'|' -v ip="$IP" '$5=="ok" && $2==ip {print "zivpn_"$3; exit}')
            [[ -n "$ZIVPN_USER" ]] && USER="$ZIVPN_USER"
        fi

        # D. Resolver CGNAT (ventana 300s)
        if [[ -n "$USER" ]]; then
            local PREV_USER
            PREV_USER=$(awk -F: -v ip="$IP" '$1==ip {print $2}' "$DB_IP_MAP" 2>/dev/null)
            if [[ -n "$PREV_USER" && "$PREV_USER" != "$USER" && "$PREV_USER" != "root" ]]; then
                # Verificar si ambos logins en ventana 300s
                local EPOCH_NOW=$(date +%s)
                local EPOCH_PREV=$(awk -F: -v ip="$IP" '$1==ip {print $3}' "$DB_IP_MAP" 2>/dev/null)
                if [[ -n "$EPOCH_PREV" && $((EPOCH_NOW - EPOCH_PREV)) -le 300 ]]; then
                    # CGNAT: IP ambigua, desregistrar anterior
                    trafico_eliminar_reglas_ip "$PREV_USER" "$IP"
                    echo "$IP|" > "$DB_IP_MAP.tmp"
                    grep -v "^$IP:" "$DB_IP_MAP" >> "$DB_IP_MAP.tmp" 2>/dev/null
                    mv "$DB_IP_MAP.tmp" "$DB_IP_MAP"
                    USER=""  # IP queda sin dueño
                fi
            fi
        fi

        # Registrar atribución
        if [[ -n "$USER" && "$USER" != "root" ]]; then
            trafico_registrar_ip "$IP" "$USER"
        else
            # IP sin dueño demostrable
            echo "$IP|" > "$DB_IP_MAP.tmp"
            grep -v "^$IP:" "$DB_IP_MAP" >> "$DB_IP_MAP.tmp" 2>/dev/null
            mv "$DB_IP_MAP.tmp" "$DB_IP_MAP"
        fi

    done <<< "$CANDIDATAS"

    TRAF_SYNC_DONE=1
}

# ── Registrar IP → usuario (crea reglas iptables) ────
trafico_registrar_ip() {
    local IP=$1 USER=$2
    [[ -z "$IP" || -z "$USER" ]] && return 1

    trafico_init_usuario "$USER"

    local CHAIN_IN="ABN_${USER}_IN"
    local CHAIN_OUT="ABN_${USER}_OUT"

    # Eliminar reglas del dueño anterior si existía
    local PREV_USER
    PREV_USER=$(awk -F: -v ip="$IP" '$1==ip {print $2}' "$DB_IP_MAP" 2>/dev/null)
    if [[ -n "$PREV_USER" && "$PREV_USER" != "$USER" && "$PREV_USER" != "root" ]]; then
        trafico_eliminar_reglas_ip "$PREV_USER" "$IP"
    fi

    # Reglas INPUT/OUTPUT por IP (cuenta aunque socket sea root)
    iptables -C INPUT -s "$IP" -j "$CHAIN_IN" 2>/dev/null || iptables -I INPUT 1 -s "$IP" -j "$CHAIN_IN" 2>/dev/null
    iptables -C OUTPUT -d "$IP" -j "$CHAIN_OUT" 2>/dev/null || iptables -I OUTPUT 1 -d "$IP" -j "$CHAIN_OUT" 2>/dev/null

    # Contabilidad por UID (si usuario de sistema, UID >= 1000)
    local UID_NUM
    UID_NUM=$(awk -F: -v u="$USER" '$1==u {print $3; exit}' /etc/passwd 2>/dev/null)
    if [[ -n "$UID_NUM" && "$UID_NUM" -ge 1000 ]]; then
        iptables -C OUTPUT -m owner --uid-owner "$UID_NUM" -j "$CHAIN_OUT" 2>/dev/null || \
            iptables -A OUTPUT -m owner --uid-owner "$UID_NUM" -j "$CHAIN_OUT" 2>/dev/null
        iptables -t mangle -C OUTPUT -m owner --uid-owner "$UID_NUM" -j CONNMARK --set-mark "$UID_NUM" 2>/dev/null || \
            iptables -t mangle -A OUTPUT -m owner --uid-owner "$UID_NUM" -j CONNMARK --set-mark "$UID_NUM" 2>/dev/null
        iptables -t mangle -C PREROUTING -j CONNMARK --restore-mark 2>/dev/null || \
            iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark 2>/dev/null
        iptables -C INPUT -m connmark --mark "$UID_NUM" -j "$CHAIN_IN" 2>/dev/null || \
            iptables -A INPUT -m connmark --mark "$UID_NUM" -j "$CHAIN_IN" 2>/dev/null
    fi

    # Actualizar ip_map.db
    local EPOCH=$(date +%s)
    echo "$IP:$USER:$EPOCH" > "$DB_IP_MAP.tmp"
    grep -v "^$IP:" "$DB_IP_MAP" >> "$DB_IP_MAP.tmp" 2>/dev/null
    mv "$DB_IP_MAP.tmp" "$DB_IP_MAP"
}

# ── Eliminar reglas de una IP para un usuario ───────
trafico_eliminar_reglas_ip() {
    local USER=$1 IP=$2
    [[ -z "$USER" || -z "$IP" ]] && return

    local CHAIN_IN="ABN_${USER}_IN"
    local CHAIN_OUT="ABN_${USER}_OUT"

    iptables -D INPUT -s "$IP" -j "$CHAIN_IN" 2>/dev/null
    iptables -D OUTPUT -d "$IP" -j "$CHAIN_OUT" 2>/dev/null
}

# ── Cachear última conexión UDP Custom (solo cron) ──
trafico_cachear_udp_ultima() {
    # Solo la ejecuta el cron (no el render)
    [[ -t 0 ]] && return 0  # si hay TTY, no es cron

    local JOURNAL_FILE="/tmp/abbienet_traf_udp.$$.journal"
    timeout ${TRAF_TO}s journalctl -u abbienet-udp -u udp-custom --since "7 days ago" -o short-unix -n 500 2>/dev/null > "$JOURNAL_FILE" || echo "" > "$JOURNAL_FILE"

    # usuario|epoch|IP (máximo epoch por usuario)
    awk -F'[ |]' '
        /Client connected/ {
            for(i=1;i<=NF;i++) {
                if ($i ~ /^\[src:/) { ip=substr($i,6); gsub(/\]/,"",ip) }
                if ($i ~ /^\[user:/) { user=substr($i,7); gsub(/\]/,"",user) }
            }
            if (user && ip) {
                epoch=$1
                if (epoch > max[user]) { max[user]=epoch; uip[user]=ip }
            }
        }
        END {
            for (u in max) print u"|"max[u]"|"uip[u]
        }
    ' "$JOURNAL_FILE" > "$DB_UDP_ULTIMA.tmp"

    # Poda a 30 días y usuarios que ya no existen
    if [[ -s "$DB_UDP_ULTIMA.tmp" && -f "$USUARIOS_DB" ]]; then
        awk -F'|' -v now=$(date +%s) -v users_db="$USUARIOS_DB" '
            BEGIN {
                while((getline < users_db) > 0) {
                    split($0,a,":")
                    valid[a[1]]=1
                }
            }
            (now - $2) <= 2592000 && valid[$1] {print}
        ' "$DB_UDP_ULTIMA.tmp" > "$DB_UDP_ULTIMA"
    else
        mv "$DB_UDP_ULTIMA.tmp" "$DB_UDP_ULTIMA" 2>/dev/null
    fi
    rm -f "$JOURNAL_FILE"
}

# ── Guardar snapshot (cron cada 1 min) ──────────────
trafico_guardar_snapshot() {
    trafico_sincronizar_ips
    trafico_cachear_udp_ultima

    local NOW=$(date +%s)
    local HOY=$(date +%F)
    local HHMM=$(date +%H:%M)

    # 1) Usuarios SSH/UDP del sistema (desde usuarios.db, excluir root)
    if [[ -f "$USUARIOS_DB" ]]; then
        while IFS=: read -r USER REST; do
            [[ -z "$USER" || "$USER" == "root" ]] && continue
            [[ "$USER" == \#* ]] && continue

            trafico_init_usuario "$USER"
            local CHAIN_IN="ABN_${USER}_IN"
            local CHAIN_OUT="ABN_${USER}_OUT"

            local BYTES_IN=$(get_chain_bytes "$CHAIN_IN")
            local BYTES_OUT=$(get_chain_bytes "$CHAIN_OUT")
            BYTES_IN=${BYTES_IN:-0}
            BYTES_OUT=${BYTES_OUT:-0}
            local LIVE=$(( BYTES_IN + BYTES_OUT ))

            if [[ $LIVE -gt 0 ]]; then
                # Acumular en consumo.db
                local CUR=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_CONSUMO" 2>/dev/null)
                CUR=${CUR:-0}
                echo "$USER:$((CUR + LIVE))" > "$DB_CONSUMO.tmp"
                grep -v "^$USER:" "$DB_CONSUMO" >> "$DB_CONSUMO.tmp" 2>/dev/null
                mv "$DB_CONSUMO.tmp" "$DB_CONSUMO"

                # Acumular en historial diario
                local CUR_DAY=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DIR_HISTORIAL/$HOY.db" 2>/dev/null)
                CUR_DAY=${CUR_DAY:-0}
                echo "$USER:$((CUR_DAY + LIVE))" > "$DIR_HISTORIAL/$HOY.db.tmp"
                grep -v "^$USER:" "$DIR_HISTORIAL/$HOY.db" >> "$DIR_HISTORIAL/$HOY.db.tmp" 2>/dev/null
                mv "$DIR_HISTORIAL/$HOY.db.tmp" "$DIR_HISTORIAL/$HOY.db"

                # Resetear contadores iptables
                iptables -Z "$CHAIN_IN" "$CHAIN_OUT" 2>/dev/null
            fi
        done < "$USUARIOS_DB"
    fi

    # 2) ZiVPN pseudo-usuarios "zivpn_<clave>"
    if [[ -f /etc/zivpn/config.json ]]; then
        local CLAVES
        if command -v jq >/dev/null 2>&1; then
            CLAVES=$(jq -r '.clients[].password' /etc/zivpn/config.json 2>/dev/null)
        else
            CLAVES=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/zivpn/config.json 2>/dev/null | sed 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
        # Respaldo: caducidad.db
        [[ -z "$CLAVES" && -f /etc/zivpn/caducidad.db ]] && CLAVES=$(cut -d'|' -f1 /etc/zivpn/caducidad.db 2>/dev/null)

        for CLAVE in $CLAVES; do
            [[ -z "$CLAVE" ]] && continue
            local USER="zivpn_${CLAVE}"

            trafico_init_usuario "$USER"
            local CHAIN_IN="ABN_${USER}_IN"
            local CHAIN_OUT="ABN_${USER}_OUT"

            local BYTES_IN=$(get_chain_bytes "$CHAIN_IN")
            local BYTES_OUT=$(get_chain_bytes "$CHAIN_OUT")
            BYTES_IN=${BYTES_IN:-0}
            BYTES_OUT=${BYTES_OUT:-0}
            local LIVE=$(( BYTES_IN + BYTES_OUT ))

            if [[ $LIVE -gt 0 ]]; then
                local CUR=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_CONSUMO" 2>/dev/null)
                CUR=${CUR:-0}
                echo "$USER:$((CUR + LIVE))" > "$DB_CONSUMO.tmp"
                grep -v "^$USER:" "$DB_CONSUMO" >> "$DB_CONSUMO.tmp" 2>/dev/null
                mv "$DB_CONSUMO.tmp" "$DB_CONSUMO"

                local CUR_DAY=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DIR_HISTORIAL/$HOY.db" 2>/dev/null)
                CUR_DAY=${CUR_DAY:-0}
                echo "$USER:$((CUR_DAY + LIVE))" > "$DIR_HISTORIAL/$HOY.db.tmp"
                grep -v "^$USER:" "$DIR_HISTORIAL/$HOY.db" >> "$DIR_HISTORIAL/$HOY.db.tmp" 2>/dev/null
                mv "$DIR_HISTORIAL/$HOY.db.tmp" "$DIR_HISTORIAL/$HOY.db"

                iptables -Z "$CHAIN_IN" "$CHAIN_OUT" 2>/dev/null
            fi
        done
    fi

    # 3) Snapshot interfaz servidor
    local IFACE=$(get_iface)
    local RX=0 TX=0
    if [[ -f "/sys/class/net/$IFACE/statistics/rx_bytes" ]]; then
        RX=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes" 2>/dev/null)
        TX=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null)
    fi
    echo "$HHMM:$RX:$TX" >> "$DIR_SNAPSHOTS/$HOY.snap"

    # 4) Invalidar caché live
    invalidate_live_cache

    # 5) Verificar límites (auto-bloqueo)
    trafico_verificar_limites
}

# ── Verificar límites y bloquear/desbloquear ────────
trafico_verificar_limites() {
    # 1) Limpieza preventiva: desbloquear injustificados
    if [[ -s "$DB_BLOQUEADOS" ]]; then
        while IFS=: read -r USER EPOCH_BLOQ; do
            [[ -z "$USER" ]] && continue
            local LIM=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_LIMITES" 2>/dev/null)
            LIM=${LIM:-0}
            local CONSUMO=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_CONSUMO" 2>/dev/null)
            CONSUMO=${CONSUMO:-0}
            local LIM_BYTES=$(( LIM * 1073741824 ))
            if [[ $LIM -le 0 || $CONSUMO -lt $LIM_BYTES ]]; then
                trafico_desbloquear_usuario "$USER"
            fi
        done < "$DB_BLOQUEADOS"
    fi

    # 2) Bloquear quien consumo >= límite
    if [[ -s "$DB_LIMITES" ]]; then
        while IFS=: read -r USER LIM_GB; do
            [[ -z "$USER" || "$LIM_GB" -le 0 ]] && continue
            local CONSUMO=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_CONSUMO" 2>/dev/null)
            CONSUMO=${CONSUMO:-0}
            local LIM_BYTES=$(( LIM_GB * 1073741824 ))
            if [[ $CONSUMO -ge $LIM_BYTES ]]; then
                trafico_bloquear_usuario "$USER"
            fi
        done < "$DB_LIMITES"
    fi
}

# ── Bloquear usuario (protección absoluta) ──────────
trafico_bloquear_usuario() {
    local USER=$1
    [[ -z "$USER" ]] && return 1

    local LIM=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_LIMITES" 2>/dev/null)
    LIM=${LIM:-0}
    local CONSUMO=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_CONSUMO" 2>/dev/null)
    CONSUMO=${CONSUMO:-0}
    local LIM_BYTES=$(( LIM * 1073741824 ))

    # PROTECCIÓN ABSOLUTA: no bloquear si ilimitado o consumo < límite
    if [[ $LIM -le 0 || $CONSUMO -lt $LIM_BYTES ]]; then
        trafico_desbloquear_usuario "$USER"
        return 0
    fi

    # 1. Bloquear cuenta PAM/shadow
    usermod -L "$USER" 2>/dev/null
    chage -E 0 "$USER" 2>/dev/null

    # 2. Matar procesos
    pkill -9 -u "$USER" 2>/dev/null
    pkill -9 -f "sshd:.*$USER" 2>/dev/null
    pkill -9 -f "dropbear.*$USER" 2>/dev/null

    # 3. DROP INPUT para todas sus IPs
    if [[ -f "$DB_IP_MAP" ]]; then
        awk -F: -v u="$USER" '$2==u {print $1}' "$DB_IP_MAP" 2>/dev/null | while read -r IP; do
            [[ -n "$IP" ]] && iptables -I INPUT 1 -s "$IP" -j DROP 2>/dev/null
        done
    fi

    # 4. Registrar en bloqueados.db + logger
    echo "$USER:$(date +%s)" > "$DB_BLOQUEADOS.tmp"
    grep -v "^$USER:" "$DB_BLOQUEADOS" >> "$DB_BLOQUEADOS.tmp" 2>/dev/null
    mv "$DB_BLOQUEADOS.tmp" "$DB_BLOQUEADOS"
    logger "Maxinet: $USER bloqueado por límite de consumo ($(human "$CONSUMO")/${LIM}GB)"
}

# ── Desbloquear usuario ────────────────────────────
trafico_desbloquear_usuario() {
    local USER=$1
    [[ -z "$USER" ]] && return 1

    # 1. Desbloquear cuenta
    usermod -U "$USER" 2>/dev/null
    local EXP=-1
    if [[ -f "$USUARIOS_DB" ]]; then
        EXP=$(awk -F: -v u="$USER" '$1==u {print $3; exit}' "$USUARIOS_DB" 2>/dev/null)
        [[ -n "$EXP" && "$EXP" != "0" ]] && chage -E "$EXP" "$USER" 2>/dev/null || chage -E -1 "$USER" 2>/dev/null
    else
        chage -E -1 "$USER" 2>/dev/null
    fi

    # 2. Borrar reglas DROP de sus IPs
    if [[ -f "$DB_IP_MAP" ]]; then
        awk -F: -v u="$USER" '$2==u {print $1}' "$DB_IP_MAP" 2>/dev/null | while read -r IP; do
            [[ -n "$IP" ]] && iptables -D INPUT -s "$IP" -j DROP 2>/dev/null
        done
    fi

    # 3. Limpiar bloqueados.db + logger
    grep -v "^$USER:" "$DB_BLOQUEADOS" > "$DB_BLOQUEADOS.tmp" 2>/dev/null
    mv "$DB_BLOQUEADOS.tmp" "$DB_BLOQUEADOS"
    logger "Maxinet: $USER desbloqueado (límite ajustado o consumo reiniciado)"
}

# ── Set límite GB (0 = ilimitado) ──────────────────
trafico_set_limite() {
    local USER=$1 LIM_GB=$2
    [[ -z "$USER" ]] && return 1
    LIM_GB=${LIM_GB:-0}
    [[ "$LIM_GB" =~ ^[0-9]+$ ]] || LIM_GB=0

    if [[ $LIM_GB -eq 0 ]]; then
        # Ilimitado: borrar entrada
        grep -v "^$USER:" "$DB_LIMITES" > "$DB_LIMITES.tmp" 2>/dev/null
        mv "$DB_LIMITES.tmp" "$DB_LIMITES"
        trafico_desbloquear_usuario "$USER"
    else
        echo "$USER:$LIM_GB" > "$DB_LIMITES.tmp"
        grep -v "^$USER:" "$DB_LIMITES" >> "$DB_LIMITES.tmp" 2>/dev/null
        mv "$DB_LIMITES.tmp" "$DB_LIMITES"
        # Si el nuevo límite deja al usuario por debajo, desbloquear
        local CONSUMO=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_CONSUMO" 2>/dev/null)
        CONSUMO=${CONSUMO:-0}
        local LIM_BYTES=$(( LIM_GB * 1073741824 ))
        if [[ $CONSUMO -lt $LIM_BYTES ]]; then
            trafico_desbloquear_usuario "$USER"
        fi
    fi
}

# ── Resetear consumo de un usuario ─────────────────
trafico_reset_usuario() {
    local USER=$1
    [[ -z "$USER" ]] && return 1

    # consumo.db a 0
    grep -v "^$USER:" "$DB_CONSUMO" > "$DB_CONSUMO.tmp" 2>/dev/null
    mv "$DB_CONSUMO.tmp" "$DB_CONSUMO"

    # Borrar entrada del día en historial
    local HOY=$(date +%F)
    grep -v "^$USER:" "$DIR_HISTORIAL/$HOY.db" > "$DIR_HISTORIAL/$HOY.db.tmp" 2>/dev/null
    mv "$DIR_HISTORIAL/$HOY.db.tmp" "$DIR_HISTORIAL/$HOY.db"

    # Resetear contadores iptables
    trafico_init_usuario "$USER"
    iptables -Z "ABN_${USER}_IN" "ABN_${USER}_OUT" 2>/dev/null

    # Desbloquear si estaba bloqueado
    trafico_desbloquear_usuario "$USER"
}

# ── Eliminar usuario (purga total) ─────────────────
trafico_eliminar_usuario() {
    local USER=$1
    [[ -z "$USER" ]] && return 1

    # Purga 4 DBs
    grep -v "^$USER:" "$DB_CONSUMO" > "$DB_CONSUMO.tmp" 2>/dev/null && mv "$DB_CONSUMO.tmp" "$DB_CONSUMO"
    grep -v "^$USER:" "$DB_LIMITES" > "$DB_LIMITES.tmp" 2>/dev/null && mv "$DB_LIMITES.tmp" "$DB_LIMITES"
    grep -v "^$USER:" "$DB_BLOQUEADOS" > "$DB_BLOQUEADOS.tmp" 2>/dev/null && mv "$DB_BLOQUEADOS.tmp" "$DB_BLOQUEADOS"
    # ip_map.db: eliminar entradas donde usuario coincide
    awk -F: -v u="$USER" '$2!=u' "$DB_IP_MAP" > "$DB_IP_MAP.tmp" 2>/dev/null && mv "$DB_IP_MAP.tmp" "$DB_IP_MAP"

    # Flush y delete cadenas iptables
    iptables -F "ABN_${USER}_IN" 2>/dev/null
    iptables -F "ABN_${USER}_OUT" 2>/dev/null
    iptables -X "ABN_${USER}_IN" 2>/dev/null
    iptables -X "ABN_${USER}_OUT" 2>/dev/null

    trafico_desbloquear_usuario "$USER"
}

# ── Instalar servicio cron ─────────────────────────
trafico_instalar_servicio() {
    local CRON_SCRIPT="/etc/maxinet/scripts/trafico_cron.sh"
    mkdir -p /etc/maxinet/scripts 2>/dev/null

    cat > "$CRON_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/maxinet/herramientas/trafico.sh
trafico_guardar_snapshot
EOF
    chmod +x "$CRON_SCRIPT"

    # Registrar cron sin duplicar
    (crontab -l 2>/dev/null | grep -v 'trafico_cron' ; echo "* * * * * /bin/bash /etc/maxinet/scripts/trafico_cron.sh >/dev/null 2>&1") | crontab -
}

# ── Obtener consumo live de un usuario (para UI) ────
trafico_get_live() {
    local USER=$1
    trafico_init_usuario "$USER"
    local IN=$(get_chain_bytes "ABN_${USER}_IN")
    local OUT=$(get_chain_bytes "ABN_${USER}_OUT")
    echo $(( ${IN:-0} + ${OUT:-0} ))
}

# ── Obtener consumo de hoy de un usuario ───────────
trafico_get_hoy() {
    local USER=$1
    local HOY=$(date +%F)
    awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DIR_HISTORIAL/$HOY.db" 2>/dev/null || echo 0
}

# ── Obtener consumo acumulado de un usuario ────────
trafico_get_acumulado() {
    local USER=$1
    awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_CONSUMO" 2>/dev/null || echo 0
}

# ── Obtener límite GB de un usuario ────────────────
trafico_get_limite_gb() {
    local USER=$1
    awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_LIMITES" 2>/dev/null || echo 0
}

# ── Verificar si usuario está bloqueado ────────────
trafico_esta_bloqueado() {
    local USER=$1
    grep -q "^$USER:" "$DB_BLOQUEADOS" 2>/dev/null
}

# ── Tráfico total servidor HOY (delta snapshots) ────
trafico_servidor_hoy() {
    local HOY=$(date +%F)
    local SNAP="$DIR_SNAPSHOTS/$HOY.snap"
    [[ -f "$SNAP" ]] || echo 0
    local FIRST=$(head -1 "$SNAP" 2>/dev/null)
    local LAST=$(tail -1 "$SNAP" 2>/dev/null)
    [[ -z "$FIRST" || -z "$LAST" ]] && echo 0
    local RX1=$(echo "$FIRST" | cut -d: -f2)
    local TX1=$(echo "$FIRST" | cut -d: -f3)
    local RX2=$(echo "$LAST" | cut -d: -f2)
    local TX2=$(echo "$LAST" | cut -d: -f3)
    local DRX=$(( RX2 - RX1 )); [[ $DRX -lt 0 ]] && DRX=0
    local DTX=$(( TX2 - TX1 )); [[ $DTX -lt 0 ]] && DTX=0
    echo $(( DRX + DTX ))
}

# ── Tráfico servidor día específico (para gráficas) ─
trafico_servidor_dia() {
    local DIA=$1
    local SNAP="$DIR_SNAPSHOTS/$DIA.snap"
    [[ -f "$SNAP" ]] || echo 0
    local FIRST=$(head -1 "$SNAP" 2>/dev/null)
    local LAST=$(tail -1 "$SNAP" 2>/dev/null)
    [[ -z "$FIRST" || -z "$LAST" ]] && echo 0
    local RX1=$(echo "$FIRST" | cut -d: -f2)
    local TX1=$(echo "$FIRST" | cut -d: -f3)
    local RX2=$(echo "$LAST" | cut -d: -f2)
    local TX2=$(echo "$LAST" | cut -d: -f3)
    local DRX=$(( RX2 - RX1 )); [[ $DRX -lt 0 ]] && DRX=0
    local DTX=$(( TX2 - TX1 )); [[ $DTX -lt 0 ]] && DTX=0
    echo $(( DRX + DTX ))
}

# =========================================================
# UI — PANTALLAS ESTILO ABBIENET (70 columnas)
# =========================================================

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

# ── [1] Resumen de Consumo Hoy ──────────────────────
trafico_render_resumen_hoy() {
    clear
    local HOY_FMT=$(date '+%d %b %Y')
    H1
    title "📊 RESUMEN DE CONSUMO — $HOY_FMT"
    H2

    # Tráfico total servidor hoy
    local SRV_HOY=$(trafico_servidor_hoy)
    printf "${CYAN}║${WHITE}   Tráfico Total Servidor Hoy: ${YELLOW}%s${RESET}${CYAN}%*s║${RESET}\n" "$(human "$SRV_HOY")" $((W - 34 - ${#SRV_HOY})) ""

    H2
    printf "${CYAN}║${WHITE}   ▸ SSH / UDP Custom${RESET}${CYAN}%*s║${RESET}\n" $((W - 22)) ""
    H2
    printf "${CYAN}║${GRAY}   %-16s %10s %12s %10s %s${RESET}${CYAN} ║${RESET}\n" "USUARIO" "HOY" "ACUMULADO" "LÍMITE" "ESTADO"

    local HAY_USUARIOS=0
    if [[ -f "$USUARIOS_DB" ]]; then
        while IFS=: read -r USER REST; do
            [[ -z "$USER" || "$USER" == "root" ]] && continue
            [[ "$USER" == \#* ]] && continue
            HAY_USUARIOS=1

            local HOY_B=$(trafico_get_hoy "$USER")
            local ACC_B=$(trafico_get_acumulado "$USER")
            local LIM_GB=$(trafico_get_limite_gb "$USER")
            local LIM_B=$(( LIM_GB * 1073741824 ))
            local LIVE_B=$(trafico_get_live "$USER")
            local TOTAL_HOY=$(( HOY_B + LIVE_B ))
            local TOTAL_ACC=$(( ACC_B + LIVE_B ))

            local LIM_STR="∞"
            [[ $LIM_GB -gt 0 ]] && LIM_STR="${LIM_GB} GB"

            local ESTADO="${GREEN}OK${RESET}"
            local PCT=0
            [[ $LIM_B -gt 0 ]] && PCT=$(( TOTAL_ACC * 100 / LIM_B ))
            [[ $PCT -ge 80 ]] && ESTADO="${YELLOW}⚠ ${PCT}%${RESET}"
            [[ $PCT -ge 100 ]] && ESTADO="${RED}⛔ ${PCT}%${RESET}"
            if trafico_esta_bloqueado "$USER"; then
                ESTADO="${RED}[BLOQUEADO]${RESET}"
                # Desbloqueo automático si ya no tiene límite real
                if [[ $LIM_GB -le 0 ]]; then
                    trafico_desbloquear_usuario "$USER"
                    ESTADO="${GREEN}OK (desbloqueado)${RESET}"
                fi
            fi

            printf "${CYAN}║${WHITE}   %-16s ${CYAN}%10s ${WHITE}%12s ${YELLOW}%10s ${CYAN}%s${RESET}${CYAN} ║${RESET}\n" \
                "$USER" "$(human "$TOTAL_HOY")" "$(human "$TOTAL_ACC")" "$LIM_STR" "$ESTADO"
        done < "$USUARIOS_DB"
    fi

    if [[ $HAY_USUARIOS -eq 0 ]]; then
        printf "${CYAN}║${GRAY}   %*s${RESET}${CYAN} ║${RESET}\n" $((W-6)) "Sin usuarios registrados (crea uno en el menú [1])."
    fi

    H2
    printf "${CYAN}║${WHITE}   ▸ ZiVPN${RESET}${CYAN}%*s║${RESET}\n" $((W - 10)) ""
    H2
    printf "${CYAN}║${GRAY}   %-16s %10s %12s %10s %s${RESET}${CYAN} ║${RESET}\n" "CONTRASEÑA" "HOY" "ACUMULADO" "LÍMITE" "ESTADO"

    local HAY_ZIVPN=0
    if [[ -f /etc/zivpn/config.json ]]; then
        local CLAVES
        if command -v jq >/dev/null 2>&1; then
            CLAVES=$(jq -r '.clients[].password' /etc/zivpn/config.json 2>/dev/null)
        else
            CLAVES=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/zivpn/config.json 2>/dev/null | sed 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
        [[ -z "$CLAVES" && -f /etc/zivpn/caducidad.db ]] && CLAVES=$(cut -d'|' -f1 /etc/zivpn/caducidad.db 2>/dev/null)

        for CLAVE in $CLAVES; do
            [[ -z "$CLAVE" ]] && continue
            HAY_ZIVPN=1
            local USER="zivpn_${CLAVE}"

            local HOY_B=$(trafico_get_hoy "$USER")
            local ACC_B=$(trafico_get_acumulado "$USER")
            local LIM_GB=$(trafico_get_limite_gb "$USER")
            local LIM_B=$(( LIM_GB * 1073741824 ))
            local LIVE_B=$(trafico_get_live "$USER")
            local TOTAL_HOY=$(( HOY_B + LIVE_B ))
            local TOTAL_ACC=$(( ACC_B + LIVE_B ))

            local LIM_STR="∞"
            [[ $LIM_GB -gt 0 ]] && LIM_STR="${LIM_GB} GB"

            local ESTADO="${GREEN}OK${RESET}"
            local PCT=0
            [[ $LIM_B -gt 0 ]] && PCT=$(( TOTAL_ACC * 100 / LIM_B ))
            [[ $PCT -ge 80 ]] && ESTADO="${YELLOW}⚠ ${PCT}%${RESET}"
            [[ $PCT -ge 100 ]] && ESTADO="${RED}⛔ ${PCT}%${RESET}"
            if trafico_esta_bloqueado "$USER"; then
                ESTADO="${RED}[BLOQUEADO]${RESET}"
                if [[ $LIM_GB -le 0 ]]; then
                    trafico_desbloquear_usuario "$USER"
                    ESTADO="${GREEN}OK (desbloqueado)${RESET}"
                fi
            fi

            printf "${CYAN}║${WHITE}   🔑 %-14s ${CYAN}%10s ${WHITE}%12s ${YELLOW}%10s ${CYAN}%s${RESET}${CYAN} ║${RESET}\n" \
                "$CLAVE" "$(human "$TOTAL_HOY")" "$(human "$TOTAL_ACC")" "$LIM_STR" "$ESTADO"
        done
    fi

    if [[ $HAY_ZIVPN -eq 0 ]]; then
        printf "${CYAN}║${GRAY}   %*s${RESET}${CYAN} ║${RESET}\n" $((W-6)) "Sin contraseñas ZiVPN configuradas."
    fi

    H2
    # Notas honestas
    local CONNTRACK_OK=0
    [[ -r /proc/net/nf_conntrack || -r /proc/net/ip_conntrack ]] && CONNTRACK_OK=1
    if [[ $CONNTRACK_OK -eq 0 ]]; then
        printf "${CYAN}║${YELLOW}   ⚠ conntrack no disponible (N/D)${RESET}${CYAN}%*s║${RESET}\n" $((W - 35)) ""
    fi

    # Contar IPs sin dueño
    local IP_SIN_DUENO=0
    if [[ -f "$DB_IP_MAP" ]]; then
        IP_SIN_DUENO=$(awk -F: '$2=="" || $2=="root" {count++} END{print count+0}' "$DB_IP_MAP")
    fi
    if [[ $IP_SIN_DUENO -gt 0 ]]; then
        printf "${CYAN}║${YELLOW}   ℹ️  %d IP(s) con tráfico real sin dueño demostrable (N/D)${RESET}${CYAN}%*s║${RESET}\n" "$IP_SIN_DUENO" $((W - 55 - ${#IP_SIN_DUENO})) ""
    fi

    if [[ $HAY_USUARIOS -eq 0 && $HAY_ZIVPN -eq 0 ]]; then
        printf "${CYAN}║${GRAY}   Sin flujos atribuidos todavía (0 B). El cron consolida cada minuto.${RESET}${CYAN}%*s║${RESET}\n" $((W - 68)) ""
    fi

    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
}

# ── [2] Gráfica Semanal ────────────────────────────
trafico_render_grafica_semanal() {
    clear
    H1
    title "📈 GRÁFICA SEMANAL (ÚLTIMOS 7 DÍAS)"
    H2

    local TOTAL_SEM=0
    for i in $(seq 6 -1 0); do
        local DIA=$(date -d "-$i days" +%F 2>/dev/null || date -v-${i}d +%F 2>/dev/null)
        local BYTES=$(trafico_servidor_dia "$DIA")
        TOTAL_SEM=$(( TOTAL_SEM + BYTES ))
        local ETIQUETA=""
        [[ $i -eq 0 ]] && ETIQUETA=" ${GOLD}← HOY${RESET}"
        local BAR
        BAR=$(bar_pct "$BYTES" 10737418240 30)  # escala 10 GB
        printf "${CYAN}║${WHITE} %s ${CYAN}|${RESET} %s${CYAN}%s║${RESET}\n" "$DIA" "$BAR" "$ETIQUETA"
    done

    H2
    printf "${CYAN}║${WHITE}   Total semana: ${YELLOW}%s${RESET}${CYAN}%*s║${RESET}\n" "$(human "$TOTAL_SEM")" $((W - 18 - ${#TOTAL_SEM})) ""
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
}

# ── [3] Gráfica Mensual ────────────────────────────
trafico_render_grafica_mensual() {
    clear
    H1
    title "📆 GRÁFICA MENSUAL (ÚLTIMOS 30 DÍAS)"
    H2

    local TOTAL_MES=0
    for i in $(seq 29 -1 0); do
        local DIA=$(date -d "-$i days" +%F 2>/dev/null || date -v-${i}d +%F 2>/dev/null)
        local BYTES=$(trafico_servidor_dia "$DIA")
        TOTAL_MES=$(( TOTAL_MES + BYTES ))
        local ETIQUETA=""
        [[ $i -eq 0 ]] && ETIQUETA=" ${GOLD}←${RESET}"
        local BAR
        BAR=$(bar_pct "$BYTES" 10737418240 25)  # escala 10 GB
        printf "${CYAN}║${WHITE} %s ${CYAN}|${RESET} %s${CYAN}%s║${RESET}\n" "$DIA" "$BAR" "$ETIQUETA"
    done

    H2
    printf "${CYAN}║${WHITE}   Total mes: ${YELLOW}%s${RESET}${CYAN}%*s║${RESET}\n" "$(human "$TOTAL_MES")" $((W - 15 - ${#TOTAL_MES})) ""
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
}

# ── [4] Consumo Detallado por Usuario ──────────────
trafico_render_detalle_usuario() {
    while true; do
        clear
        H1
        title "👤 CONSUMO DETALLADO POR USUARIO"
        H2

        local USUARIOS=()
        local IDX=1
        if [[ -f "$USUARIOS_DB" ]]; then
            while IFS=: read -r USER REST; do
                [[ -z "$USER" || "$USER" == "root" ]] && continue
                [[ "$USER" == \#* ]] && continue
                local ACC=$(trafico_get_acumulado "$USER")
                local LIM=$(trafico_get_limite_gb "$USER")
                local LIM_STR="∞"
                [[ $LIM -gt 0 ]] && LIM_STR="${LIM} GB"
                local ESTADO=""
                trafico_esta_bloqueado "$USER" && ESTADO=" ${RED}⛔ BLOQUEADO${RESET}"
                printf "${CYAN}║${WHITE}   [%02d] %-16s %12s / %-8s %s${RESET}${CYAN} ║${RESET}\n" "$IDX" "$USER" "$(human "$ACC")" "$LIM_STR" "$ESTADO"
                USUARIOS+=("$USER")
                IDX=$((IDX + 1))
            done < "$USUARIOS_DB"
        fi

        # ZiVPN
        if [[ -f /etc/zivpn/config.json ]]; then
            local CLAVES
            if command -v jq >/dev/null 2>&1; then
                CLAVES=$(jq -r '.clients[].password' /etc/zivpn/config.json 2>/dev/null)
            else
                CLAVES=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/zivpn/config.json 2>/dev/null | sed 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            fi
            [[ -z "$CLAVES" && -f /etc/zivpn/caducidad.db ]] && CLAVES=$(cut -d'|' -f1 /etc/zivpn/caducidad.db 2>/dev/null)

            for CLAVE in $CLAVES; do
                [[ -z "$CLAVE" ]] && continue
                local USER="zivpn_${CLAVE}"
                local ACC=$(trafico_get_acumulado "$USER")
                local LIM=$(trafico_get_limite_gb "$USER")
                local LIM_STR="∞"
                [[ $LIM -gt 0 ]] && LIM_STR="${LIM} GB"
                local ESTADO=""
                trafico_esta_bloqueado "$USER" && ESTADO=" ${RED}⛔ BLOQUEADO${RESET}"
                printf "${CYAN}║${WHITE}   [%02d] 🔑 %-14s %12s / %-8s %s${RESET}${CYAN} ║${RESET}\n" "$IDX" "$CLAVE" "$(human "$ACC")" "$LIM_STR" "$ESTADO"
                USUARIOS+=("$USER")
                IDX=$((IDX + 1))
            done
        fi

        if [[ ${#USUARIOS[@]} -eq 0 ]]; then
            printf "${CYAN}║${GRAY}   %*s${RESET}${CYAN} ║${RESET}\n" $((W-6)) "Sin usuarios registrados."
            H3
            echo ""
            read -rp "$(trx '   Presiona Enter para volver... ')" _
            return
        fi

        H3
        echo ""
        read -rp "$(trx '   ► Seleccione usuario [0=Volver]: ')" SEL
        [[ "$SEL" == "0" || -z "$SEL" ]] && return
        [[ "$SEL" =~ ^[0-9]+$ ]] || continue
        local IDX_SEL=$((SEL - 1))
        [[ $IDX_SEL -ge 0 && $IDX_SEL -lt ${#USUARIOS[@]} ]] || continue

        local USER="${USUARIOS[$IDX_SEL]}"
        trafico_render_usuario_detalle "$USER"
    done
}

trafico_render_usuario_detalle() {
    local USER=$1
    while true; do
        clear
        local ACC=$(trafico_get_acumulado "$USER")
        local HOY=$(trafico_get_hoy "$USER")
        local LIVE=$(trafico_get_live "$USER")
        local TOTAL_ACC=$(( ACC + LIVE ))
        local TOTAL_HOY=$(( HOY + LIVE ))
        local LIM_GB=$(trafico_get_limite_gb "$USER")
        local LIM_B=$(( LIM_GB * 1073741824 ))
        local LIM_STR="Ilimitado"
        [[ $LIM_GB -gt 0 ]] && LIM_STR="${LIM_GB} GB"

        H1
        local DISP_USER="$USER"
        [[ "$USER" == zivpn_* ]] && DISP_USER="🔑 ${USER#zivpn_}"
        title "👤 DETALLE: $DISP_USER"
        H2

        printf "${CYAN}║${WHITE}   Consumo acumulado: ${YELLOW}%s${RESET}${CYAN}%*s║${RESET}\n" "$(human "$TOTAL_ACC")" $((W - 22 - ${#TOTAL_ACC})) ""
        printf "${CYAN}║${WHITE}   Consumo hoy:       ${CYAN}%s${RESET}${CYAN}%*s║${RESET}\n" "$(human "$TOTAL_HOY")" $((W - 20 - ${#TOTAL_HOY})) ""
        printf "${CYAN}║${WHITE}   Límite:            ${GOLD}%s${RESET}${CYAN}%*s║${RESET}\n" "$LIM_STR" $((W - 10 - ${#LIM_STR})) ""

        if trafico_esta_bloqueado "$USER"; then
            printf "${CYAN}║${RED}   Estado:            ⛔ BLOQUEADO${RESET}${CYAN}%*s║${RESET}\n" $((W - 22)) ""
        else
            printf "${CYAN}║${GREEN}   Estado:            ✅ ACTIVO${RESET}${CYAN}%*s║${RESET}\n" $((W - 20)) ""
        fi

        H2
        if [[ $LIM_B -gt 0 ]]; then
            printf "${CYAN}║${WHITE}   Uso de cuota:${RESET}${CYAN}%*s║${RESET}\n" $((W - 16)) ""
            local BAR
            BAR=$(bar_pct40 "$TOTAL_ACC" "$LIM_B")
            printf "${CYAN}║${WHITE}   %s${RESET}${CYAN} ║${RESET}\n" "$BAR"
        else
            printf "${CYAN}║${GRAY}   Sin límite configurado (ilimitado)${RESET}${CYAN}%*s║${RESET}\n" $((W - 38)) ""
        fi

        H2
        printf "${CYAN}║${WHITE}   Historial 7 días:${RESET}${CYAN}%*s║${RESET}\n" $((W - 20)) ""
        for i in $(seq 6 -1 0); do
            local DIA=$(date -d "-$i days" +%F 2>/dev/null || date -v-${i}d +%F 2>/dev/null)
            local DB_DAY="$DIR_HISTORIAL/$DIA.db"
            local DAY_B=0
            [[ -f "$DB_DAY" ]] && DAY_B=$(awk -F: -v u="$USER" '$1==u {print $2; exit}' "$DB_DAY" 2>/dev/null)
            DAY_B=${DAY_B:-0}
            local ETIQUETA=""
            [[ $i -eq 0 ]] && ETIQUETA=" ${GOLD}← HOY${RESET}"
            local BAR
            BAR=$(bar_pct "$DAY_B" 1073741824 30)  # escala 1 GB
            printf "${CYAN}║${WHITE} %s ${CYAN}|${RESET} %s${CYAN}%s║${RESET}\n" "$DIA" "$BAR" "$ETIQUETA"
        done

        H2
        printf "${CYAN}║${WHITE}   [R] ${GREEN}Resetear consumo${RESET}   [L] ${YELLOW}Cambiar límite${RESET}   [0] ${RED}Volver${RESET}${CYAN}%*s║${RESET}\n" $((W - 50)) ""
        H3
        echo ""
        read -rp "$(trx '   ► Acción: ')" ACT
        case "${ACT,,}" in
            r)
                trafico_reset_usuario "$USER"
                echo -e "${GREEN}✅ Consumo reiniciado${RESET}"
                sleep 1
                ;;
            l)
                echo ""
                read -rp "$(trx '   Nuevo límite en GB [0 = Ilimitado]: ')" NEW_LIM
                NEW_LIM=${NEW_LIM:-0}
                [[ "$NEW_LIM" =~ ^[0-9]+$ ]] || NEW_LIM=0
                trafico_set_limite "$USER" "$NEW_LIM"
                echo -e "${GREEN}✅ Límite actualizado a ${NEW_LIM} GB${RESET}"
                sleep 1
                ;;
            0) return ;;
        esac
    done
}

# ── [5] Configurar Límites de GB ───────────────────
trafico_render_config_limites() {
    while true; do
        clear
        H1
        title "🔧 CONFIGURAR LÍMITES DE GB"
        H2
        printf "${CYAN}║${GRAY}   %-16s %12s %10s %s${RESET}${CYAN} ║${RESET}\n" "USUARIO" "USO ACTUAL" "LÍMITE" "ACCIÓN"

        local USUARIOS=()
        local IDX=1
        if [[ -f "$USUARIOS_DB" ]]; then
            while IFS=: read -r USER REST; do
                [[ -z "$USER" || "$USER" == "root" ]] && continue
                [[ "$USER" == \#* ]] && continue
                local ACC=$(trafico_get_acumulado "$USER")
                local LIM=$(trafico_get_limite_gb "$USER")
                local LIM_STR="∞"
                [[ $LIM -gt 0 ]] && LIM_STR="${LIM} GB"
                printf "${CYAN}║${WHITE}   [%02d] %-16s %12s %-8s ${GRAY}[Editar]${RESET}${CYAN} ║${RESET}\n" "$IDX" "$USER" "$(human "$ACC")" "$LIM_STR"
                USUARIOS+=("$USER")
                IDX=$((IDX + 1))
            done < "$USUARIOS_DB"
        fi

        if [[ -f /etc/zivpn/config.json ]]; then
            local CLAVES
            if command -v jq >/dev/null 2>&1; then
                CLAVES=$(jq -r '.clients[].password' /etc/zivpn/config.json 2>/dev/null)
            else
                CLAVES=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/zivpn/config.json 2>/dev/null | sed 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            fi
            [[ -z "$CLAVES" && -f /etc/zivpn/caducidad.db ]] && CLAVES=$(cut -d'|' -f1 /etc/zivpn/caducidad.db 2>/dev/null)

            for CLAVE in $CLAVES; do
                [[ -z "$CLAVE" ]] && continue
                local USER="zivpn_${CLAVE}"
                local ACC=$(trafico_get_acumulado "$USER")
                local LIM=$(trafico_get_limite_gb "$USER")
                local LIM_STR="∞"
                [[ $LIM -gt 0 ]] && LIM_STR="${LIM} GB"
                printf "${CYAN}║${WHITE}   [%02d] 🔑 %-14s %12s %-8s ${GRAY}[Editar]${RESET}${CYAN} ║${RESET}\n" "$IDX" "$CLAVE" "$(human "$ACC")" "$LIM_STR"
                USUARIOS+=("$USER")
                IDX=$((IDX + 1))
            done
        fi

        if [[ ${#USUARIOS[@]} -eq 0 ]]; then
            printf "${CYAN}║${GRAY}   %*s${RESET}${CYAN} ║${RESET}\n" $((W-6)) "Sin usuarios registrados."
        fi

        H3
        echo ""
        read -rp "$(trx '   ► Seleccione usuario [0=Volver]: ')" SEL
        [[ "$SEL" == "0" || -z "$SEL" ]] && return
        [[ "$SEL" =~ ^[0-9]+$ ]] || continue
        local IDX_SEL=$((SEL - 1))
        [[ $IDX_SEL -ge 0 && $IDX_SEL -lt ${#USUARIOS[@]} ]] || continue

        local USER="${USUARIOS[$IDX_SEL]}"
        local DISP="$USER"
        [[ "$USER" == zivpn_* ]] && DISP="🔑 ${USER#zivpn_}"

        echo ""
        read -rp "$(trx "   Nuevo límite para $DISP en GB [0 = Ilimitado]: ")" NEW_LIM
        NEW_LIM=${NEW_LIM:-0}
        [[ "$NEW_LIM" =~ ^[0-9]+$ ]] || NEW_LIM=0
        trafico_set_limite "$USER" "$NEW_LIM"
        echo -e "${GREEN}✅ Límite actualizado a ${NEW_LIM} GB${RESET}"
        sleep 1
    done
}

# ── [6] Activar / Reinstalar Rastreo ───────────────
trafico_render_activar_rastreo() {
    clear
    H1
    title "⚙️  ACTIVAR / REINSTALAR RASTREO"
    H2
    printf "${CYAN}║${WHITE}   Instalando cron de vigilancia (cada 1 min)...${RESET}${CYAN}%*s║${RESET}\n" $((W - 48)) ""

    trafico_instalar_servicio

    H2
    printf "${CYAN}║${GREEN}   ✅ Rastreo y auto-bloqueo de tráfico activado${RESET}${CYAN}%*s║${RESET}\n" $((W - 48)) ""
    printf "${CYAN}║${WHITE}   Vigilancia cada 1 minuto: snapshot + límites + bloqueo${RESET}${CYAN}%*s║${RESET}\n" $((W - 58)) ""
    H3
    echo ""
    sleep 2
}

# =========================================================
# MENÚ PRINCIPAL TRÁFICO & USO
# =========================================================
menu_trafico() {
    trafico_init
    while true; do
        clear
        local IFACE=$(get_iface)
        local CONNTRACK_OK=0
        [[ -r /proc/net/nf_conntrack || -r /proc/net/ip_conntrack ]] && CONNTRACK_OK=1

        H1
        title "📊 TRÁFICO & USO v3.1.4"
        H2
        printf "${CYAN}║${WHITE}   Interfaz: ${GREEN}%s${RESET}   conntrack: %s${CYAN}%*s║${RESET}\n" "$IFACE" $([ $CONNTRACK_OK -eq 1 ] && echo -e "${GREEN}OK${RESET}" || echo -e "${RED}N/D${RESET}") $((W - 45)) ""
        H2
        printf "${CYAN}║${WHITE}   [1] 📊 Resumen de Uso Hoy${RESET}${CYAN}%*s║${RESET}\n" $((W - 26)) ""
        printf "${CYAN}║${WHITE}   [2] 📈 Gráfica Semanal (Últimos 7 días)${RESET}${CYAN}%*s║${RESET}\n" $((W - 41)) ""
        printf "${CYAN}║${WHITE}   [3] 📆 Gráfica Mensual (Últimos 30 días)${RESET}${CYAN}%*s║${RESET}\n" $((W - 42)) ""
        printf "${CYAN}║${WHITE}   [4] 👤 Consumo Detallado por Usuario${RESET}${CYAN}%*s║${RESET}\n" $((W - 37)) ""
        printf "${CYAN}║${WHITE}   [5] 🔧 Configurar Límites de GB${RESET}${CYAN}%*s║${RESET}\n" $((W - 32)) ""
        printf "${CYAN}║${WHITE}   [6] ⚙️  Activar / Reinstalar Rastreo${RESET}${CYAN}%*s║${RESET}\n" $((W - 38)) ""
        H2
        printf "${CYAN}║${RED}   [0] ↩️  Volver${RESET}${CYAN}%*s║${RESET}\n" $((W - 13)) ""
        H3
        echo ""
        read -rp "$(trx '   ► Opción: ')" OP
        case "$OP" in
            1) trafico_render_resumen_hoy ;;
            2) trafico_render_grafica_semanal ;;
            3) trafico_render_grafica_mensual ;;
            4) trafico_render_detalle_usuario ;;
            5) trafico_render_config_limites ;;
            6) trafico_render_activar_rastreo ;;
            0) return ;;
            *) echo -e "${RED}$(trx 'Opción no válida')${RESET}"; sleep 1 ;;
        esac
    done
}

# =========================================================
# CLI ENTRY POINT
# =========================================================
case "${1:-}" in
    --init)
        trafico_init
        exit 0
        ;;
    --snapshot)
        trafico_guardar_snapshot
        exit 0
        ;;
    --sync-ips)
        trafico_sincronizar_ips
        exit 0
        ;;
    --cache-udp)
        trafico_cachear_udp_ultima
        exit 0
        ;;
    --verify-limits)
        trafico_verificar_limites
        exit 0
        ;;
    --install-cron)
        trafico_instalar_servicio
        exit 0
        ;;
    --menu|"")
        menu_trafico
        ;;
    *)
        echo "Uso: $0 [--init|--snapshot|--sync-ips|--cache-udp|--verify-limits|--install-cron|--menu]"
        exit 1
        ;;
esac