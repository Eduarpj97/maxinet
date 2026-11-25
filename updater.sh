#!/bin/bash

#=========================================================
#   MAXINET NETWORK — ACTUALIZADOR
#   Actualiza desde el tarball del repositorio (sin git clone)
#   ✅ Paquete validado antes de ejecutar el instalador
#   💾 El instalador preserva config/usuarios ZipVPN+Xray
#=========================================================

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"
COMMIT_HASH_FILE="$BASE/.last_commit_hash"
RAW_VER="https://raw.githubusercontent.com/Eduarpj97/maxinet/main/version.txt"
REPO_TARBALL="https://github.com/Eduarpj97/maxinet/archive/refs/heads/main.tar.gz"

FORCE_UPDATE=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE_UPDATE=1 ;;
    esac
done

# Cargar idiomas y Design System Nebula
if [[ -f "$BASE/languages/lang.sh" ]]; then
    source "$BASE/languages/lang.sh"
    load_language "$(get_current_language)"
fi
[[ -f "$BASE/lib/ui.sh" ]] && source "$BASE/lib/ui.sh" 2>/dev/null || true

RESET="${MV_R:-\e[0m}"; RED="${MV_RED:-\e[1;91m}"; GREEN="${MV_GRN:-\e[1;92m}"; GOLD="${MV_GLD:-\e[1;93m}"
BLUE="${MV_BLU:-\e[1;94m}"; MAGENTA="${MV_MAG:-\e[1;95m}"; CYAN="${MV_CYN:-\e[1;96m}"; WHITE="${MV_WHT:-\e[1;97m}"; GRAY="${MV_DIM:-\e[1;90m}"

_upd_header() {
    local cur_ver
    cur_ver="$(tr -d ' \r\n' < "$BASE/version.txt" 2>/dev/null || echo "3.1.5")"
    if declare -F mv_header >/dev/null 2>&1; then
        mv_header "🛡️  MAXINET NETWORK · ACTUALIZADOR" "maxinet-network.web.app" "v${cur_ver}"
    else
        echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
        echo -e "  ${GOLD}🛡️  Maxinet Network${RESET}  ${WHITE}ACTUALIZADOR v${cur_ver}${RESET}"
        echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
    fi
}

_upd_box_err() {
    local msg="$1"
    echo ""
    if declare -F mv_panel_top >/dev/null 2>&1; then
        mv_panel_top "ERROR DE ACTUALIZACIÓN"
        mv_prow "✗" "Estado" "$msg"
        mv_panel_bot
    else
        echo -e "  ${RED}✗ ${msg}${RESET}"
    fi
}

SCRIPTS_DIR="/etc/maxinet"
BACKUP_DIR="$BASE/backups/$(date +%Y%m%d_%H%M%S)"
TEMP_DIR="/tmp/maxinet-update-$$"

clear
_upd_header
echo ""

#==============================
# [1] VERIFICAR CONEXIÓN
#==============================

echo -e "  ${GOLD}[1/6]${RESET} ${WHITE}Verificando conexión...${RESET}"
if ! curl -fsSL --max-time 5 https://github.com &>/dev/null; then
    _upd_box_err "Sin conexión a internet"
    exit 1
fi
echo -e "        ${GREEN}✓ Conexión establecida${RESET}"

#==============================
# [2] VERIFICAR VERSIÓN
#==============================

echo -e "  ${GOLD}[2/6]${RESET} ${WHITE}Verificando versión...${RESET}"

LOCAL_VER=$(tr -d ' \r\n' < "$BASE/version.txt" 2>/dev/null || echo "0")
REMOTE_VER=$(curl -fsSL --max-time 5 "$RAW_VER" 2>/dev/null | tr -d ' \r\n')
[[ -z "$REMOTE_VER" ]] && REMOTE_VER=$(curl -fsSL --max-time 8 "https://api.github.com/repos/Eduarpj97/maxinet/contents/version.txt" 2>/dev/null \
    | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 | base64 -d 2>/dev/null | tr -d ' \r\n')

if [[ -z "$REMOTE_VER" ]]; then
    _upd_box_err "No se pudo verificar versión remota"
    exit 1
fi

if [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
    if [[ "$FORCE_UPDATE" -eq 1 ]]; then
        echo -e "        ${GOLD}⚡ Modo forzado: v${LOCAL_VER} (reinstalando)${RESET}"
    else
        echo -e "        ${GREEN}✓ v${LOCAL_VER} — Misma versión en servidor${RESET}"
        echo ""
        read -rp "$(echo -e "${CYAN}  ¿Deseas forzar la reinstalación con los últimos cambios de GitHub? [s/N]: ${RESET}")" FORZAR
        if [[ ! "$FORZAR" =~ ^[sS]$ ]]; then
            echo ""
            read -rp "$(echo -e "${CYAN}  Enter para volver${RESET}")" _
            exec bash "$BASE/menu.sh"
        fi
        echo -e "        ${GOLD}⚡ Forzando actualización con GitHub...${RESET}"
    fi
fi

echo -e "        ${WHITE}Local: ${GOLD}v${LOCAL_VER}${RESET}  →  Remota: ${GREEN}v${REMOTE_VER}${RESET}"

#==============================
# [3] RESPALDAR
#==============================

echo -e "  ${GOLD}[3/6]${RESET} ${WHITE}Respaldando scripts...${RESET}"

mkdir -p "$BACKUP_DIR"
cp -r "$SCRIPTS_DIR"/* "$BACKUP_DIR/" 2>/dev/null
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
echo -e "        ${GREEN}✓ Respaldo (${BACKUP_SIZE:-?})${RESET}"

# Retención: mantener SOLO los 3 respaldos más recientes (evita llenar disco)
ls -1dt "$SCRIPTS_DIR"/backups/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf 2>/dev/null
BK_KEPT=$(ls -1dt "$SCRIPTS_DIR"/backups/*/ 2>/dev/null | wc -l)
[[ "$BK_KEPT" -gt 0 ]] && echo -e "        ${GRAY}🧹 Retención de respaldos: ${BK_KEPT}/3${RESET}"

#==============================
# [4] DESCARGAR (tarball del repositorio)
#==============================

echo -e "  ${GOLD}[4/6]${RESET} ${WHITE}Descargando v${GREEN}${REMOTE_VER}${WHITE}...${RESET}"

rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

curl -fL --max-time 240 --retry 3 -o "$TEMP_DIR/src.tar.gz" "$REPO_TARBALL" 2>/dev/null
if [[ $? -ne 0 ]]; then
    echo -e "        ${RED}✗ Error descargando el paquete${RESET}"
    echo -e "        ${GRAY}Restaurando respaldo...${RESET}"
    cp -r "$BACKUP_DIR"/* "$SCRIPTS_DIR/" 2>/dev/null
    rm -rf "$TEMP_DIR"
    exit 1
fi

tar -xzf "$TEMP_DIR/src.tar.gz" -C "$TEMP_DIR" 2>/dev/null
PKG_DIR=$(find "$TEMP_DIR" -maxdepth 2 -name install.sh -type f -printf '%h\n' 2>/dev/null | head -n1)
if [[ -z "$PKG_DIR" || ! -f "$PKG_DIR/menu.sh" || ! -d "$PKG_DIR/protocolos" ]]; then
    echo -e "        ${RED}✗ Paquete inválido — actualización cancelada${RESET}"
    echo -e "        ${GRAY}Restaurando respaldo...${RESET}"
    cp -r "$BACKUP_DIR"/* "$SCRIPTS_DIR/" 2>/dev/null
    rm -rf "$TEMP_DIR"
    exit 1
fi
rm -f "$TEMP_DIR/src.tar.gz"
echo -e "        ${GREEN}✓ Paquete descargado y verificado${RESET}"

#==============================
# [5] ACTUALIZAR (instalador preserva datos)
#==============================

echo -e "  ${GOLD}[5/6]${RESET} ${WHITE}Actualizando...${RESET}"

UPDATED=1
MAXINET_SRC="$PKG_DIR" MAXINET_VERSION="$REMOTE_VER" bash "$PKG_DIR/install.sh" --update
RC=$?
rm -rf "$TEMP_DIR"

if [[ $RC -ne 0 ]]; then
    echo -e "        ${RED}✗ Instalador reportó error ($RC)${RESET}"
    echo -e "        ${GRAY}Restaurando respaldo...${RESET}"
    cp -r "$BACKUP_DIR"/* "$SCRIPTS_DIR/" 2>/dev/null
    exit 1
fi

# Fix CRLF from Windows — TODOS los .sh del sistema
find "$SCRIPTS_DIR" -name "*.sh" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null
find "$SCRIPTS_DIR/herramientas" -name "*.sh" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null

echo -e "        ${GREEN}✓ Instalador aplicado (v${REMOTE_VER})${RESET}"

if [[ -f "$BASE/configs/profile.d/Maxinet-banner.sh" ]]; then
    cp -f "$BASE/configs/profile.d/Maxinet-banner.sh" /etc/profile.d/Maxinet-banner.sh 2>/dev/null
    chmod +x /etc/profile.d/Maxinet-banner.sh 2>/dev/null
fi

#==============================
# [6] IPTABLES GAMING
#==============================

echo -e "  ${GOLD}[6/6]${RESET} ${WHITE}Configurando iptables gaming...${RESET}"

IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
[[ -z "$IFACE" ]] && IFACE=$(ls /sys/class/net 2>/dev/null | grep -E '^(eth|ens|enp)' | head -n1)
IFACE="${IFACE:-eth0}"

DSCP_COUNT=0
for RULE in "7000:7999" "3478:3480" "8000:9000"; do
    if ! iptables -t mangle -C PREROUTING -p udp --dport "$RULE" -j DSCP --set-dscp-class af41 2>/dev/null; then
        iptables -t mangle -A PREROUTING -p udp --dport "$RULE" -j DSCP --set-dscp-class af41
        DSCP_COUNT=$((DSCP_COUNT + 1))
    fi
done

iptables -N MAXINET_OUT >/dev/null 2>&1
iptables -C OUTPUT -j MAXINET_OUT >/dev/null 2>&1 || iptables -I OUTPUT 1 -j MAXINET_OUT

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

echo -e "        ${GREEN}✓ iptables configurado${RESET}"

#==============================
# RESUMEN (100% alineado y centrado)
#==============================

rm -rf "$TEMP_DIR"
echo ""
if declare -F mv_panel_top >/dev/null 2>&1; then
    mv_panel_top "ACTUALIZACIÓN COMPLETADA"
    mv_prow "✓" "Estado" "Actualizado con éxito"
    mv_prow "🏷" "Versión" "v${LOCAL_VER} → v${REMOTE_VER}"
    mv_prow "🌐" "Origen" "GitHub · rama main"
    mv_prow "💾" "Respaldo" "${BACKUP_SIZE:-?}"
    mv_panel_bot
else
    echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
    echo -e "  ${GREEN}✓ ACTUALIZACIÓN COMPLETADA${RESET}  (v${LOCAL_VER} → v${REMOTE_VER})"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${RESET}"
fi

echo ""
echo -e "  ${GRAY}Restaurar:${RESET} ${WHITE}cp -r ${BACKUP_DIR}/* /etc/maxinet/${RESET}"
echo ""
read -rp "$(echo -e "${CYAN}  Enter para volver${RESET}")" _
exec bash "$BASE/menu.sh"
