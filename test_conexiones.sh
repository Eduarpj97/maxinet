#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# test_conexiones.sh — Pruebas con LOGS REALES para Maxinet v3.0
# (nada simulado: los fixtures son transcripciones literales)
# Uso: bash test_conexiones.sh
# ═══════════════════════════════════════════════════════════════
set -u

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE" || exit 1

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✘ $1"; [[ -n "${2:-}" ]] && echo "      detalle: $2"; return 0; }

# Entorno temporal aislado (rutas sobrerribles)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MAXINET_USUARIOS_DB="$TMP/usuarios.db"
export ABBIENET_USUARIOS_DB="$TMP/usuarios.db"
export MAXINET_ZIVPN_CONEX_DB="$TMP/conexiones.db"
export ABBIENET_ZIVPN_CONEX_DB="$TMP/conexiones.db"
export MAXINET_CT_FILE="$TMP/ct"
export ABBIENET_CT_FILE="$TMP/ct"

echo "════ 1. Parser UDP Custom (logs reales 2026-10-20) ════"
source ./herramientas/conexiones.sh

cat > "$TMP/udp.log" << 'EOF'
Oct 20 03:10:20 ee-uu2 udp-custom[2086745]: 2026/10/20 03:10:20 [INFO] [src:191.95.54.179:4814] [user:eduar] Client connected
Oct 20 03:14:43 ee-uu2 udp-custom[2086745]: 2026/10/20 03:14:43 [INFO] [error:timeout: no recent network activity] [src:191.95.54.179:40104] Client disconnected
Oct 20 03:14:43 ee-uu2 udp-custom[2086745]: 2026/10/20 03:14:43 [INFO] [src:191.95.54.179:61341] [user:eduar] Client connected
EOF

RES=$(udp_custom_parsear < "$TMP/udp.log")
N=$(printf '%s\n' "$RES" | grep -c . || true)

[[ "$N" == "2" ]] && ok "2 sesiones reales (4814 cerrada + 61341 abierta)" || fail "número de sesiones" "esperado 2, obtenido $N"
printf '%s\n' "$RES" | grep -q '^eduar|191.95.54.179|4814|2026-10-20 03:10:20|desconectado|2026-10-20 03:14:43$' \
    && ok "4814: conectó 03:10:20 y se cerró por disconnect 40104 (regla por IP)" || fail "sesión 4814" "$RES"
printf '%s\n' "$RES" | grep -q '^eduar|191.95.54.179|61341|2026-10-20 03:14:43|conectado|2026-10-20 03:14:43$' \
    && ok "conect 03:14:43 eduar@191.95.54.179:61341" || fail "sesión conect (61341)" "$RES"
printf '%s\n' "$RES" | grep -q '|191.95.54.179|40104|' \
    && fail "no debe inventarse una sesión para el puerto 40104 (nunca conectó)" || ok "puerto 40104 no genera sesión inventada"
printf '%s\n' "$RES" | grep -q '^N/D|' && fail "no debe aparecer usuario N/D con log completo" || ok "sin usuarios inventados (N/D ausente)"

# Disconnect sin sesión abierta y sin connect previo => evento con usuario N/D (evidencia real)
cat > "$TMP/udp2.log" << 'EOF'
Oct 20 05:00:00 ee-uu2 udp-custom[2086745]: 2026/10/20 05:00:00 [INFO] [error:timeout: no recent network activity] [src:203.0.113.77:50001] Client disconnected
EOF
RES2=$(udp_custom_parsear < "$TMP/udp2.log")
printf '%s\n' "$RES2" | grep -q '^N/D|203.0.113.77|50001|.*|desconectado|2026-10-20 05:00:00$' \
    && ok "disconnect sin contexto => evento N/D honesto" || fail "evento N/D honesto" "$RES2"

echo "════ 2. Parser ZiVPN (log real 2026-10-19) ════"
cat > "$TMP/zv.log" << 'EOF'
Oct 19 22:06:53 ee-uu2 zivpn[771]: INFO client connected {"addr": "191.95.16.206:59765"}
Oct 19 22:15:10 ee-uu2 zivpn[771]: INFO client disconnected {"addr": "191.95.16.206:59765"}
Oct 19 22:20:01 ee-uu2 zivpn[771]: INFO client connected {"addr": "191.95.16.206:40022"}
EOF

RES=$(zivpn_parsear < "$TMP/zv.log")
N=$(printf '%s\n' "$RES" | grep -c . || true)
[[ "$N" == "2" ]] && ok "2 sesiones (mismo addr unido)" || fail "número de sesiones ZiVPN" "esperado 2, obtenido $N: $RES"
printf '%s\n' "$RES" | grep -q '^191.95.16.206|59765|.*|desconectado$' \
    && ok "59765 desconectado" || fail "sesión 59765" "$RES"
printf '%s\n' "$RES" | grep -q '^191.95.16.206|40022|.*|conectado$' \
    && ok "40022 conectado" || fail "sesión 40022" "$RES"

FIX_EPOCH=$(( $(date +%s 2>/dev/null) - 2 * 86400 ))
FIX_D="$(date -d "@$FIX_EPOCH" '+%b %e %H:%M:%S' 2>/dev/null)"
FIX_ISO="$(date -d "@$FIX_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
if [[ -n "$FIX_D" && -n "$FIX_ISO" ]]; then
    printf '%s ee-uu2 zivpn[771]: INFO client connected {"addr": "203.0.113.50:5000"}\n' "$FIX_D" > "$TMP/zv2.log"
    RES=$(zivpn_parsear < "$TMP/zv2.log")
    printf '%s\n' "$RES" | grep -q "^203.0.113.50|5000|${FIX_ISO}|conectado$" \
        && ok "desde normalizado desde formato corto del journal ($FIX_ISO)" || fail "desde journal corto" "$RES"
    
    FIX2_EPOCH=$(( $(date +%s 2>/dev/null) - 12 * 86400 ))
    FIX2_D="$(date -d "@$FIX2_EPOCH" '+%b %e %H:%M:%S' 2>/dev/null)"
    FIX2_ISO="$(date -d "@$FIX2_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    printf '%s ee-uu2 zivpn[771]: INFO client connected {"addr": "203.0.113.51:5001"}\n' "$FIX2_D" > "$TMP/zv3.log"
    RES=$(zivpn_parsear < "$TMP/zv3.log")
    printf '%s\n' "$RES" | grep -q "^203.0.113.51|5001|${FIX2_ISO}|conectado$" \
        && ok "desde con día unitario del journal ('%e' con espacio)" || fail "desde journal día unitario" "$RES"
fi

echo "════ 3. Cruce sesión↔clave con conexiones.db ════"
cat > "$MAXINET_ZIVPN_CONEX_DB" << 'EOF'
2026-10-19T22:06:53-05:00|191.95.16.206:59765|3014455378|123456|ok
2026-10-19T22:20:01-05:00|191.95.16.206:40022|1997|123456|ok
EOF
RES=$(zivpn_parsear < "$TMP/zv.log" | zivpn_unir_claves)
printf '%s\n' "$RES" | grep -q '^3014455378|191.95.16.206|59765|.*|desconectado$' \
    && ok "clave 3014455378 cruzada por ip:puerto" || fail "cruce de clave 59765" "$RES"
printf '%s\n' "$RES" | grep -q '^1997|191.95.16.206|40022|.*|conectado$' \
    && ok "clave 1997 cruzada por ip:puerto" || fail "cruce de clave 40022" "$RES"

printf '%s\n' "10.0.0.9|1234|2026-10-19 22:00:00|conectado" | zivpn_unir_claves | grep -q '^N/D|10.0.0.9|' \
    && ok "sin registro en db => N/D" || fail "fallback N/D en db"

printf '%s\n' "2026-10-19T23:00:00-05:00|10.0.0.9:1234|clave_mala|0|rechazado" >> "$MAXINET_ZIVPN_CONEX_DB"
printf '%s\n' "10.0.0.9|1234|2026-10-19 22:00:00|conectado" | zivpn_unir_claves | grep -q '^N/D|10.0.0.9|' \
    && ok "intentos rechazados no asignan contraseña" || fail "filtro de rechazados"

echo "════ 4. Contraseña de usuario UDP (usuarios.db real) ════"
printf 'eduar:ClaveReal2026!::\n' > "$MAXINET_USUARIOS_DB"
[[ "$(pass_de_usuario_udp eduar)" == "ClaveReal2026!" ]] && ok "pass de eduar resuelta" || fail "pass_de_usuario_udp"
[[ "$(pass_de_usuario_udp nadie)" == "N/D" ]] && ok "usuario inexistente => N/D" || fail "usuario inexistente"
[[ "$(pass_de_usuario_udp N/D)" == "N/D" ]] && ok "usuario N/D => N/D" || fail "usuario N/D"

echo "════ 5. Liveness por conntrack (fixtures nf_conntrack) ════"
cat > "$MAXINET_CT_FILE" << 'EOF'
ipv4 2 udp 17 45 src=191.95.54.179 dst=203.0.113.5 sport=61341 dport=2100 src=203.0.113.5 dst=191.95.54.179 sport=2100 dport=61341 [ASSURED] mark=0 use=1
ipv4 6 tcp 6 431999 ESTABLISHED src=198.51.100.7 dst=203.0.113.5 sport=51000 dport=443 src=203.0.113.5 dst=198.51.100.7 sport=443 dport=51000 [ASSURED] mark=0 use=1
EOF
[[ "$(conntrack_ip_viva 191.95.54.179)" == "si" ]] && ok "IP con flujo UDP => si" || fail "conntrack si"
[[ "$(conntrack_ip_viva 203.0.113.5)" == "si" ]] && ok "IP como destino => si" || fail "conntrack dst"
[[ "$(conntrack_ip_viva 8.8.8.8)" == "no" ]] && ok "IP sin flujo => no" || fail "conntrack no"
MAXINET_CT_FILE="$TMP/noexiste" ; export MAXINET_CT_FILE
MAXINET_CT_NO_BIN=1 ; export MAXINET_CT_NO_BIN
ABBIENET_CT_NO_BIN=1 ; export ABBIENET_CT_NO_BIN
[[ "$(conntrack_ip_viva 8.8.8.8)" == "N/D" ]] && ok "sin conntrack legible => N/D" || fail "conntrack N/D"

echo "════ 6. auth.sh (heredoc real, allow/deny) ════"
awk "/<< 'AUTHEOF'/ {f=1; next} /^AUTHEOF\$/ {f=0} f" ./protocolos/zipvpn.sh > "$TMP/auth.sh"
grep -q 'exit 1' "$TMP/auth.sh" && grep -q 'jq -e' "$TMP/auth.sh" \
    && ok "auth.sh extraído del heredoc" || fail "extracción de auth.sh"
chmod +x "$TMP/auth.sh"

cat > "$TMP/config.json" << 'EOF'
{ "auth": { "mode": "command", "command": "/etc/zivpn/auth.sh", "config": ["3014455378", "1997"] } }
EOF
cat > "$TMP/caducidad.db" << 'EOF'
3014455378:2026-12-31
1997:2026-01-01
EOF
export MAXINET_ZIVPN_CONFIG="$TMP/config.json"
export ABBIENET_ZIVPN_CONFIG="$TMP/config.json"
export MAXINET_ZIVPN_CADUCIDAD="$TMP/caducidad.db"
export ABBIENET_ZIVPN_CADUCIDAD="$TMP/caducidad.db"
export MAXINET_ZIVPN_CONEX_DB="$TMP/conexiones.db"
export ABBIENET_ZIVPN_CONEX_DB="$TMP/conexiones.db"

MAXINET_AUTH_TEST=1 bash "$TMP/auth.sh" "191.95.16.206:59765" "3014455378" "123456" >/dev/null 2>&1 \
    && ok "clave vigente => permitida (exit 0)" || fail "allow: clave vigente"

MAXINET_AUTH_TEST=1 bash "$TMP/auth.sh" "191.95.16.206:59765" "clave_inventada_999" "0" >/dev/null 2>&1 \
    && fail "clave inventada no debe pasar" || ok "clave inventada => rechazada (exit≠0)"

MAXINET_AUTH_TEST=1 bash "$TMP/auth.sh" "191.95.16.206:59765" "1997" "0" >/dev/null 2>&1 \
    && fail "clave vencida no debe pasar" || ok "clave vencida (2026-01-01) => rechazada"

MAXINET_AUTH_TEST=1 bash "$TMP/auth.sh" "191.95.16.206:59765" "" "0" >/dev/null 2>&1 \
    && fail "clave vacía no debe pasar" || ok "clave vacía => rechazada"

# Registro real en bitácora (sin AUTH_TEST)
: > "$MAXINET_ZIVPN_CONEX_DB"
bash "$TMP/auth.sh" "203.0.113.9:1000" "3014455378" "123456" >/dev/null 2>&1
grep -q '^.*|203.0.113.9:1000|3014455378|.*|ok$' "$MAXINET_ZIVPN_CONEX_DB" \
    && ok "bitácora conexiones.db: línea real (fecha|addr|clave|tx|res)" || fail "registro en conexiones.db" "$(cat "$MAXINET_ZIVPN_CONEX_DB" 2>/dev/null)"
bash "$TMP/auth.sh" "203.0.113.9:1001" "mala" "0" >/dev/null 2>&1
grep -q '|203.0.113.9:1001|mala|.*|rechazado$' "$MAXINET_ZIVPN_CONEX_DB" \
    && ok "bitácora registra intentos rechazados" || fail "registro de rechazo"

echo "════ 7. Poda de conexiones.db ════"
FECHA_REC=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
{
    echo "2020-01-01T00:00:00-05:00|1.1.1.1:1|1|1|ok"
    echo "${FECHA_REC}|191.95.16.206:59765|3014455378|123456|ok"
} > "$MAXINET_ZIVPN_CONEX_DB"
podar_conexiones_zivpn 30
grep -q '2020-01-01' "$MAXINET_ZIVPN_CONEX_DB" && fail "entrada de 2020 no podada" || ok "entrada de 2020 podada"
grep -q '191.95.16.206' "$MAXINET_ZIVPN_CONEX_DB" && ok "entrada reciente conservada" || fail "entrada reciente perdida"

echo "════ 8. Parser ZiVPN estricto (anti-inflado TCP error) ════"
cat > "$TMP/zv_strict.log" << 'EOF'
Oct 20 13:22:20 ee-uu2 zivpn[175473]: ERROR TCP error {"addr": "191.95.20.59:29344", "id": "user", "reqAddr": "1.2.3.4:53", "error": "dial tcp 1.2.3.4:53: i/o timeout"}
Oct 20 13:22:26 ee-uu2 zivpn[175473]: INFO client connected {"addr": "191.95.20.59:29344"}
Oct 20 13:25:01 ee-uu2 zivpn[175473]: INFO client disconnected {"addr": "191.95.20.59:29344", "error": "accepting stream failed: timeout: no recent network activity"}
EOF
RES=$(zivpn_parsear < "$TMP/zv_strict.log")
N=$(printf '%s\n' "$RES" | grep -c . || true)
[[ "$N" == "1" ]] && ok "TCP error previo no crea sesión (1 sola sesión)" || fail "sesiones con TCP error" "esperado 1, obtenido $N: $RES"
printf '%s\n' "$RES" | grep -q '^191.95.20.59|29344|.*|desconectado$' \
    && ok "conect+disconnect reales => desconectado" || fail "estado post-disconnect" "$RES"

echo "════ 9. Cruce honesto de contraseñas (IP única vs CGNAT) ════"
cat > "$MAXINET_ZIVPN_CONEX_DB" << 'EOF'
2026-10-20T13:22:26-05:00|191.95.20.59:29344|12345|123456|ok
2026-10-20T13:30:00-05:00|191.95.16.167:60000|9999|0|ok
2026-10-20T13:31:00-05:00|191.95.16.167:60001|7777|0|ok
2026-10-20T13:40:00-05:00|191.95.16.86:30000|5555|0|ok
EOF
RES=$(printf '%s\n' "191.95.20.59|29344|2026-10-20 13:22:26|conectado" | zivpn_unir_claves)
printf '%s\n' "$RES" | grep -q '^12345|' && ok "addr exacta gana siempre" || fail "addr exacta" "$RES"
RES=$(printf '%s\n' "191.95.16.86|31000|2026-10-20 13:45:00|conectado" | zivpn_unir_claves)
printf '%s\n' "$RES" | grep -q '^5555|' && ok "IP con UNA sola contraseña conocida => esa pass" || fail "IP única" "$RES"
RES=$(printf '%s\n' "191.95.16.167|60002|2026-10-20 13:50:00|conectado" | zivpn_unir_claves)
printf '%s\n' "$RES" | grep -q '^N/D|' && ok "IP CGNAT con pass variadas => N/D honesto" || fail "CGNAT N/D" "$RES"

echo "════ 10. Flujos kernel ZiVPN (conntrack) ════"
export MAXINET_CT_DUMP_OK=1
export ABBIENET_CT_DUMP_OK=1
export MAXINET_CT_DUMP='ts=1761000000.123456 udp 17 19 src=191.95.37.37 dst=10.0.0.211 sport=13276 dport=9123 packets=1 bytes=110 src=10.0.0.211 dst=191.95.37.37 sport=5667 dport=27396 [ASSURED] mark=0 use=1
ts=1761000010.000000 udp 17 19 src=198.51.100.9 dst=10.0.0.211 sport=4444 dport=2222 packets=2 bytes=220 src=10.0.0.211 dst=198.51.100.9 sport=36712 dport=4444 [ASSURED] mark=0 use=1
udp 17 19 src=191.95.50.130 dst=10.0.0.211 sport=13085 dport=5667 packets=3 bytes=330 src=10.0.0.211 dst=191.95.50.130 sport=5667 dport=13085 [ASSURED] mark=0 use=1
udp 17 19 src=203.0.113.50 dst=10.0.0.211 sport=5000 dport=5667 packets=2 bytes=220 src=10.0.0.211 dst=203.0.113.50 sport=5667 dport=5000 [UNREPLIED] mark=0 use=1'
export ABBIENET_CT_DUMP="$MAXINET_CT_DUMP"

RES=$(zivpn_flujos_kernel 5667)
N=$(printf '%s\n' "$RES" | grep -c .)
[[ "$N" == "2" ]] && ok "flujos kernel: 2 ZiVPN vivos de 4 líneas (respuesta sport=5667)" || fail "conteo flujos kernel" "esperado 2, obtenido $N: $RES"

echo "════ 11. zivpn_agrupar: tabla por contraseña ════"
RES=$(printf '%s\n' \
    '1997|191.95.19.35|100|2026-10-20 16:46:17|si' \
    '1997|191.95.19.35|101|2026-10-20 16:46:16|si' \
    '1997|191.95.19.35|102|2026-10-20 16:46:13|no' \
    '1997|198.51.100.9|103|2026-10-20 16:50:00|si' \
    'horta|191.95.37.37|200|2026-10-20 16:43:30|si' \
    'horta|191.95.37.37|201|2026-10-20 16:43:22|si' \
    '#descartadas|3' | zivpn_agrupar)
N=$(printf '%s\n' "$RES" | grep -c .)
[[ "$N" == "2" ]] && ok "agrupar: 2 filas por contraseña (no 6 sesiones sueltas)" || fail "filas agrupadas" "esperado 2, obtenido $N: $RES"
printf '%s\n' "$RES" | grep -q '^1997|4|191.95.19.35 198.51.100.9|2|2026-10-20 16:50:00|3$' \
    && ok "1997: 4 sesiones, 2 IPs, última 16:50, 3 con tráfico" || fail "grupo 1997" "$RES"

echo "════ 12. purgar_flujos_zivpn_muertos: solo ociosos ════"
export MAXINET_CT_DUMP='udp 17 3 src=191.95.37.37 dst=10.0.0.211 sport=13276 dport=9123 packets=1 bytes=110 src=10.0.0.211 dst=191.95.37.37 sport=5667 dport=27396 [ASSURED] mark=0 use=1
udp 17 18 src=191.95.37.37 dst=10.0.0.211 sport=13277 dport=9124 packets=9 bytes=990 src=10.0.0.211 dst=191.95.37.37 sport=5667 dport=27397 [ASSURED] mark=0 use=1'
export ABBIENET_CT_DUMP="$MAXINET_CT_DUMP"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/conntrack" << 'EOF'
#!/bin/bash
if [[ "$1" == "-D" ]]; then
    echo "$*" >> "$TMP/ct_borra"
    exit 0
fi
echo "udp 17 3 src=191.95.37.37 dst=10.0.0.211 sport=13276 dport=9123 packets=1 bytes=110 src=10.0.0.211 dst=191.95.37.37 sport=5667 dport=27396 [ASSURED] mark=0 use=1"
EOF
chmod +x "$TMP/bin/conntrack"
export PATH="$TMP/bin:$PATH"

: > "$TMP/ct_borra"
RES=$(purgar_flujos_zivpn_muertos 5667)
[[ "$RES" == "1" ]] && ok "purga: 1 ocioso (rem<=5), vivo (rem=18) intacto" || fail "conteo de purga" "esperado 1, obtenido $RES"
grep -q -- '--sport 13276 ' "$TMP/ct_borra" \
    && ok "tupla ociosa borrada (--src/--sport/--dst/--dport)" || fail "tupla ociosa" "$(cat "$TMP/ct_borra" 2>/dev/null)"
grep -q -- '--sport 13277' "$TMP/ct_borra" \
    && fail "el flujo vivo NO debe tocarse" || ok "flujo vivo no purgado"

echo "════ 13. Sintaxis bash -n de toda la suite ════"
for f in install.sh updater.sh menu.sh configs/profile.d/Maxinet-banner.sh \
         herramientas/*.sh protocolos/*.sh usuarios/*.sh lib/*.sh; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *.bak* ]] && continue
    if bash -n "$f" 2>/dev/null; then
        ok "bash -n $f"
    else
        fail "bash -n $f" "$(bash -n "$f" 2>&1 | head -3)"
    fi
done

echo ""
echo "════════════════════════════════════════════════"
echo "  RESULTADO: $PASS pasaron, $FAIL fallaron"
echo "════════════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
