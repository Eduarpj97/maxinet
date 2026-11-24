#!/bin/bash

#=========================================================
#   Maxinet Network - TRÁFICO & USO v7.1.5
#   Réplica funcional de Abbienet v7.2.5+ (módulo trafico.sh)
#   Contabilidad real via iptables/conntrack/journal — CERO datos simulados
#
#   Invariantes:
#     · iptables es la ÚNICA fuente que acumula bytes (se resetea por snapshot)
#     · conntrack solo descubre IPs; nunca suma consumo
#     · root y las IPs del propio servidor nunca se atribuyen
#     · límite 0 / ausente / no numérico = ILIMITADO (jamás se bloquea)
#     · sin evidencia (journal/ip_map/conexiones.db) la IP queda sin dueño (N/D)
#     · CGNAT: 2 logins desde la misma IP dentro de 300 s ⇒ no se asigna a nadie
#=========================================================

# ── i18n shim (auto) ───────────────────────────────
if ! declare -F trx >/dev/null 2>&1; then trx() { printf '%s' "$1"; }; fi
# ─────────────────────────────────────────────────────────

BASE="${MAXINET_BASE:-/etc/maxinet}"
DIR_TRAFICO="${MAXINET_TRAFICO_DIR:-$BASE/trafico}"
DIR_HISTORIAL="$DIR_TRAFICO/historial"
DIR_SNAPSHOTS="$DIR_TRAFICO/snapshots"

DB_CONSUMO="$DIR_TRAFICO/consumo.db"
DB_LIMITES="$DIR_TRAFICO/limites_gb.db"
DB_BLOQUEADOS="$DIR_TRAFICO/bloqueados.db"
DB_IP_MAP="$DIR_TRAFICO/ip_map.db"
DB_UDP_ULTIMA="$DIR_TRAFICO/udp_ultima.db"

USUARIOS_DB="${MAXINET_USUARIOS_DB:-${ABBIENET_USUARIOS_DB:-$BASE/usuarios.db}}"
CONFIG="$BASE/config.conf"

ZIVPN_CONFIG="${MAXINET_ZIVPN_CONFIG:-/etc/zivpn/config.json}"
ZIVPN_CONEX_DB="${MAXINET_ZIVPN_CONEX_DB:-${ABBIENET_ZIVPN_CONEX_DB:-/etc/zivpn/conexiones.db}}"
ZIVPN_CADUCIDAD="${MAXINET_ZIVPN_CADUCIDAD:-${ABBIENET_ZIVPN_CADUCIDAD:-/etc/zivpn/caducidad.db}}"

# Design System premium + navegación + idioma
[[ -f "$BASE/lib/ui.sh" ]] && source "$BASE/lib/ui.sh"
[[ -f "$BASE/lib/nav.sh" ]] && source "$BASE/lib/nav.sh" 2>/dev/null || true
if [[ -f "$BASE/languages/lang.sh" ]]; then
    source "$BASE/languages/lang.sh" 2>/dev/null
    load_language "$(get_current_language 2>/dev/null)" 2>/dev/null || true
fi

# Cargar funciones multi-distro
[[ -f "$BASE/functions/pkg.sh" ]] && source "$BASE/functions/pkg.sh"
[[ -f "$CONFIG" ]] && source "$CONFIG" 2>/dev/null

# ── Paleta (real ESC con o sin lib/ui.sh) ───────────
_traf_color() {
    local cur="${!1:-}"
    [[ -n "$cur" ]] || printf -v "$1" '%b' "$2"
}
_traf_color MV_CYN '\033[38;5;45m'
_traf_color MV_GRN '\033[38;5;82m'
_traf_color MV_YLW '\033[38;5;226m'
_traf_color MV_RED '\033[38;5;203m'
_traf_color MV_BLU '\033[38;5;39m'
_traf_color MV_MAG '\033[38;5;201m'
_traf_color MV_WHT '\033[38;5;255m'
_traf_color MV_DIM '\033[38;5;245m'
_traf_color MV_GLD '\033[38;5;220m'
_traf_color MV_R   '\033[0m'

CYAN="$MV_CYN"; GREEN="$MV_GRN"; YELLOW="$MV_YLW"; RED="$MV_RED"
BLUE="$MV_BLU"; MAGENTA="$MV_MAG"; WHITE="$MV_WHT"; GRAY="$MV_DIM"
GOLD="$MV_GLD"; RESET="$MV_R"

# ── Timeout adaptativo (ARM más lento) ──────────────
TRAF_TO=3
case "$(uname -m 2>/dev/null)" in
    aarch64|arm64|armv7l|armv8l|armv6l) TRAF_TO=5 ;;
esac

# ══════════════════════════════════════════════════════════════════
# Formateo de bytes a texto legible (nunca inventa)
# ══════════════════════════════════════════════════════════════════
trafico_formatear() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if (( bytes < 1024 )); then
        printf '%d B\n' "$bytes"
    elif (( bytes < 1048576 )); then
        printf '%d KB\n' $(( bytes / 1024 ))
    elif (( bytes < 1073741824 )); then
        awk "BEGIN{printf \"%.1f MB\n\", $bytes/1048576}"
    else
        awk "BEGIN{printf \"%.2f GB\n\", $bytes/1073741824}"
    fi
}

# Compatibilidad con el nombre anterior
human() { trafico_formatear "${1:-0}"; }

# Barra 0..max (normalizada al máximo del período)
_draw_bar() {
    local value="${1:-0}" max="${2:-0}" width="${3:-30}"
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    [[ "$max" =~ ^[0-9]+$ ]] || max=0
    (( width < 1 )) && width=1
    local filled=0 i
    (( max > 0 )) && filled=$(( value * width / max ))
    (( filled > width )) && filled=$width
    local empty=$(( width - filled ))
    for ((i = 0; i < filled; i++)); do printf '▓'; done
    for ((i = 0; i < empty; i++)); do printf '░'; done
}

# Barra de cuota con porcentaje real (usada en el detalle)
bar_pct() {
    local used="${1:-0}" limit="${2:-0}" width="${3:-30}"
    [[ "$used" =~ ^[0-9]+$ ]] || used=0
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
    if (( limit <= 0 )); then
        _draw_bar 0 1 "$width"
        printf ' ∞'
        return 0
    fi
    local pct=$(( used * 100 / limit ))
    (( pct > 100 )) && pct=100
    local color="$GREEN"
    (( pct >= 80 )) && color="$YELLOW"
    (( pct >= 100 )) && color="$RED"
    printf '%s' "$color"
    _draw_bar "$used" "$limit" "$width"
    printf '%s %3d%%' "$RESET" "$pct"
}

# ══════════════════════════════════════════════════════════════════
# Caché de datos de tráfico (UNA lectura por render)
# ══════════════════════════════════════════════════════════════════
# Los subshells de $(...) comparten el PID ($$) del padre, así que la marca en
# disco (.done) hace que todos reutilicen el mismo volcado en vez de repetirlo.
_traf_paths() {
    local base="/tmp/maxinet_traf.$$"
    TRAF_CT_MAP="${base}.ct"
    TRAF_IPT_MAP="${base}.ipt"
    TRAF_CT_CAND="${base}.cand"
    TRAF_JOURNAL="${base}.journal"
    TRAF_MARK="${base}.done"
}

trafico_limpiar_cache() {
    _traf_paths
    rm -f "$TRAF_CT_MAP" "$TRAF_IPT_MAP" "$TRAF_CT_CAND" \
          "$TRAF_JOURNAL" "$TRAF_MARK" \
          "${TRAF_CT_MAP}.raw" "${TRAF_IPT_MAP}.raw" 2>/dev/null
    TRAF_CT_OK=0
    TRAF_SYNC_DONE=0
    # TRAF_INIT_USERS se conserva: las cadenas iptables siguen existiendo y
    # recrearlas en cada render cuesta ~10 llamadas por usuario en ARM.
}

trafico_invalidar_live() {
    # Tras `iptables -Z` los contadores cacheados ya no valen: forzar re-volcado.
    _traf_paths
    rm -f "$TRAF_MARK" 2>/dev/null
    TRAF_CT_OK=0
}

# ── Volcado ÚNICO de conntrack → "IP bytes" + lista de IPs candidatas ──
trafico_ct_dump() {
    _traf_paths
    local map="$TRAF_CT_MAP"
    [[ -z "$map" ]] && return 1
    : > "$map" 2>/dev/null
    : > "$TRAF_CT_CAND" 2>/dev/null

    local raw="" src_file=""
    src_file="${MAXINET_TRAF_CT_FILE:-${ABBIENET_TRAF_CT_FILE:-}}"
    if [[ -n "$src_file" ]]; then
        [[ -r "$src_file" ]] && raw="$src_file"
    elif [[ -r /proc/net/nf_conntrack ]]; then
        raw="/proc/net/nf_conntrack"
    elif [[ -r /proc/net/ip_conntrack ]]; then
        raw="/proc/net/ip_conntrack"
    elif command -v conntrack >/dev/null 2>&1; then
        raw="${map}.raw"
        timeout "${TRAF_TO}s" conntrack -L > "$raw" 2>/dev/null
        [[ -s "$raw" ]] || { : > "$raw"; return 1; }
    fi
    [[ -z "$raw" || ! -r "$raw" ]] && return 1

    # Puertos reales: UDP Custom 36712 (2100 por compatibilidad),
    # BadVPN 7100/7200/7300/9900 y ZiVPN 5667 (port-hopping por DNAT).
    local ports="${MAXINET_TRAF_PORTS:-${ABBIENET_TRAF_PORTS:-${UDP_CUSTOM_PORT:-36712}|2100|7100|7200|7300|9900|${ZIVPN_PORT:-5667}}}"

    awk -v MAP="$map" -v CAND="${TRAF_CT_CAND:-/dev/null}" -v PORTS="$ports" '
        BEGIN { n = split(PORTS, p, "|"); for (i = 1; i <= n; i++) WANT[p[i]] = 1 }
        {
            total = 0; portok = 0; firstsrc = ""; nip = 0
            delete SRC; delete SEEN
            for (i = 1; i <= NF; i++) {
                f = $i
                if (f ~ /^src=/) {
                    ip = substr(f, 5)
                    SRC[++nip] = ip
                    if (firstsrc == "") firstsrc = ip
                } else if (f ~ /^bytes=/) {
                    total += substr(f, 7) + 0
                } else if (f ~ /^(dport|sport)=/) {
                    if (substr(f, index(f, "=") + 1) in WANT) portok = 1
                }
            }
            # Ambos extremos aparecen como src (uno por tupla): contar 1 vez.
            for (j = 1; j <= nip; j++) {
                ip = SRC[j]
                if (ip == "" || (ip in SEEN)) continue
                SEEN[ip] = 1
                SUM[ip] += total
            }
            if (portok && firstsrc != "") print firstsrc > CAND
        }
        END { for (ip in SUM) if (SUM[ip] > 0) printf "%s %d\n", ip, SUM[ip] > MAP }
    ' "$raw" 2>/dev/null

    [[ -s "$map" ]] && TRAF_CT_OK=1
    return 0
}

# ── Volcado ÚNICO de iptables → "CADENA bytes" ──
# Formato real de `iptables-save -c`:  [pkts:bytes] -A CADENA -j DESTINO
trafico_ipt_dump() {
    _traf_paths
    local map="$TRAF_IPT_MAP"
    [[ -z "$map" ]] && return 1
    : > "$map" 2>/dev/null

    local raw="" src_file=""
    src_file="${MAXINET_TRAF_IPT_FILE:-${ABBIENET_TRAF_IPT_FILE:-}}"
    if [[ -n "$src_file" ]]; then
        [[ -r "$src_file" ]] && raw="$src_file"
    elif command -v iptables-save >/dev/null 2>&1; then
        raw="${map}.raw"
        timeout "${TRAF_TO}s" iptables-save -c > "$raw" 2>/dev/null
        [[ -s "$raw" ]] || { : > "$raw"; return 1; }
    fi
    [[ -z "$raw" || ! -r "$raw" ]] && return 1

    awk '
        /^\[[0-9]+:[0-9]+\]/ {
            b = 0; chain = ""
            if (match($0, /^\[[0-9]+:[0-9]+\]/)) {
                cnt = substr($0, RSTART + 1, RLENGTH - 2)
                split(cnt, cc, ":")
                b = cc[2] + 0
            }
            for (i = 1; i <= NF; i++) if ($i == "-A") { chain = $(i + 1); break }
            if (chain != "" && b > 0) TOT[chain] += b
        }
        END { for (c in TOT) printf "%s %d\n", c, TOT[c] }
    ' "$raw" > "$map" 2>/dev/null
    return 0
}

trafico_precachear() {
    _traf_paths
    [[ -f "$TRAF_MARK" ]] && return 0

    : > "$TRAF_CT_MAP" 2>/dev/null
    : > "$TRAF_IPT_MAP" 2>/dev/null
    : > "$TRAF_CT_CAND" 2>/dev/null

    trafico_ct_dump >/dev/null 2>&1
    trafico_ipt_dump >/dev/null 2>&1

    : > "$TRAF_MARK" 2>/dev/null
    # Barrido de cachés huérfanas (>30 min), sin tocar la del proceso actual.
    find /tmp -maxdepth 1 -name 'maxinet_traf.*' ! -name "maxinet_traf.$$.*" -mmin +30 -delete 2>/dev/null
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Inicialización de directorios y saneo de BD
# ══════════════════════════════════════════════════════════════════
trafico_init() {
    mkdir -p "$DIR_TRAFICO" "$DIR_HISTORIAL" "$DIR_SNAPSHOTS" 2>/dev/null
    touch "$DB_CONSUMO" "$DB_LIMITES" "$DB_BLOQUEADOS" "$DB_IP_MAP" "$DB_UDP_ULTIMA" 2>/dev/null
    chmod 644 "$DB_CONSUMO" "$DB_LIMITES" "$DB_BLOQUEADOS" "$DB_IP_MAP" "$DB_UDP_ULTIMA" 2>/dev/null

    # Sanear limites_gb.db: solo "usuario:GB" con GB numérico > 0.
    # 'Ilimitado', '0', '0 GB', 'none', '∞' y basura desaparecen ⇒ ilimitado.
    if [[ -s "$DB_LIMITES" ]]; then
        local tmp="${DB_LIMITES}.tmp.$$"
        awk -F: 'NF >= 2 && $1 != "" && $2 ~ /^[0-9]+$/ && ($2 + 0) > 0 { print $1 ":" ($2 + 0) }' \
            "$DB_LIMITES" > "$tmp" 2>/dev/null && mv -f "$tmp" "$DB_LIMITES" 2>/dev/null
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# ── Interfaz principal ─────────────────────────────
trafico_iface() {
    if [[ -n "${NET_IFACE:-}" ]]; then
        printf '%s\n' "$NET_IFACE"
        return 0
    fi
    local iface
    iface=$(timeout "${TRAF_TO}s" ip route get 8.8.8.8 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    if [[ -z "$iface" ]]; then
        iface=$(ls /sys/class/net 2>/dev/null | grep -E '^(eth|ens|enp|eno)' | head -n1)
    fi
    printf '%s\n' "${iface:-eth0}"
}

# ══════════════════════════════════════════════════════════════════
# Cadenas iptables de accounting por usuario (IN y OUT)
# ══════════════════════════════════════════════════════════════════
trafico_init_usuario() {
    local user="${1:-}"
    [[ -z "$user" ]] && return 1

    # Evitar repetir ~10 invocaciones de iptables por usuario en cada render
    if [[ "${TRAF_INIT_USERS:- }" == *" ${user} "* ]]; then
        return 0
    fi
    TRAF_INIT_USERS="${TRAF_INIT_USERS:- }${user} "

    local chain_in="ABN_${user}_IN"
    local chain_out="ABN_${user}_OUT"

    iptables -N "$chain_in" 2>/dev/null
    iptables -C "$chain_in" -j RETURN 2>/dev/null || iptables -A "$chain_in" -j RETURN 2>/dev/null

    iptables -N "$chain_out" 2>/dev/null
    iptables -C "$chain_out" -j RETURN 2>/dev/null || iptables -A "$chain_out" -j RETURN 2>/dev/null

    # Accounting por UID para procesos del sistema (sshd/dropbear/socks)
    if id "$user" >/dev/null 2>&1; then
        iptables -C OUTPUT -m owner --uid-owner "$user" -j "$chain_out" 2>/dev/null || \
            iptables -A OUTPUT -m owner --uid-owner "$user" -j "$chain_out" 2>/dev/null

        local uid_val
        uid_val=$(id -u "$user" 2>/dev/null)
        if [[ -n "$uid_val" && "$uid_val" -ge 1000 ]] 2>/dev/null; then
            iptables -t mangle -C OUTPUT -m owner --uid-owner "$user" -j CONNMARK --set-mark "$uid_val" 2>/dev/null || \
                iptables -t mangle -A OUTPUT -m owner --uid-owner "$user" -j CONNMARK --set-mark "$uid_val" 2>/dev/null
            iptables -t mangle -C PREROUTING -j CONNMARK --restore-mark 2>/dev/null || \
                iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark 2>/dev/null
            iptables -C INPUT -m connmark --mark "$uid_val" -j "$chain_in" 2>/dev/null || \
                iptables -A INPUT -m connmark --mark "$uid_val" -j "$chain_in" 2>/dev/null
        fi
    fi
    return 0
}

trafico_init_todos() {
    trafico_init
    [[ -f "$USUARIOS_DB" ]] || return 0
    local user
    while IFS=: read -r user _ _ _ _; do
        user=$(printf '%s' "$user" | tr -d ' \t\r\n')
        [[ -z "$user" || "$user" == "root" || "$user" == \#* ]] && continue
        trafico_init_usuario "$user"
    done < "$USUARIOS_DB"
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Parseo de journal: SOLO evidencia real (nunca se adivina)
# ══════════════════════════════════════════════════════════════════
# Emite "epoch|ssh|usuario|ip" desde "Accepted (password|publickey) for U from IP"
_traf_parsear_ssh_journal() {
    awk '
        {
            ts = $1 + 0
            if (ts <= 0) next
            for (i = 2; i < NF; i++) {
                if ($i != "Accepted") continue
                if ($(i + 1) != "password" && $(i + 1) != "publickey") continue
                user = ""; ip = ""
                for (j = i + 2; j <= NF; j++) {
                    if ($j == "for") user = $(j + 1)
                    if ($j == "from") ip = $(j + 1)
                }
                if (user != "" && user != "root" && ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                    printf "%.0f|ssh|%s|%s\n", ts, user, ip
                break
            }
        }'
}

# Emite "epoch|udp|usuario|ip" desde "[src:IP:puerto] [user:USUARIO] Client connected"
_traf_parsear_udp_journal() {
    awk '
        {
            ts = $1 + 0
            if (ts <= 0) next
            if (index($0, "Client connected") == 0) next
            if (match($0, /\[src:[^]]*\]/) == 0) next
            src = substr($0, RSTART + 5, RLENGTH - 6)
            p = index(src, ":")
            if (p == 0) next
            ip = substr(src, 1, p - 1)
            user = ""
            if (match($0, /\[user:[^]]*\]/))
                user = substr($0, RSTART + 6, RLENGTH - 7)
            if (user != "" && user != "root" && ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)
                printf "%.0f|udp|%s|%s\n", ts, user, ip
        }'
}

# Mapa IP→clave de ZiVPN desde la bitácora real de auth.sh:
#   fecha|ip:puerto|clave|tx|resultado   (solo resultado "ok")
# Emite "ip|zivpn_<clave>", una vez por IP (la más reciente).
_traf_zivpn_mapa() {
    local db="${ZIVPN_CONEX_DB:-/etc/zivpn/conexiones.db}"
    [[ -s "$db" ]] || return 0
    tail -n 500 "$db" 2>/dev/null | tac | awk -F'|' '
        $5 == "ok" && $2 != "" && $3 != "" {
            ip = $2; sub(/:.*/, "", ip)
            if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
            if (ip == "127.0.0.1" || ip == "0.0.0.0") next
            if (!(ip in seen)) { seen[ip] = 1; print ip "|zivpn_" $3 }
        }'
}

# Contraseñas ZiVPN vigentes (formato real de Maxinet: .auth.config)
_traf_zivpn_claves() {
    local -a out=()
    if [[ -s "$ZIVPN_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        mapfile -t out < <(jq -r '(.auth.config[]?, .passwords[]?, .config[]?)' "$ZIVPN_CONFIG" 2>/dev/null \
            | grep -v '^null$' | grep -v '^$' | sort -u)
    fi
    if [[ ${#out[@]} -eq 0 && -s "$ZIVPN_CADUCIDAD" ]]; then
        mapfile -t out < <(awk -F'[:|]' '$1 != "" { print $1 }' "$ZIVPN_CADUCIDAD" 2>/dev/null | sort -u)
    fi
    # Último recurso honesto: claves ya vistas en el historial de consumo
    if [[ ${#out[@]} -eq 0 ]]; then
        mapfile -t out < <( { cut -d: -f1 "$DIR_HISTORIAL/$(date +%F).db" 2>/dev/null
                             cut -d: -f1 "$DB_CONSUMO" 2>/dev/null; } \
                           | sed -n 's/^zivpn_//p' | grep -v '^$' | sort -u)
    fi
    [[ ${#out[@]} -gt 0 ]] && printf '%s\n' "${out[@]}"
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Caché persistente de la ÚLTIMA conexión UDP Custom por usuario
# ══════════════════════════════════════════════════════════════════
# Formato: usuario|epoch|ip  (máximo epoch por usuario, podado a 30 días)
trafico_cachear_udp_ultima() {
    trafico_init
    command -v journalctl >/dev/null 2>&1 || return 0

    local validos=""
    [[ -f "$USUARIOS_DB" ]] && validos=$(awk -F: '$1 != "" && $1 !~ /^#/ && $1 != "root" { print $1 }' "$USUARIOS_DB" 2>/dev/null | tr -d ' \t\r')
    [[ -n "$validos" ]] || return 0

    if [[ -n "${MAXINET_TRAF_JOURNAL_FILE:-}" && -r "${MAXINET_TRAF_JOURNAL_FILE}" ]]; then
        local nuevas
        nuevas=$(_traf_parsear_udp_journal < "$MAXINET_TRAF_JOURNAL_FILE")
    else
        local ventana="${MAXINET_TRAF_UDP_VENTANA:-6 hours ago}"
        [[ -s "$DB_UDP_ULTIMA" ]] || ventana="${MAXINET_TRAF_UDP_SEED_VENTANA:-7 days ago}"
        local nuevas
        nuevas=$(timeout "${TRAF_TO}s" journalctl -u abbienet-udp.service -u udp-custom.service -u maxinet-udp.service \
            --since "$ventana" -o short-unix --no-pager -q -n 2000 2>/dev/null | _traf_parsear_udp_journal)
    fi

    local dias="${MAXINET_TRAF_UDP_ULTIMA_DIAS:-30}"
    local corte=$(( $(date +%s) - dias * 86400 ))
    local tmp="${DB_UDP_ULTIMA}.tmp.$$"

    {
        [[ -s "$DB_UDP_ULTIMA" ]] && cat "$DB_UDP_ULTIMA"
        [[ -n "${nuevas:-}" ]] && printf '%s\n' "$nuevas" | awk -F'|' '$2 == "udp" { print $3 "|" $1 "|" $4 }'
    } | awk -F'|' -v corte="$corte" -v validos="$validos" '
        BEGIN {
            n = split(validos, a, "\n")
            for (i = 1; i <= n; i++) if (a[i] != "") ok[a[i]] = 1
        }
        $1 == "" || $1 == "root" { next }
        ($1 in ok) && $2 ~ /^[0-9]+$/ && ($2 + 0) >= corte {
            if (($2 + 0) > mejor[$1]) { mejor[$1] = $2 + 0; mip[$1] = $3 }
            else if (($2 + 0) == mejor[$1] && $3 != "") { mip[$1] = $3 }
        }
        END {
            for (u in mejor) {
                if (mip[u] != "") printf "%s|%.0f|%s\n", u, mejor[u], mip[u]
                else printf "%s|%.0f\n", u, mejor[u]
            }
        }
    ' > "$tmp" 2>/dev/null

    if [[ -s "$tmp" ]]; then
        sort -t'|' -k1,1 "$tmp" -o "$tmp" 2>/dev/null
        mv -f "$tmp" "$DB_UDP_ULTIMA" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Mapa IP ↔ usuario para SSH / UDP Custom (misma base que ZiVPN)
# ══════════════════════════════════════════════════════════════════
_traf_mapa_ssh_udp() {
    local ventana="${MAXINET_TRAF_MAPA_VENTANA:-6 hours ago}"
    local ssh_ports="22 109 110 143 442"

    if [[ -r /etc/ssh/sshd_config ]]; then
        local p
        while read -r p; do
            [[ "$p" =~ ^[0-9]+$ ]] && ssh_ports+=" $p"
        done < <(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2 }' /etc/ssh/sshd_config 2>/dev/null)
    fi

    local jssh="" judp="" jf="${MAXINET_TRAF_JOURNAL_FILE:-}"
    if [[ -n "$jf" && -r "$jf" ]]; then
        jssh=$(cat "$jf" 2>/dev/null)
        judp="$jssh"
    else
        if command -v journalctl >/dev/null 2>&1; then
            jssh=$(timeout "${TRAF_TO}s" journalctl -u ssh -u sshd -u dropbear \
                --since "$ventana" -o short-unix --no-pager -q -n 500 2>/dev/null)
            judp=$(timeout "${TRAF_TO}s" journalctl -u abbienet-udp.service -u udp-custom.service -u maxinet-udp.service \
                --since "$ventana" -o short-unix --no-pager -q -n 500 2>/dev/null)
        fi
    fi

    # 1) SSH: logins del journal
    [[ -n "$jssh" ]] && printf '%s\n' "$jssh" | _traf_parsear_ssh_journal

    # 2) SSH: sesiones vivas según utmp
    if command -v who >/dev/null 2>&1; then
        timeout "${TRAF_TO}s" who 2>/dev/null | awk '
            {
                user = $1; ip = ""
                for (i = 1; i <= NF; i++)
                    if ($i ~ /^\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\)$/) {
                        ip = $i; gsub(/[()]/, "", ip)
                    }
                if (user != "" && user != "root" && ip != "")
                    print systime() "|ssh|" user "|" ip
            }'
    fi

    # 3) SSH: sockets establecidos → PID → usuario (sesiones > ventana)
    if command -v ss >/dev/null 2>&1 && command -v ps >/dev/null 2>&1; then
        local linea lport rip pid puser
        while IFS= read -r linea; do
            [[ -z "$linea" ]] && continue
            lport=$(printf '%s\n' "$linea" | awk '{ print $4 }' | sed -nE 's/.*:([0-9]+)$/\1/p')
            rip=$(printf '%s\n' "$linea" | awk '{ print $5 }' | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):.*/\1/p')
            pid=$(printf '%s\n' "$linea" | sed -nE 's/.*pid=([0-9]+).*/\1/p' | head -1)
            [[ -z "$lport" || -z "$rip" || -z "$pid" ]] && continue
            case " $ssh_ports " in *" $lport "*) ;; *) continue ;; esac
            puser=$(timeout "${TRAF_TO}s" ps -o user= -p "$pid" 2>/dev/null | tr -d ' \t\r\n')
            [[ -z "$puser" || "$puser" == "root" ]] && continue
            printf '%s|ssh|%s|%s\n' "$(date +%s)" "$puser" "$rip"
        done < <(timeout "${TRAF_TO}s" ss -tnp state established 2>/dev/null)
    fi

    # 4) UDP Custom: el log trae [src:IP:puerto] y [user:USUARIO]
    [[ -n "$judp" ]] && printf '%s\n' "$judp" | _traf_parsear_udp_journal
    return 0
}

# Política CGNAT: por IP gana el login MÁS RECIENTE. Si otro usuario inició
# sesión desde la misma IP dentro de la ventana (300 s), la IP es ambigua y se
# emite "ip|" (sin usuario) para que NO se atribuya a nadie.
_traf_resolver_cgnat() {
    awk -F'|' -v ventana="${MAXINET_TRAF_CGNAT_VENTANA:-300}" '
        $1 ~ /^[0-9]+$/ && $3 != "" && $4 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
            ip = $4; u = $3; ts = $1 + 0
            k = ip SUBSEP u
            if (!(k in visto) || ts > visto[k]) visto[k] = ts
            ips[ip] = 1
        }
        END {
            for (ip in ips) {
                mejor_u = ""; mejor_ts = -1; otro_u = ""; otro_ts = -1
                for (k in visto) {
                    split(k, a, SUBSEP)
                    if (a[1] != ip) continue
                    if (visto[k] > mejor_ts) {
                        otro_u = mejor_u; otro_ts = mejor_ts
                        mejor_u = a[2]; mejor_ts = visto[k]
                    } else if (visto[k] > otro_ts) {
                        otro_u = a[2]; otro_ts = visto[k]
                    }
                }
                if (mejor_u == "") continue
                if (otro_u != "" && (mejor_ts - otro_ts) < ventana) print ip "|"
                else print ip "|" mejor_u
            }
        }'
}

# Retira la atribución de una IP (reglas del dueño anterior + ip_map.db)
_traf_desregistrar_ip() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && return 0
    local prev_user=""
    [[ -f "$DB_IP_MAP" ]] && prev_user=$(awk -F: -v ip="$ip" '$1 == ip { u = $2 } END { print u }' "$DB_IP_MAP" 2>/dev/null)
    if [[ -n "$prev_user" ]]; then
        while iptables -D INPUT -s "$ip" -j "ABN_${prev_user}_IN" 2>/dev/null; do :; done
        while iptables -D OUTPUT -d "$ip" -j "ABN_${prev_user}_OUT" 2>/dev/null; do :; done
    fi
    local ip_re="${ip//./\\.}"
    sed -i "/^${ip_re}:/d" "$DB_IP_MAP" 2>/dev/null
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Registrar IP → usuario (reglas iptables INPUT/OUTPUT)
# ══════════════════════════════════════════════════════════════════
trafico_registrar_ip() {
    local user="${1:-}" ip="${2:-}"
    [[ -z "$user" || -z "$ip" ]] && return 1
    [[ "$user" == "root" ]] && return 1
    [[ "$ip" == "127.0.0.1" || "$ip" == "0.0.0.0" ]] && return 1

    trafico_init_usuario "$user"

    # Si la IP cambió de dueño (CGNAT / IP dinámica), retirar las reglas del
    # dueño anterior: si no, las dos cadenas contarían el mismo tráfico.
    local prev_user=""
    [[ -f "$DB_IP_MAP" ]] && prev_user=$(awk -F: -v ip="$ip" '$1 == ip { u = $2 } END { print u }' "$DB_IP_MAP" 2>/dev/null)
    if [[ -n "$prev_user" && "$prev_user" != "$user" ]]; then
        while iptables -D INPUT -s "$ip" -j "ABN_${prev_user}_IN" 2>/dev/null; do :; done
        while iptables -D OUTPUT -d "$ip" -j "ABN_${prev_user}_OUT" 2>/dev/null; do :; done
    fi

    # Registrar en la base de IPs (una sola fila por IP)
    local ip_re="${ip//./\\.}"
    sed -i "/^${ip_re}:/d" "$DB_IP_MAP" 2>/dev/null
    printf '%s:%s:%s\n' "$ip" "$user" "$(date +%s)" >> "$DB_IP_MAP"

    local chain_in="ABN_${user}_IN"
    local chain_out="ABN_${user}_OUT"
    iptables -C INPUT -s "$ip" -j "$chain_in" 2>/dev/null || iptables -I INPUT 1 -s "$ip" -j "$chain_in" 2>/dev/null
    iptables -C OUTPUT -d "$ip" -j "$chain_out" 2>/dev/null || iptables -I OUTPUT 1 -d "$ip" -j "$chain_out" 2>/dev/null
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Sincronizar atribución IP → usuario (una sola vez por render)
# ══════════════════════════════════════════════════════════════════
TRAF_SYNC_DONE=0
trafico_sincronizar_ips() {
    trafico_init
    [[ "${TRAF_SYNC_DONE:-0}" == "1" ]] && return 0
    TRAF_SYNC_DONE=1

    timeout "${TRAF_TO}s" sysctl -qw net.netfilter.nf_conntrack_acct=1 2>/dev/null

    local server_ips=""
    server_ips=$(timeout "${TRAF_TO}s" hostname -I 2>/dev/null)

    # 1. Una sola lectura de conntrack (los mapas se comparten con el render)
    trafico_precachear
    local raw_ips=()
    if [[ -n "${TRAF_CT_CAND:-}" && -s "$TRAF_CT_CAND" ]]; then
        mapfile -t raw_ips < <(sort -u "$TRAF_CT_CAND" 2>/dev/null)
    fi

    # 2. Usuarios válidos (sin root ni comentarios)
    local valid_users=()
    [[ -f "$USUARIOS_DB" ]] && mapfile -t valid_users < <(awk -F: '$1 != "" && $1 !~ /^#/ && $1 != "root" { print $1 }' "$USUARIOS_DB" 2>/dev/null)

    # 3. Journal cacheado UNA vez (short-unix: mismo formato que los parsers)
    _traf_paths
    local journal="$TRAF_JOURNAL"
    if [[ -n "${MAXINET_TRAF_JOURNAL_FILE:-}" && -r "${MAXINET_TRAF_JOURNAL_FILE}" ]]; then
        cat "${MAXINET_TRAF_JOURNAL_FILE}" > "$journal" 2>/dev/null
    elif [[ ! -s "$journal" ]] && command -v journalctl >/dev/null 2>&1; then
        timeout "${TRAF_TO}s" journalctl -u ssh -u sshd -u dropbear \
            -u abbienet-udp -u udp-custom -u maxinet-udp \
            --since "${MAXINET_TRAF_MAPA_VENTANA:-6 hours ago}" \
            -o short-unix --no-pager -q -n 500 > "$journal" 2>/dev/null
    fi

    # 4. Índices en memoria: dueño previo + evidencia del journal.
    #    Cero forks por IP (antes: un grep por usuario y por IP en cada render).
    local -A PREV_OWNER=()
    local -A IP_OWNER=()
    if [[ -f "$DB_IP_MAP" ]]; then
        local pip pu
        while IFS=: read -r pip pu _; do
            [[ -n "$pip" && -n "$pu" ]] && PREV_OWNER["$pip"]="$pu"
        done < "$DB_IP_MAP"
    fi
    if [[ -s "$journal" ]]; then
        local j_ts j_tipo j_user j_ip
        while IFS='|' read -r j_ts j_tipo j_user j_ip; do
            [[ -z "$j_user" || -z "$j_ip" ]] && continue
            IP_OWNER["$j_ip"]="$j_user"
        done < <(_traf_parsear_ssh_journal < "$journal")
        while IFS='|' read -r j_ts j_tipo j_user j_ip; do
            [[ -z "$j_user" || -z "$j_ip" ]] && continue
            [[ -z "${IP_OWNER[$j_ip]:-}" ]] && IP_OWNER["$j_ip"]="$j_user"
        done < <(_traf_parsear_udp_journal < "$journal")
    fi

    # 5. Mapeo explícito: la IP se registra solo con evidencia demostrable.
    local ip is_loc s matched_user cand
    for ip in "${raw_ips[@]}"; do
        ip=$(printf '%s' "$ip" | tr -d ' \t\r\n')
        [[ -z "$ip" || "$ip" == "127.0.0.1" || "$ip" == "0.0.0.0" ]] && continue
        is_loc=false
        for s in $server_ips; do
            [[ "$s" == "$ip" ]] && { is_loc=true; break; }
        done
        [[ "$is_loc" == "true" ]] && continue

        matched_user=""

        # A. Dueño previo válido en ip_map.db
        matched_user="${PREV_OWNER[$ip]:-}"
        [[ "$matched_user" == "root" ]] && matched_user=""

        # B. IP ligada a una cuenta válida en el journal (una pasada, no N×M)
        if [[ -z "$matched_user" ]]; then
            cand="${IP_OWNER[$ip]:-}"
            if [[ -n "$cand" && " ${valid_users[*]} " == *" ${cand} "* ]]; then
                matched_user="$cand"
            fi
        fi

        # C. Sin más fallbacks: sin evidencia la IP queda sin atribuir (N/D)
        if [[ -n "$matched_user" && "$matched_user" != "root" ]]; then
            trafico_registrar_ip "$matched_user" "$ip"
        fi
    done

    # 6. Registrar IPs de SSH / UDP Custom con su usuario real
    local mapa_ssh_udp=""
    mapa_ssh_udp=$(_traf_mapa_ssh_udp 2>/dev/null)
    if [[ -n "$mapa_ssh_udp" && ${#valid_users[@]} -gt 0 ]]; then
        local ip_res user_res
        while IFS='|' read -r ip_res user_res; do
            [[ -z "$ip_res" ]] && continue
            if [[ -z "$user_res" ]]; then
                # CGNAT: dos usuarios desde la misma IP dentro de la ventana
                _traf_desregistrar_ip "$ip_res"
                continue
            fi
            [[ " ${valid_users[*]} " == *" ${user_res} "* ]] || continue
            trafico_registrar_ip "$user_res" "$ip_res"
        done < <(printf '%s\n' "$mapa_ssh_udp" | _traf_resolver_cgnat)
    fi

    # 7. Registrar IPs de ZiVPN con su contraseña como identificador
    local zmapa=""
    zmapa=$(_traf_zivpn_mapa 2>/dev/null)
    if [[ -n "$zmapa" ]]; then
        local z_ip z_user
        while IFS='|' read -r z_ip z_user; do
            [[ -z "$z_ip" || -z "$z_user" ]] && continue
            trafico_registrar_ip "$z_user" "$z_ip"
        done <<< "$zmapa"
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Lectura en tiempo real de bytes (kernel + acumulado)
# ══════════════════════════════════════════════════════════════════
trafico_leer_iptables() {
    local user="${1:-}"
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && { printf '0\n'; return 0; }

    # Sin forks de iptables ni greps sobre /proc: todo sale de los mapas cacheados.
    trafico_precachear

    local b_in=0 b_out=0
    if [[ -n "${TRAF_IPT_MAP:-}" && -s "$TRAF_IPT_MAP" ]]; then
        local par
        par=$(awk -v cin="ABN_${user}_IN" -v cout="ABN_${user}_OUT" '
            $1 == cin  { i = $2 }
            $1 == cout { o = $2 }
            END { printf "%d %d", i + 0, o + 0 }
        ' "$TRAF_IPT_MAP" 2>/dev/null)
        b_in=${par%% *}
        b_out=${par##* }
    fi

    # Fuente de verdad para ACUMULAR: iptables. Sus contadores se resetean en
    # cada snapshot, así que sumarlos minuto a minuto es correcto. conntrack NO
    # se puede resetear: sumarlo aquí recontaría el mismo flujo en cada snapshot.
    printf '%d\n' $(( ${b_in:-0} + ${b_out:-0} ))
}

trafico_obtener_consumo() {
    local user="${1:-}"
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && { printf '0\n'; return 0; }
    local stored=0 live=0
    stored=$(awk -F: -v u="$user" '$1 == u { v = $2 } END { print v }' "$DB_CONSUMO" 2>/dev/null)
    [[ "$stored" =~ ^[0-9]+$ ]] || stored=0
    live=$(trafico_leer_iptables "$user")
    [[ "$live" =~ ^[0-9]+$ ]] || live=0
    printf '%d\n' $(( stored + live ))
}

trafico_obtener_consumo_hoy() {
    local user="${1:-}"
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && { printf '0\n'; return 0; }
    local hist="$DIR_HISTORIAL/$(date +%F).db"
    local stored=0 live=0
    [[ -f "$hist" ]] && stored=$(awk -F: -v u="$user" '$1 == u { v = $2 } END { print v }' "$hist" 2>/dev/null)
    [[ "$stored" =~ ^[0-9]+$ ]] || stored=0
    live=$(trafico_leer_iptables "$user")
    [[ "$live" =~ ^[0-9]+$ ]] || live=0
    printf '%d\n' $(( stored + live ))
}

trafico_obtener_limite() {
    local user="${1:-}"
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && { printf '0\n'; return 0; }
    local raw=""
    raw=$(awk -F: -v u="$user" '$1 == u { v = $2 } END { print v }' "$DB_LIMITES" 2>/dev/null | tr -d ' \t\r\n')
    if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw > 0 )); then
        printf '%d\n' "$raw"
    else
        printf '0\n'
    fi
}

# ── Límite GB (0 = ilimitado ⇒ se elimina la fila) ──
trafico_set_limite() {
    local user="${1:-}" gb="${2:-0}"
    trafico_init
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && return 1
    gb=$(printf '%s' "$gb" | tr -d ' \t\r\n')
    [[ "$gb" =~ ^[0-9]+$ ]] || gb=0

    local tmp="${DB_LIMITES}.tmp.$$"
    awk -F: -v u="$user" '$1 != u { print }' "$DB_LIMITES" 2>/dev/null > "$tmp"
    (( gb > 0 )) && printf '%s:%s\n' "$user" "$gb" >> "$tmp"
    mv -f "$tmp" "$DB_LIMITES" 2>/dev/null

    # Si es ilimitado o el consumo queda por debajo, desbloquear de inmediato
    local consumo limite_bytes
    consumo=$(trafico_obtener_consumo "$user")
    limite_bytes=$(( gb * 1073741824 ))
    if (( gb <= 0 )) || (( consumo < limite_bytes )); then
        trafico_desbloquear_usuario "$user"
    fi
    return 0
}

trafico_reset_usuario() {
    local user="${1:-}"
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && return 1
    trafico_init

    local tmp="${DB_CONSUMO}.tmp.$$"
    awk -F: -v u="$user" '$1 != u { print }' "$DB_CONSUMO" 2>/dev/null > "$tmp"
    printf '%s:0\n' "$user" >> "$tmp"
    mv -f "$tmp" "$DB_CONSUMO" 2>/dev/null

    local hist="$DIR_HISTORIAL/$(date +%F).db"
    if [[ -f "$hist" ]]; then
        local htmp="${hist}.tmp.$$"
        awk -F: -v u="$user" '$1 != u { print }' "$hist" 2>/dev/null > "$htmp"
        mv -f "$htmp" "$hist" 2>/dev/null
    fi

    trafico_init_usuario "$user"
    iptables -Z "ABN_${user}_IN" 2>/dev/null
    iptables -Z "ABN_${user}_OUT" 2>/dev/null
    trafico_invalidar_live

    trafico_desbloquear_usuario "$user"
    return 0
}

# ── Purgar TODO el estado de un usuario (DBs antes que cadenas) ──
trafico_eliminar_usuario() {
    local user="${1:-}"
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && return 1

    # 1) Retirar reglas que APUNTAN a las cadenas (si no, -X falla en silencio)
    local ip=""
    if [[ -f "$DB_IP_MAP" ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            while iptables -D INPUT -s "$ip" -j "ABN_${user}_IN" 2>/dev/null; do :; done
            while iptables -D OUTPUT -d "$ip" -j "ABN_${user}_OUT" 2>/dev/null; do :; done
        done < <(awk -F: -v u="$user" '$2 == u { print $1 }' "$DB_IP_MAP" 2>/dev/null)
    fi
    while iptables -D OUTPUT -m owner --uid-owner "$user" -j "ABN_${user}_OUT" 2>/dev/null; do :; done
    local uid=""
    uid=$(id -u "$user" 2>/dev/null)
    if [[ -n "$uid" ]]; then
        while iptables -D INPUT -m connmark --mark "$uid" -j "ABN_${user}_IN" 2>/dev/null; do :; done
    fi

    # 2) Purgar las 4 DBs de tráfico
    local db tmp
    for db in "$DB_CONSUMO" "$DB_LIMITES" "$DB_BLOQUEADOS"; do
        [[ -f "$db" ]] || continue
        tmp="${db}.tmp.$$"
        awk -F: -v u="$user" '$1 != u { print }' "$db" 2>/dev/null > "$tmp"
        mv -f "$tmp" "$db" 2>/dev/null
    done
    if [[ -f "$DB_IP_MAP" ]]; then
        tmp="${DB_IP_MAP}.tmp.$$"
        awk -F: -v u="$user" '$2 != u { print }' "$DB_IP_MAP" 2>/dev/null > "$tmp"
        mv -f "$tmp" "$DB_IP_MAP" 2>/dev/null
    fi

    # 3) Flush + delete de cadenas
    iptables -F "ABN_${user}_IN" 2>/dev/null
    iptables -F "ABN_${user}_OUT" 2>/dev/null
    iptables -X "ABN_${user}_IN" 2>/dev/null
    iptables -X "ABN_${user}_OUT" 2>/dev/null

    trafico_desbloquear_usuario "$user"
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Bloqueo / desbloqueo estricto (consumo excedido)
# ══════════════════════════════════════════════════════════════════
trafico_bloquear_usuario() {
    local user="${1:-}"
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && return 1

    # PROTECCIÓN ABSOLUTA: sin límite numérico > 0 NUNCA se bloquea
    local lim_gb=0
    lim_gb=$(trafico_obtener_limite "$user")
    if (( lim_gb <= 0 )); then
        grep -q "^${user}:" "$DB_BLOQUEADOS" 2>/dev/null && sed -i "/^${user}:/d" "$DB_BLOQUEADOS" 2>/dev/null
        return 0
    fi

    local consumo=0 limite_bytes=0
    consumo=$(trafico_obtener_consumo "$user")
    limite_bytes=$(( lim_gb * 1073741824 ))
    if (( limite_bytes <= 0 || consumo < limite_bytes )); then
        sed -i "/^${user}:/d" "$DB_BLOQUEADOS" 2>/dev/null
        return 0
    fi

    # 1. Bloquear cuenta a nivel de sistema (solo usuarios reales)
    if id "$user" >/dev/null 2>&1; then
        usermod -L "$user" 2>/dev/null
        chage -E 0 "$user" 2>/dev/null
        pkill -9 -u "$user" 2>/dev/null
        pkill -9 -f "sshd:.*${user}" 2>/dev/null
        pkill -9 -f "dropbear.*${user}" 2>/dev/null
    fi

    # 2. DROP de todas las IPs registradas de este usuario
    if [[ -f "$DB_IP_MAP" ]]; then
        local ip=""
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            iptables -C INPUT -s "$ip" -j DROP 2>/dev/null || iptables -I INPUT 1 -s "$ip" -j DROP 2>/dev/null
        done < <(awk -F: -v u="$user" '$2 == u { print $1 }' "$DB_IP_MAP" 2>/dev/null)
    fi

    # 3. Registrar en bloqueados.db (una fila)
    sed -i "/^${user}:/d" "$DB_BLOQUEADOS" 2>/dev/null
    printf '%s:%s\n' "$user" "$(date +%s)" >> "$DB_BLOQUEADOS"

    logger "Maxinet: usuario ${user} BLOQUEADO por consumo excedido ($(trafico_formatear "$consumo") / ${lim_gb} GB)" 2>/dev/null || true
    return 0
}

trafico_desbloquear_usuario() {
    local user="${1:-}"
    user=$(printf '%s' "$user" | tr -d ' \t\r\n')
    [[ -z "$user" ]] && return 1

    # 1. Restaurar cuenta (solo usuarios reales)
    if id "$user" >/dev/null 2>&1; then
        usermod -U "$user" 2>/dev/null
        local exp=""
        exp=$(awk -F: -v u="$user" '$1 == u { v = $3 } END { print v }' "$USUARIOS_DB" 2>/dev/null | tr -d ' \t\r\n')
        if [[ -n "$exp" ]]; then
            chage -E "$exp" "$user" 2>/dev/null
        else
            chage -E -1 "$user" 2>/dev/null
        fi
    fi

    # 2. Quitar TODAS las reglas DROP de sus IPs
    if [[ -f "$DB_IP_MAP" ]]; then
        local ip=""
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            while iptables -D INPUT -s "$ip" -j DROP 2>/dev/null; do :; done
        done < <(awk -F: -v u="$user" '$2 == u { print $1 }' "$DB_IP_MAP" 2>/dev/null)
    fi

    # 3. Quitar de la lista de bloqueados
    sed -i "/^${user}:/d" "$DB_BLOQUEADOS" 2>/dev/null
    logger "Maxinet: usuario ${user} DESBLOQUEADO (ilimitado o consumo normal)" 2>/dev/null || true
    return 0
}

trafico_verificar_limites() {
    trafico_init
    trafico_sincronizar_ips 2>/dev/null

    # 1. Limpieza preventiva: desbloquear a quien ya no lo merece
    if [[ -s "$DB_BLOQUEADOS" ]]; then
        local -a usuarios_bloqueados=()
        mapfile -t usuarios_bloqueados < <(awk -F: '$1 != "" { print $1 }' "$DB_BLOQUEADOS" 2>/dev/null)
        local b_u b_lim b_cons b_bytes
        for b_u in "${usuarios_bloqueados[@]}"; do
            b_u=$(printf '%s' "$b_u" | tr -d ' \t\r\n')
            [[ -z "$b_u" ]] && continue
            b_lim=$(trafico_obtener_limite "$b_u")
            if (( b_lim <= 0 )); then
                trafico_desbloquear_usuario "$b_u"
                continue
            fi
            b_cons=$(trafico_obtener_consumo "$b_u")
            b_bytes=$(( b_lim * 1073741824 ))
            (( b_cons < b_bytes )) && trafico_desbloquear_usuario "$b_u"
        done
    fi

    [[ -s "$DB_LIMITES" ]] || return 0

    # 2. Verificar consumo contra límite SOLO para límites reales > 0
    local user limite_gb consumo limite_bytes
    while IFS=: read -r user limite_gb; do
        user=$(printf '%s' "$user" | tr -d ' \t\r\n')
        limite_gb=$(printf '%s' "$limite_gb" | tr -d ' \t\r\n')
        [[ -z "$user" ]] && continue

        # Sin límite numérico > 0 ⇒ ILIMITADO: nunca bloquear
        if [[ ! "$limite_gb" =~ ^[0-9]+$ ]] || (( limite_gb <= 0 )); then
            grep -q "^${user}:" "$DB_BLOQUEADOS" 2>/dev/null && trafico_desbloquear_usuario "$user"
            continue
        fi

        consumo=$(trafico_obtener_consumo "$user")
        limite_bytes=$(( limite_gb * 1073741824 ))
        if (( limite_bytes > 0 && consumo >= limite_bytes )); then
            trafico_bloquear_usuario "$user"
        else
            grep -q "^${user}:" "$DB_BLOQUEADOS" 2>/dev/null && trafico_desbloquear_usuario "$user"
        fi
    done < "$DB_LIMITES"
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Snapshot: consolidar consumo live en las DB (cron cada 1 min)
# ══════════════════════════════════════════════════════════════════
trafico_guardar_snapshot() {
    trafico_init
    trafico_limpiar_cache
    trafico_sincronizar_ips 2>/dev/null
    trafico_cachear_udp_ultima 2>/dev/null

    local HOY hist_file
    HOY=$(date +%F)
    hist_file="$DIR_HISTORIAL/${HOY}.db"
    touch "$hist_file" 2>/dev/null

    local user live prev_total prev_day new_total new_day
    local -a objs=()

    # 1. Usuarios SSH / UDP Custom
    if [[ -f "$USUARIOS_DB" ]]; then
        while IFS=: read -r user _ _ _ _; do
            user=$(printf '%s' "$user" | tr -d ' \t\r\n')
            [[ -z "$user" || "$user" == "root" || "$user" == \#* ]] && continue
            objs+=("$user")
        done < "$USUARIOS_DB"
    fi

    # 2. Contraseñas ZiVPN (pseudo-usuarios zivpn_<clave>)
    local clave
    while IFS= read -r clave; do
        [[ -n "$clave" ]] && objs+=("zivpn_${clave}")
    done < <(_traf_zivpn_claves 2>/dev/null)

    local obj
    for obj in "${objs[@]}"; do
        [[ -z "$obj" ]] && continue
        trafico_init_usuario "$obj"

        live=$(trafico_leer_iptables "$obj")
        [[ "$live" =~ ^[0-9]+$ ]] || live=0
        (( live <= 0 )) && continue

        prev_total=$(awk -F: -v u="$obj" '$1 == u { v = $2 } END { print v }' "$DB_CONSUMO" 2>/dev/null)
        [[ "$prev_total" =~ ^[0-9]+$ ]] || prev_total=0
        new_total=$(( prev_total + live ))
        sed -i "/^${obj}:/d" "$DB_CONSUMO" 2>/dev/null
        printf '%s:%s\n' "$obj" "$new_total" >> "$DB_CONSUMO"

        prev_day=$(awk -F: -v u="$obj" '$1 == u { v = $2 } END { print v }' "$hist_file" 2>/dev/null)
        [[ "$prev_day" =~ ^[0-9]+$ ]] || prev_day=0
        new_day=$(( prev_day + live ))
        sed -i "/^${obj}:/d" "$hist_file" 2>/dev/null
        printf '%s:%s\n' "$obj" "$new_day" >> "$hist_file"

        # Resetear contadores para no duplicar en el siguiente snapshot
        iptables -Z "ABN_${obj}_IN" 2>/dev/null
        iptables -Z "ABN_${obj}_OUT" 2>/dev/null
    done

    # 3. Métrica global de la interfaz
    local IFACE RX TX
    IFACE=$(trafico_iface)
    RX=$(cat "/sys/class/net/${IFACE}/statistics/rx_bytes" 2>/dev/null || echo 0)
    TX=$(cat "/sys/class/net/${IFACE}/statistics/tx_bytes" 2>/dev/null || echo 0)
    printf '%s:%s:%s\n' "$(date +%H:%M)" "$RX" "$TX" >> "$DIR_SNAPSHOTS/${HOY}.snap"

    # Contadores recién puestos a cero: invalidar caché para el siguiente cálculo
    trafico_invalidar_live
    return 0
}

# ══════════════════════════════════════════════════════════════════
# Métricas de tráfico del servidor (gráficas)
# ══════════════════════════════════════════════════════════════════
trafico_servidor_dia() {
    local fecha="${1:-}"
    [[ -n "$fecha" ]] || { printf '0\n'; return 0; }
    local snap="$DIR_SNAPSHOTS/${fecha}.snap"
    [[ -s "$snap" ]] || { printf '0\n'; return 0; }

    local first last
    first=$(head -1 "$snap" 2>/dev/null)
    last=$(tail -1 "$snap" 2>/dev/null)
    local r1 t1 r2 t2
    # Formato del snapshot: HH:MM:RX:TX  (ver trafico_guardar_snapshot)
    r1=$(printf '%s' "$first" | cut -d: -f3)
    t1=$(printf '%s' "$first" | cut -d: -f4)
    r2=$(printf '%s' "$last" | cut -d: -f3)
    t2=$(printf '%s' "$last" | cut -d: -f4)

    if [[ ! "$r1" =~ ^[0-9]+$ || ! "$t1" =~ ^[0-9]+$ || ! "$r2" =~ ^[0-9]+$ || ! "$t2" =~ ^[0-9]+$ ]]; then
        printf '0\n'
        return 0
    fi

    local drx=$(( r2 - r1 )) dtx=$(( t2 - t1 ))
    (( drx < 0 )) && drx=0
    (( dtx < 0 )) && dtx=0
    printf '%d\n' $(( drx + dtx ))
}

trafico_servidor_hoy() { trafico_servidor_dia "$(date +%F)"; }

# ══════════════════════════════════════════════════════════════════
# Instalar servicio de rastreo y auto-bloqueo (cron cada minuto)
# ══════════════════════════════════════════════════════════════════
trafico_instalar_servicio() {
    trafico_init
    trafico_init_todos

    local dir_cron="$BASE/scripts"
    local cron_script="$dir_cron/trafico_cron.sh"
    local traf_sh="$BASE/herramientas/trafico.sh"
    mkdir -p "$dir_cron" 2>/dev/null

    {
        printf '#!/bin/bash\n'
        printf '# Maxinet Network — consolidación de tráfico (cron cada 1 min)\n'
        printf 'exec /bin/bash %q --snapshot\n' "$traf_sh"
    } > "$cron_script" 2>/dev/null
    chmod +x "$cron_script" 2>/dev/null

    command -v crontab >/dev/null 2>&1 || return 1
    local line="* * * * * /bin/bash ${cron_script} >/dev/null 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'trafico_cron' ; printf '%s\n' "$line" ) | crontab - 2>/dev/null || return 1
    return 0
}

# =========================================================
# UI — PANTALLAS ESTILO MAXINET (70 columnas)
# =========================================================
W=70

# Ancho visible real (ignora ANSI, cuenta emoji como 2 celdas)
_vlen() {
    local s n
    s=$(printf '%s' "$1" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g')
    n=$(printf '%s' "$s" | wc -L 2>/dev/null | tr -d ' ')
    [[ "$n" =~ ^[0-9]+$ ]] || n=${#s}
    printf '%s' "$n"
}

H1() { printf '%s╔' "$CYAN"; local i; for ((i = 0; i < W; i++)); do printf '═'; done; printf '╗%s\n' "$RESET"; }
H2() { printf '%s╠' "$CYAN"; local i; for ((i = 0; i < W; i++)); do printf '═'; done; printf '╣%s\n' "$RESET"; }
H3() { printf '%s╚' "$CYAN"; local i; for ((i = 0; i < W; i++)); do printf '═'; done; printf '╝%s\n' "$RESET"; }

row() {
    local content="${1:-}" n pad
    n=$(_vlen "$content")
    pad=$(( W - n ))
    (( pad < 0 )) && pad=0
    printf '%s║%s%*s%s║%s\n' "$CYAN" "$content" "$pad" "" "$CYAN" "$RESET"
}

title() {
    local t="${1:-}" n pad left right
    n=$(_vlen "$t")
    pad=$(( W - n ))
    (( pad < 0 )) && pad=0
    left=$(( pad / 2 ))
    right=$(( pad - left ))
    printf '%s║%*s%s%s%s%*s%s║%s\n' "$CYAN" "$left" "" "$GOLD" "$t" "$RESET" "$right" "" "$CYAN" "$RESET"
}

# ── [1] Resumen de Consumo Hoy ──────────────────────
trafico_render_resumen_hoy() {
    clear
    # Render nuevo: descartar caché y leer kernel + journal UNA sola vez
    trafico_limpiar_cache
    trafico_sincronizar_ips 2>/dev/null
    trafico_verificar_limites 2>/dev/null

    local hoy total_hoy mostrados=0 atribuido=0 ct_ok=0
    hoy=$(date +%F)
    total_hoy=$(trafico_servidor_dia "$hoy")
    [[ -n "${TRAF_CT_MAP:-}" && -s "${TRAF_CT_MAP:-}" ]] && ct_ok=1

    H1
    title "📊 RESUMEN DE CONSUMO — $(date '+%d %b %Y')"
    H2
    row "$(printf '   %sTráfico Total Servidor Hoy:%s %s%s%s' "$WHITE" "$RESET" "$GREEN" "$(trafico_formatear "$total_hoy")" "$RESET")"
    H2
    row "$(printf '   %s▸ SSH / UDP Custom%s' "$WHITE" "$RESET")"
    H2
    row "$(printf '   %s%-16s %10s %10s %7s %s%s' "$GRAY" "USUARIO" "HOY" "ACUMULADO" "LÍMITE" "ESTADO" "$RESET")"

    local user _ _ _ _ consumo_total consumo_hoy limite_gb lim_str color tag pct
    if [[ -s "$USUARIOS_DB" ]]; then
        while IFS=: read -r user _ _ _ _; do
            user=$(printf '%s' "$user" | tr -d ' \t\r\n')
            [[ -z "$user" || "$user" == "root" || "$user" == \#* ]] && continue

            mostrados=$(( mostrados + 1 ))
            consumo_total=$(trafico_obtener_consumo "$user")
            consumo_hoy=$(trafico_obtener_consumo_hoy "$user")
            atribuido=$(( atribuido + consumo_hoy ))
            limite_gb=$(trafico_obtener_limite "$user")

            lim_str="∞"
            (( limite_gb > 0 )) && lim_str="${limite_gb} GB"

            color="$GREEN"; tag=""
            if (( limite_gb > 0 )) && grep -q "^${user}:" "$DB_BLOQUEADOS" 2>/dev/null; then
                color="$RED"; tag=" ${RED}[BLOQUEADO]${RESET}"
            elif grep -q "^${user}:" "$DB_BLOQUEADOS" 2>/dev/null; then
                # Sin límite numérico real: desbloquear de inmediato (nunca bloqueado)
                trafico_desbloquear_usuario "$user" 2>/dev/null
            elif (( limite_gb > 0 )); then
                pct=$(( consumo_total * 100 / (limite_gb * 1073741824) ))
                (( pct >= 80 )) && color="$YELLOW"
                (( pct >= 100 )) && color="$RED"
            fi

            row "$(printf '   %s%-16s%s %10s %10s %7s%b' \
                "$color" "$user" "$RESET" \
                "$(trafico_formatear "$consumo_hoy")" \
                "$(trafico_formatear "$consumo_total")" \
                "$lim_str" "$tag")"
        done < "$USUARIOS_DB"
    fi

    if (( mostrados == 0 )); then
        row "$(printf '   %sSin usuarios registrados (crea uno en el menú [1]).%s' "$GRAY" "$RESET")"
    fi

    # ─── Contraseñas ZiVPN ───
    local clave zvpn_mostrados=0 zv_user
    local -a ZVPN_PASSES=()
    mapfile -t ZVPN_PASSES < <(_traf_zivpn_claves 2>/dev/null)

    if [[ ${#ZVPN_PASSES[@]} -gt 0 ]]; then
        H2
        row "$(printf '   %s▸ ZiVPN (por contraseña)%s' "$WHITE" "$RESET")"
        H2
        row "$(printf '   %s%-16s %10s %10s %7s %s%s' "$GRAY" "CONTRASEÑA" "HOY" "ACUMULADO" "LÍMITE" "ESTADO" "$RESET")"

        for clave in "${ZVPN_PASSES[@]}"; do
            clave=$(printf '%s' "$clave" | tr -d ' \t\r\n')
            [[ -z "$clave" ]] && continue
            zv_user="zivpn_${clave}"
            zvpn_mostrados=$(( zvpn_mostrados + 1 ))

            consumo_total=$(trafico_obtener_consumo "$zv_user")
            consumo_hoy=$(trafico_obtener_consumo_hoy "$zv_user")
            atribuido=$(( atribuido + consumo_hoy ))
            limite_gb=$(trafico_obtener_limite "$zv_user")
            lim_str="∞"
            (( limite_gb > 0 )) && lim_str="${limite_gb} GB"

            color="$GREEN"; tag=""
            if (( limite_gb > 0 )) && grep -q "^${zv_user}:" "$DB_BLOQUEADOS" 2>/dev/null; then
                color="$RED"; tag=" ${RED}[BLOQUEADO]${RESET}"
            elif grep -q "^${zv_user}:" "$DB_BLOQUEADOS" 2>/dev/null; then
                trafico_desbloquear_usuario "$zv_user" 2>/dev/null
            elif (( limite_gb > 0 )); then
                pct=$(( consumo_total * 100 / (limite_gb * 1073741824) ))
                (( pct >= 80 )) && color="$YELLOW"
                (( pct >= 100 )) && color="$RED"
            fi

            row "$(printf '   %s🔑 %-14s%s %10s %10s %7s%b' \
                "$color" "$clave" "$RESET" \
                "$(trafico_formatear "$consumo_hoy")" \
                "$(trafico_formatear "$consumo_total")" \
                "$lim_str" "$tag")"
        done
    fi

    H2
    # ── Notas honestas: nunca dejar la pantalla vacía ni inventar consumo ──
    if (( ct_ok != 1 )); then
        row "$(printf '   %sNota: conntrack no disponible (N/D). Solo se muestran%s' "$GRAY" "$RESET")"
        row "$(printf '   %slos contadores de iptables; el tráfico UDP podría faltar.%s' "$GRAY" "$RESET")"
    fi
    if (( atribuido == 0 )); then
        row "$(printf '   %sSin flujos atribuidos todavía (0 B). El cron consolida%s' "$GRAY" "$RESET")"
        row "$(printf '   %scada minuto: vuelve a abrir esta pantalla en unos instantes.%s' "$GRAY" "$RESET")"
    fi

    # IPs con flujos reales pero sin dueño demostrable: N/D honesto
    local sin_atribuir=0
    if [[ -s "${TRAF_CT_CAND:-}" && -s "$DB_IP_MAP" ]]; then
        sin_atribuir=$(awk -F: '
            NR == FNR { if ($1 != "") mapa[$1] = 1; next }
            $1 != "" && !($1 in mapa) { c++ }
            END { print c + 0 }
        ' "$DB_IP_MAP" "${TRAF_CT_CAND}" 2>/dev/null)
        if [[ -s "$DB_IP_MAP" ]]; then :; else sin_atribuir=0; fi
    fi
    if (( ${sin_atribuir:-0} > 0 )); then
        row "$(printf '   %s%d IP(s) con tráfico sin atribuir (N/D): no hay%s' "$GRAY" "$sin_atribuir" "$RESET")"
        row "$(printf '   %slogin reciente verificable; no se asigna a ninguna cuenta.%s' "$GRAY" "$RESET")"
    fi

    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
}

# ── [2] Gráfica Semanal ────────────────────────────
trafico_render_grafica_semanal() {
    clear

    local -a labels=() values=()
    local i d val max_val=1 total_sem=0
    for i in 6 5 4 3 2 1 0; do
        d=$(date -d "-${i} days" +%F 2>/dev/null)
        [[ -z "$d" ]] && continue
        labels+=("$(date -d "-${i} days" '+%a %d' 2>/dev/null)")
        val=$(trafico_servidor_dia "$d")
        values+=("$val")
        total_sem=$(( total_sem + val ))
        (( val > max_val )) && max_val=$val
    done

    H1
    title "📈 CONSUMO SEMANAL — ÚLTIMOS 7 DÍAS"
    H2

    local bar fmt mark last_idx=0
    (( ${#labels[@]} > 0 )) && last_idx=$(( ${#labels[@]} - 1 ))
    for i in "${!labels[@]}"; do
        bar=$(_draw_bar "${values[$i]}" "$max_val" 26)
        fmt=$(trafico_formatear "${values[$i]}")
        mark=""
        (( i == last_idx )) && mark=" ${GREEN}← HOY${RESET}"
        row "$(printf '   %s%-8s%s %s%s%s %s%9s%s%b' \
            "$GRAY" "${labels[$i]}" "$RESET" \
            "$GREEN" "$bar" "$RESET" \
            "$YELLOW" "$fmt" "$RESET" "$mark")"
    done

    H2
    row "$(printf '   %sTotal Semana:%s %s%s%s' "$WHITE" "$RESET" "$GREEN" "$(trafico_formatear "$total_sem")" "$RESET")"
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
}

# ── [3] Gráfica Mensual ────────────────────────────
trafico_render_grafica_mensual() {
    clear

    local -a labels=() values=()
    local i d val max_val=1 total_mes=0
    for i in $(seq 29 -1 0); do
        d=$(date -d "-${i} days" +%F 2>/dev/null)
        [[ -z "$d" ]] && continue
        labels+=("$(date -d "-${i} days" '+%d' 2>/dev/null)")
        val=$(trafico_servidor_dia "$d")
        values+=("$val")
        total_mes=$(( total_mes + val ))
        (( val > max_val )) && max_val=$val
    done

    H1
    title "📆 CONSUMO MENSUAL — ÚLTIMOS 30 DÍAS"
    H2

    local bar fmt mark last_idx=0
    (( ${#labels[@]} > 0 )) && last_idx=$(( ${#labels[@]} - 1 ))
    for i in "${!labels[@]}"; do
        bar=$(_draw_bar "${values[$i]}" "$max_val" 24)
        fmt=$(trafico_formatear "${values[$i]}")
        mark=""
        (( i == last_idx )) && mark=" ${GREEN}←${RESET}"
        row "$(printf '   %s%-3s%s %s%s%s %s%9s%s%b' \
            "$GRAY" "${labels[$i]}" "$RESET" \
            "$GREEN" "$bar" "$RESET" \
            "$YELLOW" "$fmt" "$RESET" "$mark")"
    done

    H2
    row "$(printf '   %sTotal Mes:%s %s%s%s' "$WHITE" "$RESET" "$GREEN" "$(trafico_formatear "$total_mes")" "$RESET")"
    H3
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
}

# ── Utilidad de fechas (GNU coreutils + respaldo busybox) ──
_traf_fecha_hace() {
    local dias="${1:-0}" fmt="${2:-%F}" ep=""
    ep=$(date +%s 2>/dev/null) || { printf ''; return 0; }
    [[ "$ep" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
    ep=$(( ep - dias * 86400 ))
    date -d "@${ep}" "$fmt" 2>/dev/null && return 0
    date -d "-${dias} days" "$fmt" 2>/dev/null
    return 0
}

# ── Usuarios disponibles para las pantallas con selector ──
_traf_usuarios_disponibles() {
    local -a lista=()
    [[ -f "$USUARIOS_DB" ]] && mapfile -t lista < <(
        awk -F: '$1 != "" && $1 !~ /^#/ && $1 != "root" { print $1 }' "$USUARIOS_DB" 2>/dev/null
    )
    local clave
    while IFS= read -r clave; do
        clave=$(printf '%s' "$clave" | tr -d ' \t\r\n')
        [[ -n "$clave" ]] && lista+=("zivpn_${clave}")
    done < <(_traf_zivpn_claves 2>/dev/null)
    [[ ${#lista[@]} -gt 0 ]] && printf '%s\n' "${lista[@]}"
    return 0
}

# Devuelve el usuario elegido en stdout; la lista se pinta en stderr
_traf_pick_usuario() {
    local -a lista=()
    mapfile -t lista < <(_traf_usuarios_disponibles)
    if [[ ${#lista[@]} -eq 0 ]]; then
        printf '' 
        return 1
    fi
    local i sel
    for i in "${!lista[@]}"; do
        printf '     %s%2d)%s %s\n' "$GRAY" $(( i + 1 )) "$RESET" "${lista[$i]}" >&2
    done
    read -rp "$(trx '   Usuario (número o nombre): ')" sel
    sel=$(printf '%s' "$sel" | tr -d ' \t\r\n')
    [[ -z "$sel" ]] && { printf ''; return 1; }
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#lista[@]} )); then
        printf '%s' "${lista[$(( sel - 1 ))]}"
        return 0
    fi
    printf '%s' "$sel"
}

# ── [4] Consumo detallado por usuario ──────────────
trafico_render_detalle_usuario() {
    clear
    trafico_limpiar_cache
    trafico_sincronizar_ips 2>/dev/null

    H1
    title "👤 CONSUMO DETALLADO POR USUARIO"
    H2
    if [[ $( _traf_usuarios_disponibles 2>/dev/null | wc -l ) -eq 0 ]]; then
        row "   No hay usuarios SSH ni contraseñas ZiVPN registradas."
        H3
        echo ""
        read -rp "$(trx '   Presiona Enter para continuar... ')" _
        return 0
    fi
    row "   Elige una cuenta para ver su consumo real:"
    H2

    local user=""
    user=$(_traf_pick_usuario) || user=""
    if [[ -z "$user" ]]; then
        return 0
    fi

    local total=0 hoy=0 limite=0
    total=$(trafico_obtener_consumo "$user")
    hoy=$(trafico_obtener_consumo_hoy "$user")
    limite=$(trafico_obtener_limite "$user")

    clear
    H1
    title "👤 DETALLE — ${user}"
    H2
    row "$(printf '   %sUsuario     :%s %s%s%s' "$GRAY" "$RESET" "$WHITE" "$user" "$RESET")"
    row "$(printf '   %sConsumo hoy :%s %s%s%s' "$GRAY" "$RESET" "$GREEN" "$(trafico_formatear "$hoy")" "$RESET")"
    row "$(printf '   %sAcumulado   :%s %s%s%s' "$GRAY" "$RESET" "$GREEN" "$(trafico_formatear "$total")" "$RESET")"

    if (( limite > 0 )); then
        row "$(printf '   %sLímite      :%s %s%d GB%s' "$GRAY" "$RESET" "$YELLOW" "$limite" "$RESET")"
        row "$(printf '   %sCuota       :%s %s' "$GRAY" "$RESET" "$(bar_pct "$total" $(( limite * 1073741824 )) 30)")"
    else
        row "$(printf '   %sLímite      :%s %s∞ (ilimitado)%s' "$GRAY" "$RESET" "$GREEN" "$RESET")"
        row "$(printf '   %sCuota       :%s sin límite; nunca se bloquea' "$GRAY" "$RESET")"
    fi

    if grep -q "^${user}:" "$DB_BLOQUEADOS" 2>/dev/null; then
        row "$(printf '   %sEstado      :%s %sBLOQUEADO%s' "$GRAY" "$RESET" "$RED" "$RESET")"
    else
        row "$(printf '   %sEstado      :%s %sactivo%s' "$GRAY" "$RESET" "$GREEN" "$RESET")"
    fi

    H2
    row "$(printf '   %sIPs atribuidas:%s' "$GRAY" "$RESET")"
    local ips="" ip="" ipn=0
    if [[ -f "$DB_IP_MAP" ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            ipn=$(( ipn + 1 ))
            (( ipn > 6 )) && continue
            row "     · ${ip}"
        done < <(awk -F: -v u="$user" '$2 == u { print $1 }' "$DB_IP_MAP" 2>/dev/null)
    fi
    if (( ipn == 0 )); then
        row "     $(printf '%sN/D — sin login verificable todavía%s' "$GRAY" "$RESET")"
    elif (( ipn > 6 )); then
        row "     $(printf '%s… y %d más%s' "$GRAY" $(( ipn - 6 )) "$RESET")"
    fi

    H2
    row "$(printf '   %sHistorial (7 días):%s' "$GRAY" "$RESET")"
    local i d v maxv=1
    local -a dvals=() dlabels=()
    for i in 6 5 4 3 2 1 0; do
        d=$(_traf_fecha_hace "$i" +%F)
        [[ -z "$d" ]] && continue
        v=0
        if [[ -f "$DIR_HISTORIAL/${d}.db" ]]; then
            v=$(awk -F: -v u="$user" '$1 == u { print $2 }' "$DIR_HISTORIAL/${d}.db" 2>/dev/null)
        fi
        [[ "$v" =~ ^[0-9]+$ ]] || v=0
        dvals+=("$v")
        dlabels+=("$(_traf_fecha_hace "$i" '+%a %d')")
        (( v > maxv )) && maxv=$v
    done
    for i in "${!dlabels[@]}"; do
        row "$(printf '   %s%-7s%s %s%s%s %s%9s%s' \
            "$GRAY" "${dlabels[$i]}" "$RESET" \
            "$GREEN" "$(_draw_bar "${dvals[$i]}" "$maxv" 20)" "$RESET" \
            "$YELLOW" "$(trafico_formatear "${dvals[$i]}")" "$RESET")"
    done

    H2
    row "   [1] Resetear contador    [2] Cambiar límite    [0] Volver"
    H3
    echo ""
    local acc=""
    read -rp "$(trx '   Opción: ')" acc
    case "$acc" in
        1)
            trafico_reset_usuario "$user"
            printf '   %s✓ Contador reiniciado: %s%s\n' "$GREEN" "$user" "$RESET"
            ;;
        2)
            local nlim=""
            read -rp "$(trx '   Nuevo límite en GB (0 = ilimitado): ')" nlim
            trafico_set_limite "$user" "$nlim"
            printf '   %s✓ Límite actualizado: %s%s\n' "$GREEN" "$user" "$RESET"
            ;;
    esac
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
    return 0
}

# ── [5] Configurar límites de GB ───────────────────
trafico_render_limites() {
    clear
    trafico_limpiar_cache
    trafico_sincronizar_ips 2>/dev/null

    H1
    title "🔧 LÍMITES DE CONSUMO (GB)"
    H2
    row "$(printf '   %sLímite 0 / vacío = ILIMITADO (nunca se bloquea)%s' "$GRAY" "$RESET")"
    H2
    row "$(printf '   %s%-18s %10s %12s %s%s' "$GRAY" "USUARIO" "LÍMITE" "CONSUMIDO" "ESTADO" "$RESET")"

    local mostrados=0 user _ _ _ _ consumo_total limite_gb lim_str color tag
    if [[ -s "$USUARIOS_DB" ]]; then
        while IFS=: read -r user _ _ _ _; do
            user=$(printf '%s' "$user" | tr -d ' \t\r\n')
            [[ -z "$user" || "$user" == "root" || "$user" == \#* ]] && continue
            mostrados=$(( mostrados + 1 ))
            consumo_total=$(trafico_obtener_consumo "$user")
            limite_gb=$(trafico_obtener_limite "$user")
            lim_str="∞"
            (( limite_gb > 0 )) && lim_str="${limite_gb} GB"
            color="$GREEN"; tag="activo"
            if grep -q "^${user}:" "$DB_BLOQUEADOS" 2>/dev/null; then
                color="$RED"; tag="BLOQUEADO"
            fi
            row "$(printf '   %s%-18s%s %10s %12s %s%s%s' \
                "$color" "$user" "$RESET" \
                "$lim_str" "$(trafico_formatear "$consumo_total")" \
                "$color" "$tag" "$RESET")"
        done < "$USUARIOS_DB"
    fi

    local clave
    while IFS= read -r clave; do
        clave=$(printf '%s' "$clave" | tr -d ' \t\r\n')
        [[ -z "$clave" ]] && continue
        mostrados=$(( mostrados + 1 ))
        user="zivpn_${clave}"
        consumo_total=$(trafico_obtener_consumo "$user")
        limite_gb=$(trafico_obtener_limite "$user")
        lim_str="∞"
        (( limite_gb > 0 )) && lim_str="${limite_gb} GB"
        color="$GREEN"; tag="activo"
        if grep -q "^${user}:" "$DB_BLOQUEADOS" 2>/dev/null; then
            color="$RED"; tag="BLOQUEADO"
        fi
        row "$(printf '   %s%-18s%s %10s %12s %s%s%s' \
            "$color" "$clave" "$RESET" \
            "$lim_str" "$(trafico_formatear "$consumo_total")" \
            "$color" "$tag" "$RESET")"
    done < <(_traf_zivpn_claves 2>/dev/null)

    if (( mostrados == 0 )); then
        row "   Sin cuentas registradas todavía."
    fi

    H2
    row "   Escribe el usuario y el límite en GB (0 = quitar límite)."
    row "   Deja el usuario vacío para volver."
    H3
    echo ""

    local u="" g=""
    read -rp "$(trx '   Usuario: ')" u
    u=$(printf '%s' "$u" | tr -d ' \t\r\n')
    [[ -z "$u" ]] && return 0
    if [[ ! "$u" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        printf '   %sNombre inválido.%s\n' "$RED" "$RESET"
        read -rp "$(trx '   Presiona Enter para continuar... ')" _
        return 0
    fi
    if [[ "$u" != zivpn_* ]] && ! grep -q "^${u}:" "$USUARIOS_DB" 2>/dev/null; then
        printf '   %sEl usuario %s no existe en usuarios.db.%s\n' "$RED" "$u" "$RESET"
        read -rp "$(trx '   Presiona Enter para continuar... ')" _
        return 0
    fi

    read -rp "$(trx '   Límite en GB (0 = ilimitado): ')" g
    trafico_set_limite "$u" "$g"
    g=$(printf '%s' "$g" | tr -d ' \t\r\n')
    [[ "$g" =~ ^[0-9]+$ ]] || g=0
    if (( g > 0 )); then
        printf '   %s✓ %s limitado a %s GB%s\n' "$GREEN" "$u" "$g" "$RESET"
    else
        printf '   %s✓ %s sin límite (ilimitado)%s\n' "$GREEN" "$u" "$RESET"
    fi
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
    return 0
}

# ── [6] Activar / reinstalar rastreo ───────────────
trafico_render_rastreo() {
    clear
    H1
    title "⚙️  RASTREO Y AUTO-BLOQUEO"
    H2

    local cron_ok="NO" nchains=0 total_cons=0 nlim=0 nbloq=0
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'trafico_cron'; then
        cron_ok="SÍ"
    fi
    nchains=$(iptables -S 2>/dev/null | grep -c '^-N ABN_' || true)
    [[ "$nchains" =~ ^[0-9]+$ ]] || nchains=0
    total_cons=$(awk -F: '{ s += $2 + 0 } END { printf "%d", s + 0 }' "$DB_CONSUMO" 2>/dev/null)
    [[ "$total_cons" =~ ^[0-9]+$ ]] || total_cons=0
    nlim=$(awk -F: 'NF >= 2 && $2 ~ /^[0-9]+$/ && ($2 + 0) > 0 { c++ } END { print c + 0 }' "$DB_LIMITES" 2>/dev/null)
    [[ "$nlim" =~ ^[0-9]+$ ]] || nlim=0
    nbloq=$(wc -l < "$DB_BLOQUEADOS" 2>/dev/null | tr -d ' \t\r\n')
    [[ "$nbloq" =~ ^[0-9]+$ ]] || nbloq=0

    row "$(printf '   %sCron cada minuto :%s %s%s%s' "$GRAY" "$RESET" "$GREEN" "$cron_ok" "$RESET")"
    row "$(printf '   %sCadenas ABN_*    :%s %s%d%s' "$GRAY" "$RESET" "$WHITE" "$nchains" "$RESET")"
    row "$(printf '   %sConsumo total    :%s %s%s%s' "$GRAY" "$RESET" "$GREEN" "$(trafico_formatear "$total_cons")" "$RESET")"
    row "$(printf '   %sLímites activos  :%s %s%d%s' "$GRAY" "$RESET" "$WHITE" "$nlim" "$RESET")"
    row "$(printf '   %sBloqueados       :%s %s%d%s' "$GRAY" "$RESET" "$WHITE" "$nbloq" "$RESET")"
    H2
    row "   Activar crea las cadenas de cada cuenta e instala el cron"
    row "   que consolida el consumo cada minuto."
    H2
    row "   [1] Activar / reinstalar ahora"
    row "   [0] Volver"
    H3
    echo ""

    local op=""
    read -rp "$(trx '   Opción: ')" op
    [[ "$op" == "1" ]] || return 0

    echo ""
    printf '   %s▸ Creando cadenas por usuario...%s\n' "$GRAY" "$RESET"
    trafico_init_todos
    printf '   %s▸ Instalando cron de consolidación...%s\n' "$GRAY" "$RESET"
    if trafico_instalar_servicio; then
        printf '   %s✓ Rastreo activo: cron cada minuto instalado.%s\n' "$GREEN" "$RESET"
        printf '   %s  El consumo empezará a acumularse en ~1 minuto.%s\n' "$GRAY" "$RESET"
    else
        printf '   %s✗ No se pudo instalar el cron (¿crontab ausente?).%s\n' "$RED" "$RESET"
        printf '   %s  Instala cron con: apt install cron%s\n' "$GRAY" "$RESET"
    fi
    echo ""
    read -rp "$(trx '   Presiona Enter para continuar... ')" _
    return 0
}

# =========================================================
# MENÚ PRINCIPAL DEL MÓDULO
# =========================================================
menu_trafico() {
    local op=""
    while true; do
        clear
        H1
        title "📈 TRÁFICO & USO"
        H2
        row ""
        row "   [1] 📊 Resumen de Uso Hoy"
        row "   [2] 📈 Gráfica Semanal (7 días)"
        row "   [3] 📆 Gráfica Mensual (30 días)"
        row "   [4] 👤 Consumo Detallado por Usuario"
        row "   [5] 🔧 Configurar Límites de GB"
        row "   [6] ⚙️  Activar / Reinstalar Rastreo"
        row ""
        row "   [0] ↩  Volver"
        row ""
        H3
        echo ""
        read -rp "$(trx '   Opción: ')" op
        case "$op" in
            1) trafico_render_resumen_hoy ;;
            2) trafico_render_grafica_semanal ;;
            3) trafico_render_grafica_mensual ;;
            4) trafico_render_detalle_usuario ;;
            5) trafico_render_limites ;;
            6) trafico_render_rastreo ;;
            0|q|Q|'') return 0 ;;
            *) printf '   %sOpción inválida.%s\n' "$RED" "$RESET"; sleep 1 ;;
        esac
    done
}

# =========================================================
# CLI — solo cuando se ejecuta directamente (nunca al sourcear)
# =========================================================
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --menu)
            menu_trafico
            ;;
        --init)
            trafico_init
            trafico_init_todos
            ;;
        --snapshot)
            # Cron: consolidar y verificar límites sin escribir en pantalla
            trafico_guardar_snapshot >/dev/null 2>&1
            trafico_verificar_limites >/dev/null 2>&1
            ;;
        --install-cron)
            trafico_instalar_servicio
            ;;
        --resumen)
            trafico_render_resumen_hoy
            ;;
        --eliminar-usuario)
            shift
            trafico_eliminar_usuario "${1:-}"
            ;;
        --reset)
            shift
            trafico_reset_usuario "${1:-}"
            ;;
        --set-limite)
            shift
            trafico_set_limite "${1:-}" "${2:-0}"
            ;;
        --consumo)
            shift
            trafico_obtener_consumo "${1:-}"
            ;;
        --limite)
            shift
            trafico_obtener_limite "${1:-}"
            ;;
        "")
            menu_trafico
            ;;
        *)
            printf 'Uso: %s [--menu|--init|--snapshot|--install-cron|--resumen|--eliminar-usuario USUARIO|--reset USUARIO|--set-limite USUARIO GB|--consumo USUARIO|--limite USUARIO]\n' "$0"
            exit 1
            ;;
    esac
fi


