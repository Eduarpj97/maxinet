#!/bin/bash
#==================================================
# Maxinet Network Premium v2.8
# ZiVPN UDP Manager (Enlace al gestor unificado)
#==================================================

BASE="/etc/maxinet"
exec bash "$BASE/protocolos/zipvpn.sh" "$@"
