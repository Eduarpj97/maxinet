#!/bin/bash
# Maxinet OpenVPN — verificación usuario/contraseña
# Formato passwd: usuario:$1$salt$hash
# Soporta via-env (username/password) o legacy (args $1/$2)
USER="$1"
PASS="$2"
[ -z "$USER" ] && USER="${username:-}"
[ -z "$PASS" ] && PASS="${password:-}"
[ -z "$USER" ] && exit 1
[ -z "$PASS" ] && exit 1
HASH=$(grep "^${USER}:" /etc/openvpn/passwd 2>/dev/null | cut -d: -f2)
[ -z "$HASH" ] && exit 1
SALT=$(echo "$HASH" | cut -d'$' -f3)
[ -z "$SALT" ] && exit 1
COMPUTED=$(openssl passwd -1 -salt "$SALT" "$PASS" 2>/dev/null)
[ "$COMPUTED" = "$HASH" ] && exit 0
exit 1
