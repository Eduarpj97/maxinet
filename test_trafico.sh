#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# test_trafico.sh — Pruebas de TRÁFICO & USO (v3.1.5)
# Sin root, sin iptables real, sin conntrack real:
#   · iptables-save -c  → fixture de texto (formato literal)
#   · conntrack         → fixture /proc/net/nf_conntrack
#   · journal           → fixture de journalctl (-o short-unix)
# Uso: bash test_trafico.sh
# ═══════════════════════════════════════════════════════════════
set -u

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE" || exit 1

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✘ $1"; [[ -n "${2:-}" ]] && echo "      detalle: $2"; return 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Entorno aislado: nada toca /etc/maxinet ni iptables reales ──
export MAXINET_BASE="$TMP/base"
export MAXINET_TRAFICO_DIR="$TMP/trafico"
export MAXINET_USUARIOS_DB="$TMP/usuarios.db"
export MAXINET_TRAF_IPT_FILE="$TMP/ipt.save"
export MAXINET_TRAF_CT_FILE="$TMP/conntrack.txt"
export MAXINET_TRAF_JOURNAL_FILE="$TMP/journal.txt"
export MAXINET_ZIVPN_CONFIG="$TMP/zivpn.json"
export MAXINET_ZIVPN_CONEX_DB="$TMP/conexiones.db"
export MAXINET_ZIVPN_CADUCIDAD="$TMP/caducidad.db"

mkdir -p "$MAXINET_TRAFICO_DIR/historial" "$MAXINET_TRAFICO_DIR/snapshots"
: > "$MAXINET_TRAF_CT_FILE"
: > "$MAXINET_TRAF_JOURNAL_FILE"

printf 'juan:x:2030-01-01:0\nroot:x:2030-01-01:0\n' > "$MAXINET_USUARIOS_DB"

source ./herramientas/trafico.sh

# ═══════════════════════════════════════════════════════════════
echo "════ 1. Contadores iptables: formato real [pkts:bytes] -A ════"
cat > "$MAXINET_TRAF_IPT_FILE" << 'EOF'
*filter
:INPUT ACCEPT [0:0]
:ABN_juan_IN - [0:0]
:ABN_juan_OUT - [0:0]
:ABN_otro_IN - [0:0]
[100:4096] -A ABN_juan_IN -j RETURN
[7:2048] -A ABN_juan_OUT -j RETURN
[3:999] -A ABN_otro_IN -j RETURN
[50:111] -A INPUT -s 203.0.113.9/32 -j ABN_juan_IN
COMMIT
EOF

trafico_limpiar_cache
V=$(trafico_leer_iptables juan)
[[ "$V" == "6144" ]] && ok "IN(4096)+OUT(2048) = 6144 B" || fail "suma de cadena ABN_juan" "esperado 6144, obtenido '$V'"

trafico_limpiar_cache
V=$(trafico_leer_iptables root)
[[ "$V" == "0" ]] && ok "cuenta sin cadenas => 0 B" || fail "cuenta sin cadenas" "obtenido '$V'"

: > "$MAXINET_TRAF_IPT_FILE"
trafico_limpiar_cache
V=$(trafico_leer_iptables juan)
[[ "$V" == "0" ]] && ok "iptables vacío => 0 B (sin error)" || fail "iptables vacío" "obtenido '$V'"

# ═══════════════════════════════════════════════════════════════
echo "════ 2. ip_map.db delimitado por ':' (legible con -F:) ════"
trafico_init
trafico_registrar_ip juan 203.0.113.9
grep -q '^203.0.113.9:juan:[0-9]\{1,\}$' "$MAXINET_TRAFICO_DIR/ip_map.db" \
    && ok "fila 'IP:usuario:epoch' escrita con ':'" \
    || fail "formato de ip_map.db" "$(cat "$MAXINET_TRAFICO_DIR/ip_map.db")"

OWNER=$(awk -F: -v ip=203.0.113.9 '$1 == ip { print $2 }' "$MAXINET_TRAFICO_DIR/ip_map.db")
[[ "$OWNER" == "juan" ]] && ok "la IP se resuelve a juan con awk -F:" || fail "relectura de ip_map" "dueño '$OWNER'"

_traf_desregistrar_ip 203.0.113.9
grep -q '^203.0.113.9:' "$MAXINET_TRAFICO_DIR/ip_map.db" \
    && fail "desregistrar debe borrar la fila" "$(cat "$MAXINET_TRAFICO_DIR/ip_map.db")" \
    || ok "desregistrar retira la fila de ip_map.db"

# ═══════════════════════════════════════════════════════════════
echo "════ 3. CGNAT: IP compartida dentro de 300 s => sin dueño ════"
printf '%s\n' \
    '1700000000|ssh|juan|198.51.100.7' \
    '1700000100|ssh|pedro|198.51.100.7' \
    '1700000000|ssh|juan|198.51.100.8' \
    '1700000400|ssh|pedro|198.51.100.8' \
    | _traf_resolver_cgnat > "$TMP/cgnat.txt"

grep -qx '198.51.100.7|' "$TMP/cgnat.txt" \
    && ok "2 logins en 100 s => IP ambigua, sin usuario" \
    || fail "CGNAT ambiguo" "$(cat "$TMP/cgnat.txt")"

grep -qx '198.51.100.8|pedro' "$TMP/cgnat.txt" \
    && ok "400 s de diferencia => gana el login más reciente (pedro)" \
    || fail "CGNAT resuelto" "$(cat "$TMP/cgnat.txt")"

# ═══════════════════════════════════════════════════════════════
echo "════ 3b. Atribución IP → usuario por journal (una pasada) ════"
trafico_limpiar_cache
printf '%s\n' '1760000000 host sshd[1]: Accepted password for juan from 198.51.100.33 port 5555 ssh2' > "$MAXINET_TRAF_JOURNAL_FILE"
printf '198.51.100.33 4096\n' > "$MAXINET_TRAF_CT_FILE"
trafico_sincronizar_ips >/dev/null 2>&1
grep -q '^198.51.100.33:juan:' "$MAXINET_TRAFICO_DIR/ip_map.db" \
    && ok "journal SSH atribuye 198.51.100.33 a juan" \
    || fail "atribución por journal" "$(cat "$MAXINET_TRAFICO_DIR/ip_map.db")"

trafico_limpiar_cache
printf '198.51.100.44 2048\n' > "$MAXINET_TRAF_CT_FILE"
trafico_sincronizar_ips >/dev/null 2>&1
grep -q '^198.51.100.44:' "$MAXINET_TRAFICO_DIR/ip_map.db" \
    && fail "IP sin login NO debe atribuirse" "$(cat "$MAXINET_TRAFICO_DIR/ip_map.db")" \
    || ok "IP sin login verificable queda sin dueño (N/D)"

: > "$MAXINET_TRAF_CT_FILE"
: > "$MAXINET_TRAF_JOURNAL_FILE"
trafico_limpiar_cache

# ═══════════════════════════════════════════════════════════════
echo "════ 4. Límites: 0 / vacío / no numérico NUNCA bloquean ════"
cat > "$MAXINET_TRAFICO_DIR/limites_gb.db" << 'EOF'
juan:Ilimitado
pedro:0
luis:abc
ana:
maria:5
EOF

[[ "$(trafico_obtener_limite juan)"  == "0" ]] && ok "'Ilimitado' => ilimitado (0)" || fail "límite Ilimitado" "$(trafico_obtener_limite juan)"
[[ "$(trafico_obtener_limite pedro)" == "0" ]] && ok "límite 0 => ilimitado" || fail "límite 0" "$(trafico_obtener_limite pedro)"
[[ "$(trafico_obtener_limite luis)"  == "0" ]] && ok "límite 'abc' => ilimitado" || fail "límite no numérico" "$(trafico_obtener_limite luis)"
[[ "$(trafico_obtener_limite maria)" == "5" ]] && ok "límite 5 GB se conserva" || fail "límite 5 GB" "$(trafico_obtener_limite maria)"

trafico_init
grep -q 'Ilimitado\|^ana:' "$MAXINET_TRAFICO_DIR/limites_gb.db" \
    && fail "trafico_init debe sanear límites basura" "$(cat "$MAXINET_TRAFICO_DIR/limites_gb.db")" \
    || ok "trafico_init descarta 'Ilimitado', 0 y valores no numéricos"

: > "$MAXINET_TRAFICO_DIR/bloqueados.db"
trafico_bloquear_usuario juan
grep -q '^juan:' "$MAXINET_TRAFICO_DIR/bloqueados.db" \
    && fail "juan (ilimitado) no debe bloquearse" "$(cat "$MAXINET_TRAFICO_DIR/bloqueados.db")" \
    || ok "usuario sin límite numérico no se bloquea"

trafico_verificar_limites >/dev/null 2>&1
grep -q '^maria:' "$MAXINET_TRAFICO_DIR/bloqueados.db" \
    && fail "maria (0 B de 5 GB) no debe bloquearse" "$(cat "$MAXINET_TRAFICO_DIR/bloqueados.db")" \
    || ok "verificar_limites no bloquea a quien no superó su cuota"

# ═══════════════════════════════════════════════════════════════
echo "════ 5. ZiVPN: conexiones.db con 'ip:puerto' y clave ════"
cat > "$MAXINET_ZIVPN_CONEX_DB" << 'EOF'
2026-01-01 00:00:00|1.2.3.4:51820|clave1|1024|ok
2026-01-01 00:05:00|1.2.3.4:51821|clave2|2048|ok
2026-01-01 00:06:00|5.6.7.8:9000|clave3|512|fallo
EOF

ZMAP="$(_traf_zivpn_mapa)"
printf '%s\n' "$ZMAP" | grep -qx '1.2.3.4|zivpn_clave2' \
    && ok "IP recortada de ip:puerto y clave más reciente (clave2)" \
    || fail "mapa ZiVPN" "$ZMAP"
printf '%s\n' "$ZMAP" | grep -q '5\.6\.7\.8' \
    && fail "auth fallida no debe generar pseudo-usuario" "$ZMAP" \
    || ok "solo entradas con resultado 'ok'"

# ═══════════════════════════════════════════════════════════════
echo "════ 6. Parsers de journal (formatos reales) ════"
printf '%s\n' '1760000000 host sshd[4242]: Accepted password for juan from 203.0.113.9 port 5555 ssh2' \
    | _traf_parsear_ssh_journal > "$TMP/ssh.txt"
grep -qx '1760000000|ssh|juan|203.0.113.9' "$TMP/ssh.txt" \
    && ok "SSH: epoch|ssh|usuario|IP" || fail "parser SSH" "$(cat "$TMP/ssh.txt")"

printf '%s\n' '1760000000 host sshd[4242]: Accepted password for root from 203.0.113.9 port 5555 ssh2' \
    | _traf_parsear_ssh_journal > "$TMP/sshroot.txt"
[[ ! -s "$TMP/sshroot.txt" ]] && ok "root nunca se atribuye" || fail "root filtrado" "$(cat "$TMP/sshroot.txt")"

printf '%s\n' '1760000001 host udp-custom[9]: 2026/10/20 03:10:20 [INFO] [src:191.95.54.179:4814] [user:eduar] Client connected' \
    | _traf_parsear_udp_journal > "$TMP/udp.txt"
grep -qx '1760000001|udp|eduar|191.95.54.179' "$TMP/udp.txt" \
    && ok "UDP: epoch|udp|usuario|IP (sin puerto)" || fail "parser UDP" "$(cat "$TMP/udp.txt")"

# ═══════════════════════════════════════════════════════════════
echo "════ 7. Snapshots ausentes => exactamente una línea '0' ════"
V=$(trafico_servidor_dia 1999-01-01)
[[ "$V" == "0" ]] && ok "día sin .snap => '0' (una sola línea)" || fail "día sin snapshot" "obtenido '$V'"
V=$(trafico_servidor_hoy)
[[ "$V" =~ ^[0-9]+$ ]] && ok "hoy siempre numérico" || fail "hoy no numérico" "obtenido '$V'"

printf '00:01:1000:500\n12:00:2000:1500\n' > "$MAXINET_TRAFICO_DIR/snapshots/2000-01-01.snap"
V=$(trafico_servidor_dia 2000-01-01)
[[ "$V" == "2000" ]] && ok "snapshot HH:MM:RX:TX => delta real (1000+1000)" || fail "delta del snapshot" "obtenido '$V'"

printf '00:01:5000:5000\n12:00:4000:4000\n' > "$MAXINET_TRAFICO_DIR/snapshots/2000-01-02.snap"
V=$(trafico_servidor_dia 2000-01-02)
[[ "$V" == "0" ]] && ok "contadores que bajan (reinicio) => 0, nunca negativo" || fail "delta negativo" "obtenido '$V'"

# ═══════════════════════════════════════════════════════════════
echo "════ 8. Snapshot consolida el consumo en las DB ════"
cat > "$MAXINET_TRAF_IPT_FILE" << 'EOF'
*filter
:ABN_juan_IN - [0:0]
:ABN_juan_OUT - [0:0]
[100:4096] -A ABN_juan_IN -j RETURN
[7:2048] -A ABN_juan_OUT -j RETURN
COMMIT
EOF
: > "$MAXINET_TRAFICO_DIR/consumo.db"
trafico_guardar_snapshot >/dev/null 2>&1
CONS=$(awk -F: '$1 == "juan" { print $2 }' "$MAXINET_TRAFICO_DIR/consumo.db")
[[ "$CONS" == "6144" ]] && ok "consumo.db acumula 6144 B desde iptables" || fail "acumulación en consumo.db" "obtenido '$CONS'"

HIST=$(awk -F: '$1 == "juan" { print $2 }' "$MAXINET_TRAFICO_DIR/historial/$(date +%F).db")
[[ "$HIST" == "6144" ]] && ok "historial del día registra 6144 B" || fail "historial diario" "obtenido '$HIST'"

[[ -s "$MAXINET_TRAFICO_DIR/snapshots/$(date +%F).snap" ]] \
    && ok "snapshot de interfaz escrito" || fail "snapshot de interfaz ausente"

# ═══════════════════════════════════════════════════════════════
echo "════ 9. trafico_eliminar_usuario purga DBs y deja 0 filas ════"
printf 'juan:999\n' >> "$MAXINET_TRAFICO_DIR/limites_gb.db"
printf 'juan:1700000000\n' >> "$MAXINET_TRAFICO_DIR/bloqueados.db"
trafico_registrar_ip juan 198.51.100.20
trafico_eliminar_usuario juan
grep -q '^juan:' "$MAXINET_TRAFICO_DIR/consumo.db"     && fail "consumo.db conserva a juan" "$(cat "$MAXINET_TRAFICO_DIR/consumo.db")" || ok "consumo.db purgado"
grep -q '^juan:' "$MAXINET_TRAFICO_DIR/limites_gb.db"  && fail "limites_gb.db conserva a juan" || ok "limites_gb.db purgado"
grep -q '^juan:' "$MAXINET_TRAFICO_DIR/bloqueados.db"  && fail "bloqueados.db conserva a juan" || ok "bloqueados.db purgado"
grep -q '^198.51.100.20:' "$MAXINET_TRAFICO_DIR/ip_map.db" && fail "ip_map.db conserva la IP" || ok "ip_map.db purgado"

# ═══════════════════════════════════════════════════════════════
echo "════ 10. Sourcear el módulo NO abre menú ni corta el shell ════"
OUT=$(timeout 15 bash -c "source '$BASE/herramientas/trafico.sh'; echo RC_OK" < /dev/null 2>&1)
RC=$?
printf '%s' "$OUT" | grep -q 'RC_OK' && (( RC == 0 )) \
    && ok "source sin argumentos termina normalmente" \
    || fail "source colgó o salió con error" "rc=$RC salida='$OUT'"

OUT=$(timeout 15 bash -c "source '$BASE/herramientas/trafico.sh' --snapshot; echo RC_OK" < /dev/null 2>&1)
printf '%s' "$OUT" | grep -q 'RC_OK' \
    && ok "source con --snapshot tampoco entra al menú" \
    || fail "source --snapshot" "'$OUT'"

# ═══════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  RESULTADO: $PASS correctas · $FAIL fallidas"
echo "════════════════════════════════════════════════════════════"
(( FAIL == 0 ))
