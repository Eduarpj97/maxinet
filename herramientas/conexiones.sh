#!/bin/bash
# =========================================================
# Maxinet Network v3.0 - Conexiones REALES (UDP Custom / ZiVPN)
# Módulo: herramientas/conexiones.sh
#
# Fuentes de verdad (NADA simulado):
#   - UDP Custom: journalctl -u udp-custom (logs del binario)
#   - ZiVPN     : journalctl -u zivpn.service + /etc/zivpn/conexiones.db
#                 (bitácora que escribe auth.sh en modo command)
#   - Liveness  : /proc/net/nf_conntrack o el binario conntrack (kernel);
#                 sin evidencia => N/D (nunca se inventa)
#
# Formatos reales verificados en VPS:
#   UDP: 2026/10/20 03:10:20 [INFO] [src:191.95.54.179:4814] [user:eduar] Client connected
#   UDP: 2026/10/20 03:14:43 [INFO] [error:timeout] [src:191.95.54.179:40104] Client disconnected
#   ZV : INFO client connected {"addr": "191.95.16.206:59765"}
#
# Solo bash + awk + coreutils (mawk-safe): igual en aarch64 y x86_64.
# Rutas sobrerribles por entorno para pruebas:
#   MAXINET_USUARIOS_DB, MAXINET_ZIVPN_CONEX_DB, MAXINET_CT_FILE
# =========================================================

BASE="/etc/maxinet"
[[ -f "$BASE/lib/ui.sh" ]] && source "$BASE/lib/ui.sh" 2>/dev/null || true

MAXINET_USUARIOS_DB="${MAXINET_USUARIOS_DB:-${ABBIENET_USUARIOS_DB:-$BASE/usuarios.db}}"
MAXINET_ZIVPN_CONEX_DB="${MAXINET_ZIVPN_CONEX_DB:-${ABBIENET_ZIVPN_CONEX_DB:-/etc/zivpn/conexiones.db}}"
MAXINET_CT_FILE="${MAXINET_CT_FILE:-${ABBIENET_CT_FILE:-}}"

# Compatibilidad hacia atrás de variables
ABBIENET_USUARIOS_DB="$MAXINET_USUARIOS_DB"
ABBIENET_ZIVPN_CONEX_DB="$MAXINET_ZIVPN_CONEX_DB"
ABBIENET_CT_FILE="$MAXINET_CT_FILE"

# Colores ANSI / Nebula
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

# ─────────────────────────────────────────────────────────────
# Función awk COMPARTIDA (mawk-safe): ts_linea(linea) normaliza el timestamp
# de una línea de journalctl a "AAAA-MM-DD HH:MM:SS":
#   1) ISO embebido: 2026/10/20 03:10:20 o 2026-10-19T22:06:53
#   2) formato corto del journalctl: "Oct 19 22:06:53"
# Si no hay evidencia de fecha, devuelve "".
# ─────────────────────────────────────────────────────────────
_MAXINET_AWK_TS='
BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", _mn, " ")
    for (_i = 1; _i <= 12; _i++) _mnum[_mn[_i]] = _i
}
function ts_linea(line,   _s, _mon, _t, _day, _yr, _ep, _now) {
    if (match(line, /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]/)) {
        _ep = substr(line, 1, index(line, " ") - 1) + 0
        if (_ep > 1000000000)
            return strftime("%Y-%m-%d %H:%M:%S", _ep)
    }
    if (match(line, /[0-9][0-9][0-9][0-9][-\/][0-9][0-9][-\/][0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
        _s = substr(line, RSTART, RLENGTH)
        gsub(/[-\/]/, "-", _s)
        gsub(/T/, " ", _s)
        return _s
    }
    if (match(line, /(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[ ]+[0-9]+ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
        _s = substr(line, RSTART, RLENGTH)
        if (match(_s, /([0-9][0-9]):([0-9][0-9]):([0-9][0-9])/) == 0) return ""
        _t = substr(_s, RSTART, 8)
        _mon = substr(_s, 1, 3)
        _day = substr(_s, 5, RSTART - 5)
        gsub(/ /, "", _day)
        if (_day == "" || _mnum[_mon] == 0) return ""
        split(_t, _hms, ":")
        _now = systime()
        _yr = strftime("%Y", _now)
        _ep = mktime(sprintf("%d %d %d %d %d %d", _yr, _mnum[_mon], _day, _hms[1], _hms[2], _hms[3]))
        if (_ep == -1) return ""
        if (_ep > _now + 86400)
            _ep = mktime(sprintf("%d %d %d %d %d %d", _yr - 1, _mnum[_mon], _day, _hms[1], _hms[2], _hms[3]))
        if (_ep == -1) return ""
        return strftime("%Y-%m-%d %H:%M:%S", _ep)
    }
    return ""
}'
_ABBIENET_AWK_TS="$_MAXINET_AWK_TS"

# ─────────────────────────────────────────────────────────────
# UDP CUSTOM
# ─────────────────────────────────────────────────────────────

# Lee el journal de UDP Custom por stdin y emite sesiones únicas:
#   usuario|ip|puerto|desde|estado|ultimo
# estado = conectado | desconectado (última evidencia del binario)
# desde  = hora del connect de la sesión (ÚLTIMA CONEXIÓN)
# ultimo = hora del ÚLTIMO evento real (connect o disconnect)
udp_custom_parsear() {
    awk "$_MAXINET_AWK_TS"'
        {
            if (index($0, "Client connected") == 0 && index($0, "Client disconnected") == 0) next
            if (match($0, /\[src:[^]]*\]/) == 0) next
            src = substr($0, RSTART + 5, RLENGTH - 6)
            p = index(src, ":")
            if (p == 0) next
            ip = substr(src, 1, p - 1)
            port = substr(src, p + 1)
            if (ip == "" || port == "") next

            ts = ts_linea($0)
            user = ""
            if (match($0, /\[user:[^]]*\]/))
                user = substr($0, RSTART + 6, RLENGTH - 7)

            key = ip ":" port
            if (index($0, "Client connected") > 0) {
                if (!(key in seen)) order[++n] = key
                seen[key] = 1
                ip_of[key] = ip
                port_of[key] = port
                if (user != "") usr[key] = user
                else if (!(key in usr)) usr[key] = "N/D"
                if (state[key] != "conectado") {
                    if (ts != "") since[key] = ts
                    open_seq[key] = ++oseq
                }
                if (ts != "") last[key] = ts
                state[key] = "conectado"
            } else {
                if (!(key in seen)) {
                    best = ""
                    for (k in state) {
                        if (state[k] == "conectado" && ip_of[k] == ip) {
                            if (user != "" && usr[k] != user) continue
                            if (best == "" || open_seq[k] <= open_seq[best]) best = k
                        }
                    }
                    if (best != "") {
                        state[best] = "desconectado"
                        if (ts != "") last[best] = ts
                    } else {
                        order[++n] = key
                        seen[key] = 1
                        ip_of[key] = ip
                        port_of[key] = port
                        if (user != "") usr[key] = user
                        else if (!(key in usr)) usr[key] = "N/D"
                        if (ts != "") since[key] = ts
                        if (ts != "") last[key] = ts
                        state[key] = "desconectado"
                    }
                } else if (state[key] == "conectado") {
                    state[key] = "desconectado"
                    if (ts != "") last[key] = ts
                } else {
                    if (ts != "") last[key] = ts
                }
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                k = order[i]
                d = (k in since) ? since[k] : "N/D"
                e = (k in last) ? last[k] : ""
                printf "%s|%s|%s|%s|%s|%s\n", usr[k], ip_of[k], port_of[k], d, state[k], e
            }
        }'
}

# Ventana por defecto: últimas 6 horas
conexiones_udp_custom() {
    local horas="${1:-6}"
    local desde
    desde=$(date -d "-${horas} hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || return 0
    command -v journalctl >/dev/null 2>&1 || return 0
    local ARCH TO=2
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) TO=5 ;;
        *) TO=2 ;;
    esac
    timeout ${TO}s journalctl -u udp-custom -u maxinet-udp.service -u abbienet-udp.service --since "$desde" -o short-unix --no-pager -q -n 500 2>/dev/null \
        | udp_custom_parsear
}

# Solo sesiones cuya última evidencia es "conectado"
conexiones_udp_custom_activas() {
    conexiones_udp_custom "${1:-6}" | awk -F'|' '$5 == "conectado" { printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }'
}

# Contraseña real de un usuario UDP Custom según usuarios.db
pass_de_usuario_udp() {
    local user="$1"
    [[ -n "$user" && "$user" != "N/D" ]] || { echo "N/D"; return; }
    [[ -f "$MAXINET_USUARIOS_DB" ]] || { echo "N/D"; return; }
    local pass
    pass=$(awk -F':' -v u="$user" '$1 == u { print $2; exit }' "$MAXINET_USUARIOS_DB" 2>/dev/null)
    if [[ -n "$pass" ]]; then echo "$pass"; else echo "N/D"; fi
}

# ─────────────────────────────────────────────────────────────
# ZIVPN
# ─────────────────────────────────────────────────────────────

# Lee el journal de ZiVPN por stdin y emite sesiones únicas:
#   ip|puerto|desde|estado
zivpn_parsear() {
    awk "$_MAXINET_AWK_TS"'
        {
            is_c = index($0, "client connected") > 0
            is_d = index($0, "client disconnected") > 0
            if (is_c == 0 && is_d == 0) next
            if (match($0, /"addr": "[^"]*"/) == 0) next
            addr = substr($0, RSTART + 9, RLENGTH - 10)
            p = index(addr, ":")
            if (p == 0) next
            ip = substr(addr, 1, p - 1)
            port = substr(addr, p + 1)
            if (ip == "" || port == "") next

            ts = ts_linea($0)
            key = ip ":" port
            if (is_c) {
                if (!(key in seen)) order[++n] = key
                seen[key] = 1
                ip_of[key] = ip
                port_of[key] = port
                if (key in cerradas) delete cerradas[key]
                if (state[key] != "conectado") {
                    if (ts != "") since[key] = ts
                }
                state[key] = "conectado"
            } else {
                if (key in seen) {
                    if (state[key] == "conectado") state[key] = "desconectado"
                } else {
                    cerradas[key] = 1
                }
            }
        }
        END {
            for (i = 1; i <= n; i++) {
                k = order[i]
                st = (k in cerradas) ? "desconectado" : state[k]
                d = (k in since) ? since[k] : "N/D"
                printf "%s|%s|%s|%s\n", ip_of[k], port_of[k], d, st
            }
        }'
}

# Une sesiones del journal con la bitácora real de auth.sh (conexiones.db):
# agrega la contraseña usada en tiempo real.
zivpn_unir_claves() {
    local ventana="${ZIVPN_AUTH_WINDOW_SEG:-300}"
    local corte=""
    if [[ -n "$ventana" && "$ventana" -gt 0 ]]; then
        corte=$(date -d "-${ventana} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
    fi
    awk -F'|' -v db="$MAXINET_ZIVPN_CONEX_DB" -v corte="$corte" '
        BEGIN {
            if (db != "" && db != "/dev/null") {
                while ((getline line < db) > 0) {
                    n = split(line, f, "|")
                    if (n >= 3 && f[1] != "" && f[2] != "" && f[3] != "") {
                        if (n >= 5 && f[5] != "ok") continue
                        k_addr[f[2]] = f[3]
                        p = index(f[2], ":")
                        if (p > 0) {
                            ip = substr(f[2], 1, p - 1)
                            if (!(ip in ip_pass)) { ip_pass[ip] = f[3]; ip_mixed[ip] = 0 }
                            else if (ip_pass[ip] != f[3]) ip_mixed[ip] = 1
                        }
                        if (n >= 5 && f[5] == "ok" && p > 0) {
                            gsub(/T/, " ", f[1])
                            sub(/[-+][0-9][0-9]:?[0-9][0-9]$/, "", f[1])
                            key = ip "|" f[3]
                            if (!(key in ip_pass_time) || f[1] > ip_pass_time[key]) {
                                ip_pass_time[key] = f[1]
                            }
                        }
                    }
                }
                close(db)
            }
        }
        {
            ip = $1; port = $2; desde = $3; estado = $4
            addr = ip ":" port
            user = "N/D"
            if (addr in k_addr) {
                user = k_addr[addr]
            }
            else if (ip in ip_pass && ip_mixed[ip] == 0) {
                user = ip_pass[ip]
            }
            else if (ip in ip_pass && ip_mixed[ip] == 1 && corte != "") {
                recent_user = ""
                recent_count = 0
                for (key in ip_pass_time) {
                    split(key, k, "|")
                    if (k[1] == ip) {
                        pass = k[2]
                        dt = ip_pass_time[key]
                        if (dt >= corte) {
                            recent_user = pass
                            recent_count++
                        }
                    }
                }
                if (recent_count == 1) {
                    user = recent_user
                }
            }
            printf "%s|%s|%s|%s|%s\n", user, ip, port, desde, estado
        }'
}

conexiones_zivpn() {
    local horas="${1:-6}"
    local desde
    desde=$(date -d "-${horas} hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || return 0
    command -v journalctl >/dev/null 2>&1 || return 0
    local ARCH TO=2
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) TO=5 ;;
        *) TO=2 ;;
    esac
    timeout ${TO}s journalctl -u zivpn.service -u maxinet-zivpn.service --since "$desde" --no-pager -q -n 500 2>/dev/null \
        | zivpn_parsear \
        | zivpn_unir_claves
}

conexiones_zivpn_activas() {
    conexiones_zivpn "${1:-6}" | awk -F'|' '$5 == "conectado" { printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }'
}

podar_conexiones_zivpn() {
    local dias="${1:-30}"
    [[ -f "$MAXINET_ZIVPN_CONEX_DB" ]] || return 0
    local tmp="${MAXINET_ZIVPN_CONEX_DB}.tmp.$$"
    local corte epoch
    epoch=$(( $(date +%s) - dias * 86400 ))
    corte=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || corte=$(date -d "-${dias} days" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || return 0
    awk -F'|' -v corte="$corte" '$1 >= corte { print }' "$MAXINET_ZIVPN_CONEX_DB" > "$tmp" 2>/dev/null
    if [[ -s "$tmp" || ! -s "$MAXINET_ZIVPN_CONEX_DB" ]]; then
        mv -f "$tmp" "$MAXINET_ZIVPN_CONEX_DB" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
}

# ─────────────────────────────────────────────────────────────
# LIVENESS POR CONNTRACK (kernel)
# ─────────────────────────────────────────────────────────────

_ct_tiene_ip() {
    awk -v ip="$1" -v minrem="${2:-0}" '{
            hit = 0
            for (i = 1; i <= NF; i++) if ($i == "src=" ip) { hit = 1; break }
            if (!hit) next
            if (minrem + 0 > 0) {
                k = 0
                for (i = 1; i <= NF; i++) if ($i == "udp") { k = i; break }
                if (k == 0 || (k + 2) > NF) next
                if (($(k + 2) + 0) < (minrem + 0)) next
            }
            found = 1
            exit
        } END { exit found ? 0 : 1 }'
}

maxinet_ct_precachear() {
    unset MAXINET_CT_DUMP MAXINET_CT_DUMP_OK ABBIENET_CT_DUMP ABBIENET_CT_DUMP_OK
    [[ -z "${MAXINET_CT_NO_BIN:-${ABBIENET_CT_NO_BIN:-}}" ]] || return 0
    command -v conntrack >/dev/null 2>&1 || return 0
    local dump rc
    dump=$(timeout 3s conntrack -L -p udp -o ktimestamp 2>/dev/null)
    rc=$?
    if [[ $rc -ne 0 ]]; then
        dump=$(timeout 2s conntrack -L -p udp -o timestamp 2>/dev/null)
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        dump=$(timeout 2s conntrack -L -p udp 2>/dev/null)
        rc=$?
    fi
    [[ $rc -eq 0 ]] || return 0
    MAXINET_CT_DUMP="$dump"
    MAXINET_CT_DUMP_OK=1
    ABBIENET_CT_DUMP="$dump"
    ABBIENET_CT_DUMP_OK=1
}
abbiennet_ct_precachear() { maxinet_ct_precachear "$@"; }

conntrack_ip_viva() {
    local ip="$1" min_rem="${2:-0}"
    local ct="$MAXINET_CT_FILE"
    if [[ -z "$ct" ]]; then
        [[ -r /proc/net/nf_conntrack ]] && ct="/proc/net/nf_conntrack"
        [[ -z "$ct" && -r /proc/net/ip_conntrack ]] && ct="/proc/net/ip_conntrack"
    fi
    if [[ -n "$ct" && -r "$ct" ]]; then
        if _ct_tiene_ip "$ip" "$min_rem" < "$ct"; then echo "si"; else echo "no"; fi
        return
    fi
    if [[ -n "${MAXINET_CT_DUMP_OK:-${ABBIENET_CT_DUMP_OK:-}}" ]]; then
        local d="${MAXINET_CT_DUMP:-$ABBIENET_CT_DUMP}"
        [[ -z "$d" ]] && { echo "no"; return; }
        if printf '%s\n' "$d" | _ct_tiene_ip "$ip" "$min_rem"; then echo "si"; else echo "no"; fi
        return
    fi
    [[ -z "${MAXINET_CT_NO_BIN:-${ABBIENET_CT_NO_BIN:-}}" ]] || { echo "N/D"; return; }
    command -v conntrack >/dev/null 2>&1 || { echo "N/D"; return; }
    local dump rc
    dump=$(conntrack -L -p udp 2>/dev/null)
    rc=$?
    [[ $rc -eq 0 ]] || { echo "N/D"; return; }
    [[ -z "$dump" ]] && { echo "no"; return; }
    if printf '%s\n' "$dump" | _ct_tiene_ip "$ip" "$min_rem"; then echo "si"; else echo "no"; fi
}

_ct_puerto_en_flujos() {
    awk -v p="$1" '{
            for (i = 1; i <= NF; i++) {
                if ($i == "sport=" p || $i == "dport=" p) { found = 1; exit }
            }
        } END { exit found ? 0 : 1 }'
}

zivpn_ct_hay_flujos() {
    local puerto="${1:-5667}" ct="$MAXINET_CT_FILE"
    if [[ -z "$ct" ]]; then
        [[ -r /proc/net/nf_conntrack ]] && ct="/proc/net/nf_conntrack"
        [[ -z "$ct" && -r /proc/net/ip_conntrack ]] && ct="/proc/net/ip_conntrack"
    fi
    if [[ -n "$ct" && -r "$ct" ]]; then
        _ct_puerto_en_flujos "$puerto" < "$ct"
        return
    fi
    [[ -z "${MAXINET_CT_NO_BIN:-${ABBIENET_CT_NO_BIN:-}}" ]] || return 1
    command -v conntrack >/dev/null 2>&1 || return 1
    if [[ -n "${MAXINET_CT_DUMP_OK:-${ABBIENET_CT_DUMP_OK:-}}" ]]; then
        local d="${MAXINET_CT_DUMP:-$ABBIENET_CT_DUMP}"
        [[ -z "$d" ]] && return 1
        printf '%s\n' "$d" | _ct_puerto_en_flujos "$puerto"
        return
    fi
    conntrack -L -p udp 2>/dev/null | _ct_puerto_en_flujos "$puerto"
}

zivpn_umbral_frescura() {
    local stream="${MAXINET_CT_STREAM:-${ABBIENET_CT_STREAM:-}}"
    if [[ -z "$stream" ]]; then
        stream=$(sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream 2>/dev/null)
    fi
    [[ "$stream" =~ ^[0-9]+$ ]] || stream=180
    local u=$(( stream - 60 ))
    [[ "$u" -ge $(( stream / 3 )) ]] || u=$(( stream / 3 ))
    [[ "$u" -ge 10 ]] || u=10
    printf '%s\n' "$u"
}

zivpn_modo_en_linea() {
    if zivpn_ct_hay_flujos "${1:-5667}"; then
        echo "kernel"
    else
        echo "journal"
    fi
}

# ─────────────────────────────────────────────────────────────
# FLUJOS KERNEL ZIVPN + SESIONES REALES
# ─────────────────────────────────────────────────────────────

zivpn_flujos_kernel() {
    local puerto="${1:-5667}"
    local dump=""
    local ARCH TO=2
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) TO=5 ;;
        *) TO=2 ;;
    esac
    if [[ -n "${MAXINET_CT_DUMP_OK:-${ABBIENET_CT_DUMP_OK:-}}" ]]; then
        dump="${MAXINET_CT_DUMP:-$ABBIENET_CT_DUMP}"
    elif [[ -z "${MAXINET_CT_NO_BIN:-${ABBIENET_CT_NO_BIN:-}}" ]] && command -v conntrack >/dev/null 2>&1; then
        dump=$(timeout ${TO}s conntrack -L -p udp -o ktimestamp 2>/dev/null) || true
        [[ -z "$dump" ]] && dump=$(timeout ${TO}s conntrack -L -p udp -o timestamp 2>/dev/null)
        [[ -z "$dump" ]] && dump=$(timeout ${TO}s conntrack -L -p udp 2>/dev/null)
    fi
    [[ -n "$dump" ]] || return 0
    printf '%s\n' "$dump" | awk -v zp="$puerto" '
        /UNREPLIED/ { next }
        {
            ts = ""
            ep = 0
            if (match($0, /(^|[^A-Za-z])ts=[0-9][0-9]*(\.[0-9]+)?/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^[^A-Za-z]?ts=/, "", s)
                split(s, b, ".")
                ep = int(b[1] + 0)
            } else if (match($0, /\[[0-9][0-9]*\.[0-9]+\]/)) {
                s = substr($0, RSTART + 1, RLENGTH - 2)
                split(s, b, ".")
                ep = int(b[1] + 0)
            } else if (match($0, /^[0-9][0-9]*\.[0-9]+/)) {
                s = substr($0, 1, RLENGTH)
                split(s, b, ".")
                ep = int(b[1] + 0)
            }
            if (ep > 0) ts = strftime("%Y-%m-%d %H:%M:%S", ep)
            src1 = ""; sport1 = 0; sport2 = 0; nsp = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^src=/) { if (src1 == "") { split($i, a, "="); src1 = a[2] } }
                else if ($i ~ /^sport=/) {
                    split($i, a, "=")
                    if (nsp == 0) { sport1 = a[2] + 0; nsp = 1 }
                    else { sport2 = a[2] + 0 }
                }
            }
            if (src1 == "" || sport1 == 0) next
            if (sport2 != zp + 0) next
            print src1 "|" sport1 "|" ts
        }'
}

zivpn_iso_a_fecha() {
    local iso="${1:-}" d t
    [[ -n "$iso" ]] || return 0
    d="${iso%%T*}"
    t="${iso#*T}"
    [[ "$d" != "$iso" && -n "$t" ]] || return 0
    t="${t%%[-+]*}"
    t="${t%%Z*}"
    t="${t%%.*}"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
    [[ "$t" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2} ]] || return 0
    printf '%s %s' "$d" "${t:0:8}"
}

zivpn_fecha_db() {
    local filas need dmap t k v ip port des fecha iso out=""
    filas=$(cat)
    [[ -n "$filas" ]] || return 0
    local db="${MAXINET_ZIVPN_CONEX_DB:-}"
    if [[ -z "$db" || "$db" == "/dev/null" || ! -s "$db" ]]; then
        printf '%s\n' "$filas"
        return 0
    fi
    need=$(printf '%s\n' "$filas" | awk -F'|' '$1 != "" && $3 == "" { print $1 ":" $2 }')
    if [[ -z "$need" ]]; then
        printf '%s\n' "$filas"
        return 0
    fi
    dmap=$(printf '%s\n' "$need" | awk -F'|' -v OFS='|' '
        FNR == NR {
            w[$0] = 1
            ip = $0
            sub(/:[0-9]+$/, "", ip)
            wip[ip] = 1
            next
        }
        NF >= 5 && $5 != "ok" { next }
        {
            ad = $2
            ip = $2
            sub(/:[0-9]+$/, "", ip)
            if ((ad in w) && $1 > mx[ad]) mx[ad] = $1
            if ((ip in wip) && $1 > mi[ip]) mi[ip] = $1
        }
        END {
            for (k in mx) print "A", k, mx[k]
            for (k in mi) print "I", k, mi[k]
        }' - "$db")
    local -A FA FI
    while IFS='|' read -r t k v; do
        [[ -z "$k" || -z "$v" ]] && continue
        if [[ "$t" == "A" ]]; then FA["$k"]="$v"; else FI["$k"]="$v"; fi
    done <<< "$dmap"
    while IFS='|' read -r ip port des; do
        [[ -z "$ip" ]] && continue
        if [[ -z "$des" ]]; then
            iso="${FA[$ip:$port]:-}"
            [[ -z "$iso" ]] && iso="${FI[$ip]:-}"
            fecha=$(zivpn_iso_a_fecha "$iso")
            [[ -n "$fecha" ]] && des="$fecha"
        fi
        out+="${ip}|${port}|${des}"$'\n'
    done <<< "$filas"
    printf '%s' "$out"
}

zivpn_fecha_journal() {
    local jf="${1:-}" filas need dmap t k v ip port des fecha out=""
    filas=$(cat)
    [[ -n "$filas" ]] || return 0
    if [[ -z "$jf" ]]; then
        printf '%s\n' "$filas"
        return 0
    fi
    need=$(printf '%s\n' "$filas" | awk -F'|' '$1 != "" && $3 == "" { print $1 ":" $2 }')
    if [[ -z "$need" ]]; then
        printf '%s\n' "$filas"
        return 0
    fi
    dmap=$(printf '%s\n' "$jf" | awk -F'|' -v OFS='|' -v keys="$need" '
        BEGIN {
            n = split(keys, a, "\n")
            for (i = 1; i <= n; i++) {
                if (a[i] == "") continue
                w[a[i]] = 1
                ip = a[i]
                sub(/:[0-9]+$/, "", ip)
                wip[ip] = 1
            }
        }
        $5 == "conectado" && $2 != "" && $4 != "" && $4 != "N/D" {
            ad = $2 ":" $3
            if ((ad in w) && $4 > mx[ad]) mx[ad] = $4
            if (($2 in wip) && $4 > mi[$2]) mi[$2] = $4
        }
        END {
            for (k in mx) print "A", k, mx[k]
            for (k in mi) print "I", k, mi[k]
        }')
    local -A JA JI
    while IFS='|' read -r t k v; do
        [[ -z "$k" || -z "$v" ]] && continue
        if [[ "$t" == "A" ]]; then JA["$k"]="$v"; else JI["$k"]="$v"; fi
    done <<< "$dmap"
    while IFS='|' read -r ip port des; do
        [[ -z "$ip" ]] && continue
        if [[ -z "$des" ]]; then
            fecha="${JA[$ip:$port]:-}"
            [[ -z "$fecha" ]] && fecha="${JI[$ip]:-}"
            [[ -n "$fecha" ]] && des="$fecha"
        fi
        out+="${ip}|${port}|${des}"$'\n'
    done <<< "$filas"
    printf '%s' "$out"
}

zivpn_sesiones_reales() {
    local horas="${1:-6}"
    local puerto="${2:-5667}"
    local ventana="${ZIVPN_VENTANA_SEG:-60}"
    local ventana_sin_kernel="${ZIVPN_VENTANA_SIN_KERNEL:-300}"
    local corte
    corte=$(date -d "-${ventana} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    local journal_full journal_pass_all journal_pass flujos flujos_nuevos flujos_pass
    journal_full=$(conexiones_zivpn "$horas" 2>/dev/null)
    journal_pass_all=$(printf '%s\n' "$journal_full" | awk -F'|' \
        '$5 == "conectado" && $1 != "" && $1 != "N/D" {
            printf "%s|%s|%s|%s\n", $1, $2, $3, ($4 == "N/D" ? "" : $4)
        }')
    local n_j_total n_j_pass_all
    n_j_total=$(printf '%s\n' "$journal_full" | awk -F'|' '$5 == "conectado" && $2 != "" { c++ } END { print c + 0 }')
    n_j_pass_all=$(printf '%s\n' "$journal_pass_all" | grep -c .)

    flujos=$(zivpn_flujos_kernel "$puerto" 2>/dev/null)
    local hay_kernel=0
    [[ -n "$flujos" ]] && hay_kernel=1

    local ventana_eff=$(( hay_kernel ? ventana : ventana_sin_kernel ))
    local corte_eff
    corte_eff=$(date -d "-${ventana_eff} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

    journal_pass=$(printf '%s\n' "$journal_pass_all" | awk -F'|' -v corte="$corte_eff" '
        {
            d = ($4 == "" ? "" : $4)
            if (corte != "" && (d == "" || d < corte)) next
            print
        }')
    local n_j_pass
    n_j_pass=$(printf '%s\n' "$journal_pass" | grep -c .)

    flujos_nuevos=$(printf '%s\n' "$flujos" | awk -F'|' -v j="$journal_pass" '
        BEGIN {
            n = split(j, arr, "\n")
            for (i = 1; i <= n; i++) {
                split(arr[i], f, "|")
                if (f[2] != "") jd[f[2] ":" f[3]] = 1
            }
        }
        $1 != "" { if (!(($1 ":" $2) in jd)) print $1 "|" $2 "|" $3 }')

    local n_f_ts=0 n_f_db=0 n_f_jr=0 n_f_vac0 n_f_vac1 n_f_vac2 n_f_filas
    if [[ -n "$flujos_nuevos" ]]; then
        n_f_vac0=$(printf '%s\n' "$flujos_nuevos" | awk -F'|' '$3 == "" && $1 != "" { c++ } END { print c + 0 }')
        n_f_filas=$(printf '%s\n' "$flujos_nuevos" | awk -F'|' '$1 != "" { c++ } END { print c + 0 }')
        n_f_ts=$(( n_f_filas - n_f_vac0 ))
        flujos_nuevos=$(printf '%s\n' "$flujos_nuevos" | zivpn_fecha_db)
        n_f_vac1=$(printf '%s\n' "$flujos_nuevos" | awk -F'|' '$3 == "" && $1 != "" { c++ } END { print c + 0 }')
        n_f_db=$(( n_f_vac0 - n_f_vac1 ))
        flujos_nuevos=$(printf '%s\n' "$flujos_nuevos" | zivpn_fecha_journal "$journal_full")
        n_f_vac2=$(printf '%s\n' "$flujos_nuevos" | awk -F'|' '$3 == "" && $1 != "" { c++ } END { print c + 0 }')
        n_f_jr=$(( n_f_vac1 - n_f_vac2 ))
    fi
    flujos_pass=""
    local n_f_total=0 n_f_pass=0
    if [[ -n "$flujos_nuevos" ]]; then
        n_f_total=$(printf '%s\n' "$flujos_nuevos" | grep -c .)
        flujos_pass=$(printf '%s\n' "$flujos_nuevos" \
            | awk -F'|' '{ printf "%s|%s|%s|conectado\n", $1, $2, $3 }' \
            | zivpn_unir_claves \
            | awk -F'|' '$1 != "" && $1 != "N/D" { printf "%s|%s|%s|%s\n", $1, $2, $3, $4 }')
        n_f_pass=$(printf '%s\n' "$flujos_pass" | grep -c .)
    fi

    {
        [[ -n "$journal_pass" ]] && printf '%s\n' "$journal_pass"
        [[ -n "$flujos_pass" ]] && printf '%s\n' "$flujos_pass"
    }
    printf '#fechas|%d;%d;%d\n' "$n_f_ts" "$n_f_db" "$(( n_j_pass + n_f_jr ))"
    printf '#descartadas|%d\n' "$(( n_j_total - n_j_pass + n_f_total - n_f_pass ))"
}

zivpn_agrupar() {
    awk -F'|' '
        $1 != "" && $1 !~ /^#/ {
            pass = $1; ip = $2; desde = $4; viva = $5
            if (!(pass in seen)) { order[++npass] = pass; seen[pass] = 1; nses[pass] = 0; nviv[pass] = 0; ips[pass] = ""; nip[pass] = 0; ult[pass] = "" }
            nses[pass]++
            if (viva == "si") nviv[pass]++
            if (index(" " ips[pass] " ", " " ip " ") == 0) { ips[pass] = (ips[pass] == "" ? ip : ips[pass] " " ip); nip[pass]++ }
            if (desde > ult[pass]) ult[pass] = desde
        }
        END {
            for (i = 1; i <= npass; i++) {
                p = order[i]
                printf "%s|%d|%s|%d|%s|%d\n", p, nses[p], ips[p], nip[p], ult[p], nviv[p]
            }
        }'
}

_zivpn_celda16() {
    local s="${1:-}"
    local n=${#s}
    if (( n > 16 )); then
        s="${s:0:16}"
        n=16
    fi
    if (( n < 16 )); then
        printf '%s%*s' "$s" $(( 16 - n )) ''
    else
        printf '%s' "$s"
    fi
}

_zivpn_hace() {
    local ult="${1:-}" vacio="${2:-en vivo}" tseg edad dd
    [[ -z "$ult" || "$ult" == "sin fecha" || "$ult" == "nunca vista" ]] && { printf '%s' "$vacio"; return 0; }
    [[ "$ult" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] || { printf '%s' "$vacio"; return 0; }
    local nseg="${ZIVPN_NOW:-}"
    [[ -z "$nseg" ]] && nseg=$(date +%s 2>/dev/null)
    tseg=$(date -d "$ult" +%s 2>/dev/null)
    if [[ -n "$tseg" && -n "$nseg" ]]; then
        edad=$(( nseg - tseg ))
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

zivpn_pintar_tabla() {
    local pad modo="${2:-kernel}"
    pad=$(printf '%*s' "${1:-1}" '')
    local entrada ZIVPN_NOW
    ZIVPN_NOW=$(date +%s 2>/dev/null)
    entrada=$(cat)

    local filas_on n_on
    filas_on=$(printf '%s\n' "$entrada" \
        | awk -F'|' '$1 != "" && $1 !~ /^#/ && $6 + 0 >= 1 { print }' \
        | LC_ALL=C sort -t'|' -k5,5r -k2,2rn)
    n_on=$(printf '%s\n' "$filas_on" | awk -F'|' '$1 != "" { c++ } END { print c + 0 }')

    local db_claves grupos_off cand p u fecha iso
    grupos_off=$(printf '%s\n' "$entrada" \
        | awk -F'|' '$1 != "" && $1 !~ /^#/ && $6 + 0 < 1 { print }')
    local db="${MAXINET_ZIVPN_CONEX_DB:-}" db_dates=""
    if [[ -n "$db" && "$db" != "/dev/null" && -s "$db" ]]; then
        db_claves=$(awk -F'|' 'NF >= 5 && $5 == "ok" && $3 != "" { print $3 }' "$db" \
            | LC_ALL=C sort -u)
        db_dates=$(awk -F'|' -v OFS='|' '
            NF >= 5 && $5 == "ok" && $3 != "" && $1 > best[$3] { best[$3] = $1 }
            END { for (k in best) print k, best[k] }' "$db")
    fi
    declare -A _ON_PASS=()
    local _op
    while IFS='|' read -r _op _; do
        [[ -n "$_op" ]] && _ON_PASS["$_op"]=1
    done <<< "$filas_on"

    local valid_passes=""
    local cfg="${MAXINET_ZIVPN_CONFIG:-/etc/zivpn/config.json}"
    local cad="${MAXINET_ZIVPN_CADUCIDAD:-/etc/zivpn/caducidad.db}"
    local lim="${MAXINET_ZIVPN_LIMITES:-/etc/zivpn/limites.db}"
    if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
        valid_passes+=$(jq -r '.auth.config[]?' "$cfg" 2>/dev/null)$'\n'
    fi
    [[ -f "$cad" ]] && valid_passes+=$(cut -d: -f1 "$cad" 2>/dev/null)$'\n'
    [[ -f "$lim" ]] && valid_passes+=$(cut -d: -f1 "$lim" 2>/dev/null)$'\n'
    valid_passes=$(printf '%s\n' "$valid_passes" | awk 'NF && !seen[$0]++')

    declare -A _VALID_PASS=()
    local _vp
    if [[ -n "$valid_passes" ]]; then
        while IFS= read -r _vp; do
            [[ -n "$_vp" ]] && _VALID_PASS["$_vp"]=1
        done <<< "$valid_passes"
    fi

    declare -A _CAND_SEEN=()
    cand=""
    local _raw_cand _rc
    _raw_cand=$(printf '%s\n%s\n%s\n' "$grupos_off" "${db_claves:-}" "${valid_passes:-}" | awk -F'|' '$1 != "" { print $1 }')
    while IFS= read -r _rc; do
        [[ -z "$_rc" ]] && continue
        [[ -n "${_ON_PASS[$_rc]:-}" ]] && continue
        [[ -n "${_CAND_SEEN[$_rc]:-}" ]] && continue
        if [[ -n "$valid_passes" && -z "${_VALID_PASS[$_rc]:-}" ]]; then
            continue
        fi
        _CAND_SEEN["$_rc"]=1
        cand+="${_rc}"$'\n'
    done <<< "$_raw_cand"

    local -A OFF_DATES=()
    if [[ -n "$db_dates" ]]; then
        while IFS='|' read -r p iso; do
            [[ -z "$p" || -z "$iso" ]] && continue
            fecha=$(zivpn_iso_a_fecha "$iso")
            [[ -n "$fecha" ]] && OFF_DATES["$p"]="$fecha"
        done <<< "$db_dates"
    fi
    if [[ -n "$grupos_off" ]]; then
        while IFS='|' read -r p _ _ _ u _; do
            [[ -z "$p" ]] && continue
            if [[ -z "${OFF_DATES[$p]:-}" || "$u" > "${OFF_DATES[$p]}" ]]; then
                OFF_DATES["$p"]="$u"
            fi
        done <<< "$grupos_off"
    fi

    local off_rows="" off_orden="" n_off=0
    if [[ -n "$cand" ]]; then
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            u="${OFF_DATES[$p]:-nunca vista}"
            off_rows+="${p}|${u}"$'\n'
        done <<< "$cand"
        off_orden=$(printf '%s' "$off_rows" | LC_ALL=C sort -t'|' -k2,2r -k1,1)
        n_off=$(printf '%s\n' "$off_orden" | awk -F'|' '$1 != "" { c++ } END { print c + 0 }')
    fi

    if [[ "$n_on" -eq 0 && "$n_off" -eq 0 ]]; then
        return 0
    fi

    local C_AZUL="\033[1;34m"
    local C_CIAN="\033[1;36m"
    local C_VERDE="\033[1;32m"
    local C_AMARILLO="\033[1;33m"
    local C_BLANCO="\033[1;37m"
    local C_GRIS="\033[38;5;245m"
    local C_DORADO="\033[38;5;220m"
    local C_RESET="\033[0m"

    local c_borde="$C_AZUL"
    local c_hdr="$C_BLANCO"

    local top="┌──────────────────┬──────────┬─────────────────────┬────────────┐"
    local mid="├──────────────────┼──────────┼─────────────────────┼────────────┤"
    local bot="└──────────────────┴──────────┴─────────────────────┴────────────┘"

    echo -e "${pad}${c_borde}${top}${C_RESET}"
    printf "${pad}${c_borde}│${C_RESET} %s ${c_borde}│${C_RESET} %s ${c_borde}│${C_RESET} %s ${c_borde}│${C_RESET} %s ${c_borde}│${C_RESET}\n" \
        "CONTRASEÑA      " "USUARIOS" "ÚLTIMA CONEXIÓN    " "ESTADO    "
    echo -e "${pad}${c_borde}${mid}${C_RESET}"

    local pass nses ips nip ult nviv ip_count ip_txt cell hace est tcol marca shown=0
    local max="${ZIVPN_TABLA_MAX:-25}"
    local usr_on=0
    usr_on=$(printf '%s\n' "$filas_on" | awk -F'|' '$1 != "" { s += $4 + 0 } END { print s + 0 }')

    if [[ "$n_on" -gt 0 ]]; then
        while IFS='|' read -r pass nses ips nip ult nviv; do
            [[ -z "$pass" ]] && continue
            [[ "$shown" -ge "$max" ]] && break
            shown=$(( shown + 1 ))
            [[ -z "$ult" ]] && ult="sin fecha"
            marca="◐"; tcol="$C_AMARILLO"
            [[ "${nviv:-0}" -ge "${nses:-1}" ]] && { marca="●"; tcol="$C_VERDE"; }
            hace=$(_zivpn_hace "$ult" "en vivo")
            printf -v est '%s %-8s' "$marca" "$hace"
            cell=$(_zivpn_celda16 "$pass")
            printf "${pad}${c_borde}│${C_RESET} ${C_AMARILLO}%s${C_RESET} ${c_borde}│${C_RESET} ${C_BLANCO}%8s${C_RESET} ${c_borde}│${C_RESET} ${C_CIAN}%-19s${C_RESET} ${c_borde}│${C_RESET} ${tcol}%s${C_RESET} ${c_borde}│${C_RESET}\n" \
                "$cell" "${nip:-$nses}" "$ult" "$est"
        done <<< "$filas_on"
    fi

    if [[ "$n_off" -gt 0 && "$shown" -lt "$max" ]]; then
        while IFS='|' read -r pass ult; do
            [[ -z "$pass" ]] && continue
            [[ "$shown" -ge "$max" ]] && break
            shown=$(( shown + 1 ))
            [[ -z "$ult" ]] && ult="nunca vista"
            hace=$(_zivpn_hace "$ult" "nunca")
            printf -v est '%s %-8s' "○" "$hace"
            cell=$(_zivpn_celda16 "$pass")
            printf "${pad}${c_borde}│${C_RESET} ${C_GRIS}%s${C_RESET} ${c_borde}│${C_RESET} ${C_GRIS}%8s${C_RESET} ${c_borde}│${C_RESET} ${C_GRIS}%-19s${C_RESET} ${c_borde}│${C_RESET} ${C_GRIS}%s${C_RESET} ${c_borde}│${C_RESET}\n" \
                "$cell" "0" "$ult" "$est"
        done <<< "$off_orden"
    fi

    echo -e "${pad}${c_borde}${bot}${C_RESET}"
    local leyenda="●/◐ = con tráfico kernel reciente · ○ = apagada"
    [[ "$modo" == "journal" ]] && leyenda="●/◐ = conectada en los últimos ${ZIVPN_VENTANA_SEG:-60} s · ○ = apagada"
    echo -e "${pad}${C_GRIS}${n_on} contraseña(s) en línea · ${usr_on} usuario(s) conectado(s) · ${n_off} apagada(s) · ${leyenda}${C_RESET}"
}

purgar_flujos_zivpn_muertos() {
    local puerto="${1:-5667}"
    command -v conntrack >/dev/null 2>&1 || { echo 0; return 0; }
    local dump=""
    if [[ -n "${MAXINET_CT_DUMP_OK:-${ABBIENET_CT_DUMP_OK:-}}" ]]; then
        dump="${MAXINET_CT_DUMP:-${ABBIENET_CT_DUMP:-}}"
    else
        dump=$(conntrack -L -p udp -o timestamp 2>/dev/null) || true
        [[ -z "$dump" ]] && dump=$(conntrack -L -p udp 2>/dev/null)
    fi
    [[ -n "$dump" ]] || { echo 0; return 0; }
    local borrados=0 f_src f_sport f_dst f_dport
    while IFS='|' read -r f_src f_sport f_dst f_dport; do
        [[ -z "$f_src" ]] && continue
        if conntrack -D -p udp --src "$f_src" --sport "$f_sport" --dst "$f_dst" --dport "$f_dport" >/dev/null 2>&1; then
            borrados=$((borrados + 1))
        fi
    done < <(printf '%s\n' "$dump" | awk -v zp="$puerto" '
        /UNREPLIED/ { next }
        {
            k = 0
            for (i = 1; i <= NF; i++) if ($i == "udp") { k = i; break }
            if (k == 0 || (k + 2) > NF) next
            rem = $(k + 2) + 0
            if (rem > 5) next
            src1 = ""; dst1 = ""; sport1 = 0; dport1 = 0; sport2 = 0
            nsp = 0; ndp = 0; nsr = 0; nds = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^src=/) { split($i, a, "="); if (nsr == 0) { src1 = a[2]; nsr = 1 } }
                else if ($i ~ /^dst=/) { split($i, a, "="); if (nds == 0) { dst1 = a[2]; nds = 1 } }
                else if ($i ~ /^sport=/) { split($i, a, "="); if (nsp == 0) { sport1 = a[2] + 0; nsp = 1 } else { sport2 = a[2] + 0 } }
                else if ($i ~ /^dport=/) { split($i, a, "="); if (ndp == 0) { dport1 = a[2] + 0; ndp = 1 } }
            }
            if (src1 == "" || dst1 == "" || sport1 == 0 || dport1 == 0) next
            if (sport2 != zp + 0) next
            printf "%s|%s|%s|%s\n", src1, sport1, dst1, dport1
        }')
    echo "$borrados"
}

mostrar_udp_custom_conectados() {
    echo -e " ${C_B_CIAN}🚀 Conexiones UDP Custom en Vivo${C_RESET}"
    local data
    data=$(conexiones_udp_custom 6)
    if [[ -z "$data" ]]; then
        echo -e " ${C_GRIS}(sin sesiones registradas)${C_RESET}"
        return
    fi
    printf '%s\n' "$data"
}

mostrar_zivpn_conectados() {
    local puerto="${1:-5667}"
    echo -e " ${C_B_CIAN}⚡ Conexiones ZiVPN en Vivo (Puerto UDP :$puerto)${C_RESET}"
    maxinet_ct_precachear
    local sesiones agrupadas
    sesiones=$(zivpn_sesiones_reales 6 "$puerto")
    agrupadas=$(printf '%s\n' "$sesiones" | zivpn_agrupar)
    if [[ -z "$agrupadas" ]]; then
        echo -e " ${C_GRIS}(sin contraseñas activas en este momento)${C_RESET}"
        return
    fi
    printf '%s\n' "$agrupadas" | zivpn_pintar_tabla 2 "kernel"
}
