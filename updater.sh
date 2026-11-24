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

# Cargar idiomas
if [[ -f "$BASE/languages/lang.sh" ]]; then
    source "$BASE/languages/lang.sh"
    load_language "$(get_current_language)"
fi

RESET="\e[0m"; RED="\e[1;91m"; GREEN="\e[1;92m"; GOLD="\e[1;93m"
BLUE="\e[1;94m"; MAGENTA="\e[1;95m"; CYAN="\e[1;96m"; WHITE="\e[1;97m"; GRAY="\e[1;90m"

W=58
TOP(){ printf "${CYAN}╔"; printf '═%.0s' $(seq 1 $W); printf "╗${RESET}\n"; }
MID(){ printf "${CYAN}╠"; printf '═%.0s' $(seq 1 $W); printf "╣${RESET}\n"; }
BOT(){ printf "${CYAN}╚"; printf '═%.0s' $(seq 1 $W); printf "╝${RESET}\n"; }
ROW(){ printf "${CYAN}║${RESET} %-56s${CYAN}║${RESET}\n" "$1"; }
ROWC(){ printf "${CYAN}║${RESET} %b%*s${CYAN}║${RESET}\n" "$1" $(( 56 - $(echo -ne "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -c) )) ""; }

SCRIPTS_DIR="/etc/maxinet"
BACKUP_DIR="$BASE/backups/$(date +%Y%m%d_%H%M%S)"
TEMP_DIR="/tmp/maxinet-update-$$"

clear
TOP
printf "${CYAN}║${RESET}  ${GOLD}🛡️  Maxinet Network${RESET}  ${WHITE}ACTUALIZADOR v${VERSION:-$(cat "$BASE/version.txt" 2>/dev/null || echo "3.1.3")}${RESET}${CYAN}           ║${RESET}\n"
printf "${CYAN}║${RESET}  ${GRAY}maxinet-network.web.app${RESET}  ${GRAY}·${RESET}  ${WHITE}Actualizador${RESET}${CYAN}                    ║${RESET}\n"
MID
echo ""


#==============================
# [1] VERIFICAR CONEXIÓN
#==============================

printf "${CYAN}║${RESET} ${GOLD}[1/6]${RESET} Verificando conexión...${CYAN}%*s║${RESET}\n" $(( W - 30 )) ""

if ! curl -fsSL --max-time 5 https://github.com &>/dev/null; then
    ROWC "${RED}✗ Sin conexión a internet${RESET}"
    BOT
    exit 1
fi
ROWC "${GREEN}✓ Conexión establecida${RESET}"

#==============================
# [2] VERIFICAR VERSIÓN
#==============================

printf "${CYAN}║${RESET} ${GOLD}[2/6]${RESET} Verificando versión...${CYAN}%*s║${RESET}\n" $(( W - 27 )) ""

LOCAL_VER=$(tr -d ' \n' < "$BASE/version.txt" 2>/dev/null || echo "0")
REMOTE_VER=$(curl -fsSL --max-time 5 "$RAW_VER" 2>/dev/null | tr -d ' \n')
[[ -z "$REMOTE_VER" ]] && REMOTE_VER=$(curl -fsSL --max-time 8 "https://api.github.com/repos/Eduarpj97/maxinet/contents/version.txt" 2>/dev/null \
    | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 | base64 -d 2>/dev/null | tr -d ' \n')

if [[ -z "$REMOTE_VER" ]]; then
    ROWC "${RED}✗ No se pudo verificar versión remota${RESET}"
    BOT
    exit 1
fi

if [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
    if [[ "$FORCE_UPDATE" -eq 1 ]]; then
        ROWC "${GOLD}⚡ Modo forzado: v${LOCAL_VER} (reinstalando)${RESET}"
    else
        ROWC "${GREEN}✓ v${LOCAL_VER} — Misma versión en servidor${RESET}"
        MID
        echo ""
        read -rp "$(echo -e "${CYAN}   ¿Deseas forzar la reinstalación con los últimos cambios de GitHub? [s/N]: ${RESET}")" FORZAR
        if [[ ! "$FORZAR" =~ ^[sS]$ ]]; then
            BOT
            echo ""
            read -rp "$(echo -e "${CYAN}   Enter para volver${RESET}")" _
            exec bash "$BASE/menu.sh"
        fi
        ROWC "${GOLD}⚡ Forzando actualización con GitHub...${RESET}"
    fi
fi

ROWC "${WHITE}Local: ${GOLD}v${LOCAL_VER}${RESET}  →  Remota: ${GREEN}v${REMOTE_VER}${RESET}"

#==============================
# [3] RESPALDAR
#==============================

printf "${CYAN}║${RESET} ${GOLD}[3/6]${RESET} Respaldando scripts...${CYAN}%*s║${RESET}\n" $(( W - 27 )) ""

mkdir -p "$BACKUP_DIR"
cp -r "$SCRIPTS_DIR"/* "$BACKUP_DIR/" 2>/dev/null
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
ROWC "${GREEN}✓ Respaldo (${BACKUP_SIZE:-?})${RESET}"

# Retención: mantener SOLO los 3 respaldos más recientes (evita llenar disco)
ls -1dt "$SCRIPTS_DIR"/backups/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf 2>/dev/null
BK_KEPT=$(ls -1dt "$SCRIPTS_DIR"/backups/*/ 2>/dev/null | wc -l)
[[ "$BK_KEPT" -gt 0 ]] && ROWC "${GRAY}🧹 Retención de respaldos: ${BK_KEPT}/3${RESET}"

#==============================
# [4] DESCARGAR (tarball del repositorio)
#==============================

printf "${CYAN}║${RESET} ${GOLD}[4/6]${RESET} Descargando v${GREEN}${REMOTE_VER}${RESET}...${CYAN}%*s║${RESET}\n" $(( W - 30 - ${#REMOTE_VER} )) ""

rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

curl -fL --max-time 240 --retry 3 -o "$TEMP_DIR/src.tar.gz" "$REPO_TARBALL" 2>/dev/null
if [[ $? -ne 0 ]]; then
    ROWC "${RED}✗ Error descargando el paquete${RESET}"
    ROWC "${GRAY}Restaurando respaldo...${RESET}"
    cp -r "$BACKUP_DIR"/* "$SCRIPTS_DIR/" 2>/dev/null
    rm -rf "$TEMP_DIR"
    BOT
    exit 1
fi

tar -xzf "$TEMP_DIR/src.tar.gz" -C "$TEMP_DIR" 2>/dev/null
PKG_DIR=$(find "$TEMP_DIR" -maxdepth 2 -name install.sh -type f -printf '%h\n' 2>/dev/null | head -n1)
if [[ -z "$PKG_DIR" || ! -f "$PKG_DIR/menu.sh" || ! -d "$PKG_DIR/protocolos" ]]; then
    ROWC "${RED}✗ Paquete inválido — actualización cancelada${RESET}"
    ROWC "${GRAY}Restaurando respaldo...${RESET}"
    cp -r "$BACKUP_DIR"/* "$SCRIPTS_DIR/" 2>/dev/null
    rm -rf "$TEMP_DIR"
    BOT
    exit 1
fi
rm -f "$TEMP_DIR/src.tar.gz"
ROWC "${GREEN}✓ Paquete descargado y verificado${RESET}"

#==============================
# [5] ACTUALIZAR (instalador preserva datos)
#==============================

printf "${CYAN}║${RESET} ${GOLD}[5/6]${RESET} Actualizando...${CYAN}%*s║${RESET}\n" $(( W - 21 )) ""

UPDATED=1
MAXINET_SRC="$PKG_DIR" MAXINET_VERSION="$REMOTE_VER" bash "$PKG_DIR/install.sh" --update
RC=$?
rm -rf "$TEMP_DIR"

if [[ $RC -ne 0 ]]; then
    ROWC "${RED}✗ Instalador reportó error ($RC)${RESET}"
    ROWC "${GRAY}Restaurando respaldo...${RESET}"
    cp -r "$BACKUP_DIR"/* "$SCRIPTS_DIR/" 2>/dev/null
    BOT
    exit 1
fi

# Fix CRLF from Windows — TODOS los .sh del sistema
find "$SCRIPTS_DIR" -name "*.sh" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null
find "$SCRIPTS_DIR/herramientas" -name "*.sh" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null

ROWC "${GREEN}✓ Instalador aplicado (v${REMOTE_VER})${RESET}"

#==============================
# [6] IPTABLES GAMING
#==============================

printf "${CYAN}║${RESET} ${GOLD}[6/6]${RESET} Configurando iptables gaming...${CYAN}%*s║${RESET}\n" $(( W - 33 )) ""

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

ROWC "${GREEN}✓ iptables configurado${RESET}"

#==============================
# RESUMEN
#==============================

rm -rf "$TEMP_DIR"

echo ""
MID
printf "${CYAN}║${RESET}                                                          ${CYAN}║${RESET}\n"
printf "${CYAN}║${RESET}  ${GREEN}✓ ACTUALIZACIÓN COMPLETADA${RESET}                            ${CYAN}║${RESET}\n"
printf "${CYAN}║${RESET}                                                          ${CYAN}║${RESET}\n"
printf "${CYAN}║${RESET}  ${GRAY}Versión:${RESET}  ${GOLD}v${LOCAL_VER}${RESET} → ${GREEN}v${REMOTE_VER}${RESET}${CYAN}%*s║${RESET}\n" $(( W - 23 - ${#LOCAL_VER} - ${#REMOTE_VER} )) ""
printf "${CYAN}║${RESET}  ${GRAY}Origen:${RESET}  ${WHITE}GitHub · rama main${RESET}${CYAN}%*s║${RESET}\n" $(( W - 25 )) ""
printf "${CYAN}║${RESET}  ${GRAY}Respaldo:${RESET} ${WHITE}${BACKUP_SIZE:-?}${RESET}${CYAN}%*s║${RESET}\n" $(( W - 17 - ${#BACKUP_SIZE} )) ""
printf "${CYAN}║${RESET}                                                          ${CYAN}║${RESET}\n"
MID
printf "${CYAN}║${RESET}  ${GRAY}Restaurar:${RESET} ${WHITE}cp -r ${BACKUP_DIR}/* /etc/maxinet/${RESET}${CYAN}%*s║${RESET}\n" $(( W - 8 - ${#BACKUP_DIR} )) ""
printf "${CYAN}║${RESET}                                                          ${CYAN}║${RESET}\n"
BOT

echo ""
read -rp "$(echo -e "${CYAN}   Enter para volver${RESET}")" _
exec bash "$BASE/menu.sh"