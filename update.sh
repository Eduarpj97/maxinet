#!/bin/bash
# =============================================================================
#  Maxinet Network — ACTUALIZADOR
#  ---------------------------------------------------------------------------
#  Actualizaciones libres: sin validación remota ni bloqueo.
#
#  DISTRIBUCIÓN VÍA TARBALL DEL REPOSITORIO (sin git clone):
#   📦 El código se descarga como tarball de GitHub (rama main).
#   🛡 Se valida la estructura del paquete ANTES de ejecutar nada.
#   💾 El instalador (--update) hace backup + preserva config/usuarios.
#
#  MOTOR DE INTEGRIDAD (heredado):
#   🧹 Repara automaticamente archivos con BOM invisible (causa "command not found")
#   🔍 Detecta errores de sintaxis en todos los .sh y reporta cuales estan rotos
#   🔐 Restaura permisos de ejecucion perdidos
#   📋 Verifica archivos criticos del panel (menus, libs, idiomas)
# =============================================================================

# ── i18n shim (auto) ───────────────────────────────
if ! declare -F trx >/dev/null 2>&1; then trx() { printf '%s' "$1"; }; fi
# ─────────────────────────────────────────────────────────
BASE="/etc/maxinet"
VERSION_FILE="$BASE/version.txt"
RAW_VER="https://raw.githubusercontent.com/Eduarpj97/maxinet/main/version.txt"
REPO_TARBALL="https://github.com/Eduarpj97/maxinet/archive/refs/heads/main.tar.gz"

# --yes / -y flag para auto-confirmar actualización (útil en cron/menu no interactivo)
FORCE_YES=0
case "${1:-}" in
    --yes|-y) FORCE_YES=1 ;;
    --check) FORCE_YES=0 ;;  # solo verifica, no actualiza
esac

RESET="${MV_R:-\e[0m}"; RED="${MV_RED:-\e[1;91m}"; GREEN="${MV_GRN:-\e[1;92m}"; GOLD="${MV_GLD:-\e[1;93m}"; CYAN="${MV_CYN:-\e[1;96m}"; WHITE="${MV_WHT:-\e[1;97m}"; GRAY="${MV_DIM:-\e[1;90m}"

# Versión local instalada
ver_local() {
    if [[ -f "$VERSION_FILE" ]]; then
        tr -d ' \n' < "$VERSION_FILE"
    else
        echo "0.0.0"
    fi
}

# Versión disponible en el repo remoto (vacío = sin conexión/repo sin version.txt)
# ✅ Usa la API de GitHub (sin caché CDN) y fallback a raw/jsDelivr
ver_remota() {
    local V TMP="/tmp/Maxinet_ver"
    # Prioridad 1: API de GitHub - SIEMPRE fresca, sin cache CDN
    V=$(curl -fsSL --max-time 8 "https://api.github.com/repos/Eduarpj97/maxinet/contents/version.txt" 2>/dev/null \
        | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4 | base64 -d 2>/dev/null | tr -d ' \n')
    [[ -n "$V" ]] && { echo "$V"; return 0; }
    # Prioridad 2: raw.githubusercontent
    V=$(curl -fsSL --max-time 8 "$RAW_VER" 2>/dev/null | tr -d ' \n')
    [[ -n "$V" ]] && { echo "$V"; return 0; }
    # Prioridad 3: jsDelivr CDN
    V=$(curl -fsSL --max-time 8 "https://cdn.jsdelivr.net/gh/Eduarpj97/maxinet@main/version.txt" 2>/dev/null | tr -d ' \n')
    echo "$V"
}

hay_actualizacion() {
    local l r
    l=$(ver_local); r=$(ver_remota)
    [[ -z "$r" ]] && return 1
    local l1 l2 l3 r1 r2 r3
    IFS='.' read -r l1 l2 l3 <<< "$l"
    IFS='.' read -r r1 r2 r3 <<< "$r"
    l1=${l1:-0}; l2=${l2:-0}; l3=${l3:-0}
    r1=${r1:-0}; r2=${r2:-0}; r3=${r3:-0}
    if (( r1 > l1 )); then return 0; fi
    if (( r1 == l1 && r2 > l2 )); then return 0; fi
    if (( r1 == l1 && r2 == l2 && r3 > l3 )); then return 0; fi
    return 1
}

# =============================================================================
# 🧹 MOTOR DE INTEGRIDAD — repara archivos danados SIN reinstalar nada
# =============================================================================
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

verificar_integridad() {
    mkdir -p "$BASE/logs" "$INTEG_DIR"
    local total=0 boms=0 roto=0 perms=0 criticos=0 f
    local detalles=""

    # 1) Escanear todos los .sh legibles (los PACKED son binarios protegidos)
    while IFS= read -r f; do
        head -c 20 "$f" 2>/dev/null | grep -q "MAXINET-PACKED" && continue
        total=$((total+1))
        if reparar_bom "$f"; then
            boms=$((boms+1))
            detalles+="  ${GREEN}🧹 Reparado${RESET} BOM invisible: ${GRAY}${f#$BASE/}${RESET}\n"
        fi
        if ! bash -n "$f" >/dev/null 2>&1; then
            roto=$((roto+1))
            detalles+="  ${RED}⚠ ROTO${RESET} sintaxis invalida: ${GRAY}${f#$BASE/}${RESET}\n"
        fi
        if [[ ! -x "$f" ]]; then
            chmod +x "$f"; perms=$((perms+1))
        fi
    done < <(find "$BASE" -maxdepth 3 -name "*.sh" ! -path "$BASE/logs/*" ! -path "$BASE/.pack-backup/*" 2>/dev/null | sort)

    # 2) Archivos criticos que deben existir SIEMPRE
    local crit
    for crit in menu.sh update.sh updater.sh usuarios/menu.sh herramientas/menu.sh protocolos/menu.sh \
                lib/nav.sh lib/ui.sh languages/lang.sh languages/es.sh; do
        if [[ ! -f "$BASE/$crit" ]]; then
            criticos=$((criticos+1))
            detalles+="  ${RED}✗ FALTA${RESET} archivo critico: ${GRAY}$crit${RESET} (actualice para restaurarlo)\n"
        fi
    done

    # 3) Reporte
    echo -e "${CYAN}  ── SALUD DEL SISTEMA ─────────────────────────────${RESET}"
    echo -e "  Scripts revisados : ${WHITE}$total${RESET}   BOM reparados: ${GREEN}$boms${RESET}   Rotos: $([[ $roto -eq 0 ]] && echo -ne "${GREEN}" || echo -ne "${RED}")$roto${RESET}   Permisos fijados: ${GREEN}$perms${RESET}"
    if [[ $criticos -gt 0 ]]; then
        echo -e "  Criticos faltantes: ${RED}$criticos${RESET}"
    fi
    if [[ -n "$detalles" ]]; then
        echo -e "$detalles"
    elif [[ $boms -eq 0 && $roto -eq 0 && $criticos -eq 0 ]]; then
        echo -e "  ${GREEN}  ✅ Todos los archivos estan sanos.${RESET}"
    fi
    echo ""

    rm -rf "$INTEG_DIR"

    # codigo de salida: 0=sano 1=hubo problemas
    [[ $roto -eq 0 && $criticos -eq 0 ]] && return 0
    return 1
}

# =============================================================================
# DESCARGA DEL PAQUETE (tarball del repositorio)
#   Deja el árbol extraído en $MAXINET_PKG_DIR
#   Devuelve: 0 = OK · 1 = error de descarga · 2 = paquete inválido
# =============================================================================
MAXINET_PKG_DIR=""

descargar_paquete() {
    local TGZ="/tmp/maxinet-src-$$.tar.gz"
    local DEST="/tmp/maxinet-src-$$"
    rm -rf "$TGZ" "$DEST"
    MAXINET_PKG_DIR=""

    echo -e "${CYAN}  ⬇ Descargando paquete desde GitHub...${RESET}"
    curl -fL --max-time 240 --retry 3 -o "$TGZ" "$REPO_TARBALL" 2>/dev/null || {
        echo -e "${RED}  ❌ Error al descargar el paquete del repositorio.${RESET}"
        echo -e "${GRAY}  Verifica la conexión: $REPO_TARBALL${RESET}"
        rm -rf "$TGZ"
        return 1
    }

    mkdir -p "$DEST"
    if ! tar -xzf "$TGZ" -C "$DEST" 2>/dev/null; then
        echo -e "${RED}  ❌ Paquete corrupto — no se pudo extraer.${RESET}"
        rm -rf "$TGZ" "$DEST"
        return 2
    fi
    rm -f "$TGZ"

    local ROOT
    ROOT=$(find "$DEST" -maxdepth 2 -name install.sh -type f -printf '%h\n' 2>/dev/null | head -n1)
    if [[ -z "$ROOT" || ! -f "$ROOT/menu.sh" || ! -d "$ROOT/protocolos" ]]; then
        echo -e "${RED}  ❌ El paquete no tiene la estructura esperada.${RESET}"
        rm -rf "$DEST"
        return 2
    fi

    MAXINET_PKG_DIR="$ROOT"
    echo -e "${GREEN}  ✅ Paquete verificado${RESET}"
    return 0
}

# =============================================================================
# APLICAR LA ACTUALIZACIÓN — árbol del repo + instalador seguro
#   El instalador hace: backup → preserva config/usuarios → despliega
# =============================================================================
aplicar_update() {
    descargar_paquete || return 1

    echo -e "${GRAY}  ⚙ Aplicando actualización...${RESET}"
    MAXINET_SRC="$MAXINET_PKG_DIR" MAXINET_VERSION="$RV" bash "$MAXINET_PKG_DIR/install.sh" --update
    local RC=$?
    rm -rf "$(dirname "$MAXINET_PKG_DIR")" 2>/dev/null
    MAXINET_PKG_DIR=""
    if [[ $RC -ne 0 ]]; then
        echo -e "${RED}  ❌ El instalador reportó un error (código $RC).${RESET}"
        echo -e "${GRAY}  Puedes restaurar con el backup que el instalador dejó en $BASE/backups/${RESET}"
        return 1
    fi

    if [[ -f "$BASE/configs/profile.d/Maxinet-banner.sh" ]]; then
        cp -f "$BASE/configs/profile.d/Maxinet-banner.sh" /etc/profile.d/Maxinet-banner.sh 2>/dev/null
        chmod +x /etc/profile.d/Maxinet-banner.sh 2>/dev/null
    fi

    echo -e "${GREEN}  ✅ Actualizacion completada.${RESET}"
    echo ""
    verificar_integridad
    return 0
}

# =============================================================================
# MODOS NO INTERACTIVOS (para cron/monitoreo/pruebas)
#   --integridad : solo escanea y repara, sin preguntar nada
# =============================================================================
MODO="${1:-}"
if [[ "$MODO" == "--integridad" || "$MODO" == "--check" ]]; then
    verificar_integridad
    exit $?
fi

# =============================================================================
# MAIN
# =============================================================================
[[ -f "$BASE/lib/ui.sh" ]] && source "$BASE/lib/ui.sh" 2>/dev/null || true

echo ""
if declare -F mv_header >/dev/null 2>&1; then
    mv_header "🔄 MAXINET NETWORK — ACTUALIZADOR" "Verificación e integridad del sistema" "v$(ver_local)"
else
    echo -e "${GOLD}  ╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${GOLD}  ║${WHITE}   🔄 MAXINET NETWORK — ACTUALIZADOR              ${GOLD}║${RESET}"
    echo -e "${GOLD}  ╚══════════════════════════════════════════════════╝${RESET}"
fi
echo ""

LV=$(ver_local)
RV=$(ver_remota)


if [[ -z "$RV" ]]; then
    echo -e "${GRAY}  (no se pudo consultar el servidor de actualizaciones)${RESET}"
    echo -e "  Versión local: ${WHITE}v$LV${RESET}"
    verificar_integridad
    echo -e "  ${GRAY}Reintenta más tarde. El panel sigue funcionando normal.${RESET}"
elif ! hay_actualizacion; then
    echo -e "  Versión local : ${WHITE}v$LV${RESET}"
    echo -e "  Versión actual: ${WHITE}v$RV${RESET}"
    echo -e "  ${GREEN}  ✅ Ya tienes la última versión instalada.${RESET}"
    echo ""
    verificar_integridad
    echo -e "  ${GRAY}El panel sigue funcionando normal.${RESET}"
    echo ""
    read -n1 -r -p "$(trx '  Presiona ENTER para volver...')"
    exec "$BASE/menu.sh"
else
    echo -e "  Versión local : ${WHITE}v$LV${RESET}"
    echo -e "  Disponible    : ${GOLD}v$RV${RESET}"
    echo ""
    echo -e "  ${WHITE}  Puedes actualizar cuando quieras.${RESET}"
    echo ""
    if [[ $FORCE_YES -eq 1 ]]; then
        CONFIRMA="s"
    else
        read -rp "$(echo -e "${CYAN}  ¿Deseas actualizar ahora? [s/N] › ${RESET}")" CONFIRMA
    fi
    case "${CONFIRMA,,}" in
        s|si|sí|y|yes)
            aplicar_update
            echo ""
            if [[ $FORCE_YES -eq 0 ]]; then
                read -n1 -r -p "$(trx '  Presiona ENTER para continuar...')"
            fi
            exec "$BASE/menu.sh"
        ;;
        *)
            echo -e "  ${GOLD}  ⏭ Omitido. Puedes actualizar luego desde el menú 🛠 [09] Update.${RESET}"
            echo -e "  ${GRAY}  El panel sigue funcionando normal.${RESET}"
            echo ""
            if [[ $FORCE_YES -eq 0 ]]; then
                read -n1 -r -p "$(trx '  Presiona ENTER para volver...')"
            fi
            exec "$BASE/menu.sh"
        ;;
    esac
fi
