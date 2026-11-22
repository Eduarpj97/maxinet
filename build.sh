#!/usr/bin/env bash
# build.sh — empaquetar release de Maxinet
# Uso: ./build.sh [version]
# Genera: maxinet-<version>.tar.gz (árbol limpio para instalación)

set -euo pipefail

VERSION="${1:-$(cat VERSION 2>/dev/null || echo '1.0.0')}"
NAME="maxinet-$VERSION"
OUT="maxinet-$VERSION.tar.gz"
TMP="/tmp/$NAME"

echo "=== Construyendo $OUT ==="

# Limpiar destino previo
rm -rf "$TMP"
mkdir -p "$TMP"

# Copiar árbol (excluir .git, backups, logs, activaciones, licencias, bots, gate, docs internos)
rsync -a --delete \
  --exclude='.git' \
  --exclude='.gitignore' \
  --exclude='backups/' \
  --exclude='logs/' \
  --exclude='activaciones/' \
  --exclude='licencia.conf*' \
  --exclude='gate/' \
  --exclude='backup/' \
  --exclude='.bot-state' \
  --exclude='.env-bot' \
  --exclude='.master-key' \
  --exclude='payload/pwd.pwd' \
  --exclude='tools/vps-*.sh' \
  --exclude='DEPLOY-v5.2.md' \
  --exclude='.current_lang' \
  --exclude='docs/maxinet-bootstrap-reference.sh' \
  --exclude='*.tar.gz' \
  . "$TMP/"

# Asegurar permisos de ejecución en launchers y scripts
find "$TMP" -name '*.sh' -type f -exec chmod +x {} \;
chmod +x "$TMP/launchers/"* 2>/dev/null || true
chmod +x "$TMP/install.sh" 2>/dev/null || true

# Crear tarball
tar -czf "$OUT" -C /tmp "$NAME"

# SHA256
sha256sum "$OUT" > "$OUT.sha256"

echo "=== OK ==="
ls -lh "$OUT" "$OUT.sha256"
echo ""
echo "Para publicar:"
echo "  gh release create v$VERSION $OUT $OUT.sha256 --title \"Maxinet v$VERSION\" --notes-file CHANGELOG.md"