#!/bin/bash

#=========================================================
#   MAXINET NETWORK — AUTO-UPDATE CHECKER
#   Verifica actualizaciones periodicamente
#   Instala silenciosamente en background
#
#   DISTRIBUCIÓN VÍA TARBALL DEL REPOSITORIO (SIN git clone):
#   📦 El código se descarga como tarball de GitHub (rama main).
#   🛡 Se valida la estructura del paquete ANTES de ejecutar nada.
#   💾 El instalador (--update) hace backup + preserva config/usuarios.
#   ⚠ Si el repositorio no responde → no descarga, loguea y sale limpio.
#
#   MOTOR DE INTEGRIDAD (heredado):
#   🧹 Repara BOM invisible en cada ejecucion (sin reinstalar)
#   🔍 Detecta errores de sintaxis y los registra
#=========================================================

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
LOG="$BASE/logs/auto-update.log"
LOCK="/tmp/maxinet_autoupdate.lock"
VERSION_FILE="$BASE/version.txt"
RAW_VER="https://raw.githubusercontent.com/Eduarpj97/maxinet/main/version.txt"
REPO_TARBALL="https://github.com/Eduarpj97/maxinet/archive/refs/heads/main.tar.gz"

# Evitar ejecuciones duplicadas
[[ -f "$LOCK" ]] && { AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) )); [[ $AGE -lt 3600 ]] && exit 0; }
echo $$ > "$LOCK"
trap "rm -f '$LOCK'" EXIT

mkdir -p "$BASE/logs" "$BASE/backups"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

log "=== Auto-update check iniciado ==="

#==============================
# VERSIONES
#==============================

LOCAL_VER=$(tr -d ' \n' < "$VERSION_FILE" 2>/dev/null || echo "0")
REMOTE_VER=$(curl -fsSL --max-time 5 "$RAW_VER" 2>/dev/null | tr -d ' \n')
[[ -z "$REMOTE_VER" ]] && REMOTE_VER=$(curl -fsSL --max-time 8 "https://api.github.com/repos/Eduarpj97/maxinet/contents/version.txt" 2>/dev/null \
    | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 | base64 -d 2>/dev/null | tr -d ' \n')

if [[ -z "$REMOTE_VER" ]]; then
    log "No se pudo obtener versión remota"
    exit 0
fi

if [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
    log "Ya actualizado (v${LOCAL_VER})"
    exit 0
fi

# Orden semántico simple
l1=${LOCAL_VER%%.*}; r1=${REMOTE_VER%%.*}
if [[ $r1 -lt $l1 ]]; then
    log "Remota (${REMOTE_VER}) anterior a local (${LOCAL_VER}) — ignorando"
    exit 0
fi

log "Nueva versión: v${LOCAL_VER} → v${REMOTE_VER}"

#==============================
# 🧹 MOTOR DE INTEGRIDAD (pre-chequeo rápido)
#==============================
INTEG_DIR="/tmp/maxinet_integ_$$"

reparar_bom() {
    local f="$1"
    [ "$(od -A n -t x1 -N 3 "$f" 2>/dev/null | tr -d ' \n')" = "efbbbf" ] || return 1
    local perms
    perms=$(stat -c%a "$f" 2>/dev/null || echo 755)
    local tmp="$INTEG_DIR/bom.tmp"
    mkdir -p "$INTEG_DIR"
    tail -c +4 "$f" > "$tmp"
    sed -i '/./,$!d' "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
    chmod "$perms" "$f"
    return 0
}

#==============================
# DESCARGAR PAQUETE (tarball del repositorio)
#==============================

TEMP_DIR="/tmp/maxinet_autoupdate_$$"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

curl -fL --max-time 240 --retry 3 -o "$TEMP_DIR/src.tar.gz" "$REPO_TARBALL" 2>/dev/null
if [[ $? -ne 0 ]]; then
    log "Error al descargar el paquete del repositorio"
    rm -rf "$TEMP_DIR"
    exit 1
fi

tar -xzf "$TEMP_DIR/src.tar.gz" -C "$TEMP_DIR" 2>/dev/null || {
    log "Paquete corrupto — no se pudo extraer"
    rm -rf "$TEMP_DIR"
    exit 1
}
rm -f "$TEMP_DIR/src.tar.gz"

PKG_DIR=$(find "$TEMP_DIR" -maxdepth 2 -name install.sh -type f -printf '%h\n' 2>/dev/null | head -n1)
if [[ -z "$PKG_DIR" || ! -f "$PKG_DIR/menu.sh" || ! -d "$PKG_DIR/protocolos" ]]; then
    log "Estructura del paquete inesperada — abortando"
    rm -rf "$TEMP_DIR"
    exit 1
fi
log "Paquete descargado y verificado"

# Backup completo antes de tocar nada (sin logs ni backups previos)
BK="$BASE/backups/auto_$(date +%Y%m%d_%H%M%S).tar.gz"
tar czf "$BK" -C /etc --exclude='maxinet/logs' --exclude='maxinet/backups' maxinet 2>/dev/null
log "💾 Backup pre-actualizacion: $BK ($(du -h "$BK" 2>/dev/null | cut -f1))"

# Retención: mantener SOLO los 3 backups automáticos más recientes (evita llenar disco)
ls -1t "$BASE"/backups/auto_*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f 2>/dev/null
BK_KEPT=$(ls -1 "$BASE"/backups/auto_*.tar.gz 2>/dev/null | wc -l)
[[ "$BK_KEPT" -gt 0 ]] && log "🧹 Retención de backups automáticos: ${BK_KEPT}/3"

# Aplicar con el instalador (él preserva config/usuarios ZipVPN+Xray)
MAXINET_SRC="$PKG_DIR" MAXINET_VERSION="$REMOTE_VER" bash "$PKG_DIR/install.sh" --update >> "$LOG" 2>&1
RC=$?
rm -rf "$TEMP_DIR"

if [[ $RC -ne 0 ]]; then
    log "Instalador reportó error ($RC) — se conserva la instalación anterior"
    exit 1
fi

# Fix CRLF from Windows + verificacion final de integridad
find "$BASE" -name "*.sh" -type f ! -path "$BASE/backups/*" -exec sed -i 's/\r$//' {} + 2>/dev/null

# Tras actualizar, garantizar el cron de limpieza de cuentas V2Ray
# expiradas en VPS ya desplegados (sin necesidad de reinstalar).
if [[ -f "$BASE/protocolos/v2ray.sh" ]]; then
    bash "$BASE/protocolos/v2ray.sh" --ensure-cleanup 2>/dev/null || true
fi

# iptables gaming
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[[ -z "$IFACE" ]] && IFACE="eth0"

for RULE in "7000:7999" "3478:3480" "8000:9000"; do
    iptables -t mangle -C PREROUTING -p udp --dport "$RULE" -j DSCP --set-dscp-class af41 2>/dev/null || \
        iptables -t mangle -A PREROUTING -p udp --dport "$RULE" -j DSCP --set-dscp-class af41
done

iptables -N MAXINET_OUT >/dev/null 2>&1
iptables -C OUTPUT -j MAXINET_OUT >/dev/null 2>&1 || iptables -I OUTPUT 1 -j MAXINET_OUT
iptables-save > /etc/iptables/rules.v4 2>/dev/null

log "✅ Actualización completada: v${LOCAL_VER} → v${REMOTE_VER} (GitHub main)."