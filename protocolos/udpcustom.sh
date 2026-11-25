#!/bin/bash

# ── i18n shim (auto) ───────────────────────────────
if ! declare -F trx >/dev/null 2>&1; then trx() { printf '%s' "$1"; }; fi
# ─────────────────────────────────────────────────────────

BASE="/etc/maxinet"
CONFIG="$BASE/config.conf"

[[ ! -f "$CONFIG" ]] && {
    echo "$(trx '❌ No existe configuración Maxinet')"
    exit 1
}

source "$CONFIG"


# Sistema de animación/progreso + detección de estado
[[ -f "$BASE/lib/anim.sh" ]] && source "$BASE/lib/anim.sh"

CYAN="${MV_CYN:-\e[1;96m}"
GREEN="${MV_GRN:-\e[1;92m}"
RED="${MV_RED:-\e[1;91m}"
WHITE="${MV_WHT:-\e[1;97m}"
RESET="${MV_R:-\e[0m}"


SERVICE="udp-custom"
# Puertos de llegada/salida: 36712 UDP estático
PORT="36712"
BIN="/usr/bin/udp"
CONFIG_UDP="/usr/bin/config.json"


set_udp_status(){

if systemctl is-active --quiet "$SERVICE"; then
    STATUS="${GREEN}🟢 ACTIVO${RESET}"
else
    STATUS="${RED}🔴 DETENIDO${RESET}"
fi

}


install_udp(){

clear
mv_brand_header "INSTALANDO UDP CUSTOM"
anim_init 5
anim_step "Instalando dependencias"
anim_run "apt update" apt update -y
anim_run "Instalar paquetes base" apt install -y curl wget iptables libpam0g


anim_step "Activando IP Forward y DNAT"

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1
sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

DEV=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
[[ -z "$DEV" ]] && DEV=$(ip link show up 2>/dev/null | awk -F': ' '/state UP/ && $2!="lo"{print $2;exit}')
DEV="${DEV:-eth0}"

# Limpiar reglas PREROUTING previas hacia 2100/36712/5667
iptables -t nat -S PREROUTING 2>/dev/null | grep -E "DNAT.*:(2100|36712|5667)" | sed 's/^-A/-D/' | while read -r rule; do
    iptables -t nat $rule 2>/dev/null || true
done

# 1. Excepción ESTABLISHED,RELATED (evita secuestrar respuestas DNS/QUIC)
iptables -t nat -C PREROUTING -p udp -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -t nat -I PREROUTING 1 -p udp -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

# 2. ZiVPN Port-Hopping 6000:19999 -> 5667
iptables -t nat -A PREROUTING -p udp -m udp --dport 6000:19999 -j DNAT --to-destination :5667 2>/dev/null

# 3. DNAT UDP Custom -> 36712 (excluyendo puertos dedicados)
for _rng in 1:89 91:108 110:142 144:5666 5668:7099 7301:9899 9901:36711 36713:65535; do
    iptables -t nat -A PREROUTING -i "$DEV" -p udp -m udp --dport "$_rng" -j DNAT --to-destination :36712 2>/dev/null
done

iptables -C INPUT -p udp --dport 36712 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 36712 -j ACCEPT 2>/dev/null
iptables -t nat -C POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$DEV" -j MASQUERADE 2>/dev/null
netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

ARCH=$(uname -m)

case "$ARCH" in
x86_64)
URL="https://raw.githubusercontent.com/http-custom/udp-custom/main/bin/udp-custom-linux-amd64"
;;
aarch64|arm64)
URL="https://raw.githubusercontent.com/prjkt-nv404/UDP-Custom-Installer-arm64/main/udpc-arm64"
;;
*)
echo "❌ Arquitectura no soportada: $ARCH"
return
;;
esac

mkdir -p /root/udp /etc/UDPCustom 2>/dev/null
anim_step "Descargando UDP (${ARCH})"

if ! anim_run "Descargar binario" curl -L -s -f "$URL" -o "/root/udp/udp-custom"; then
    :
fi

if [[ ! -f "/root/udp/udp-custom" || $(wc -c < "/root/udp/udp-custom" 2>/dev/null || echo 0) -lt 1000000 ]]; then
    echo "$(trx '❌ Error descargando UDP')"
    return
fi

chmod +x /root/udp/udp-custom
cp -f /root/udp/udp-custom /usr/local/bin/udp-custom 2>/dev/null
cp -f /root/udp/udp-custom "$BIN" 2>/dev/null
chmod +x /usr/local/bin/udp-custom "$BIN" 2>/dev/null

anim_step "Creando configuración"

cat > /root/udp/config.json <<EOF
{
    "listen": ":36712",
    "stream_buffer": 33554432,
    "receive_buffer": 83886080,
    "auth": {
        "mode": "passwords"
    }
}
EOF
cp -f /root/udp/config.json /etc/UDPCustom/config.json 2>/dev/null
cp -f /root/udp/config.json "$CONFIG_UDP" 2>/dev/null

anim_step "Creando servicio"

cat > /etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=Maxinet UDP Custom Service (HTTP Custom) [ Puerto 36712 ]
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/udp
ExecStart=/root/udp/udp-custom server -exclude 22,53,80,443,90,109,143,5667,7100,7200,7300,9900 --config /root/udp/config.json
Restart=always
RestartSec=1s
Nice=-20
LimitNOFILE=1048576
LimitNPROC=512000
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF


anim_step "Iniciando servicio"
anim_run "daemon-reload" systemctl daemon-reload
anim_run "Habilitar en arranque" systemctl enable "$SERVICE"
svc_restart_anim "$SERVICE" "Arrancando UDP Custom"



if systemctl is-active --quiet "$SERVICE"; then

# Clave consistente UDP_CUSTOM= con dedupe (evita duplicados
# generados por claves viejas UDPCUSTOM= sin guion).
sed -i '/^UDP_CUSTOM=/d;/^UDPCUSTOM=/d' "$CONFIG"

echo "UDP_CUSTOM=ON" >> "$CONFIG"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$(trx '✅ UDP CUSTOM INSTALADO')"
echo "Puerto: $PORT"
echo ""
echo "$(trx '📌 Para asignar puertos a usuarios')"
echo "$(trx '   usar el formato: 1-PUERTO')"
echo "$(trx '   Ejemplo: 1-36712')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

else

echo "$(trx '❌ UDP no inició')"
journalctl -u "$SERVICE" --no-pager -n 20

fi


sleep 3

}
remove_udp(){

clear

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$(trx '       🗑️ ELIMINAR UDP CUSTOM')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"


read -rp "$(trx '¿Eliminar UDP Custom? (s/n): ')" CONFIRM


if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then

echo "$(trx '❌ Cancelado')"
sleep 2
return

fi



echo "$(trx '⏳ Deteniendo servicio...')"

anim_init 3
anim_run "Detener y deshabilitar" bash -c "systemctl stop \"$SERVICE\" 2>/dev/null; systemctl disable \"$SERVICE\" 2>/dev/null"



anim_step "Eliminando archivos"

anim_run "Eliminar servicio y binarios" bash -c "rm -f \"/etc/systemd/system/$SERVICE.service\" \"$BIN\" \"$CONFIG_UDP\""



anim_run "daemon-reload" systemctl daemon-reload



echo "$(trx '🧹 Limpiando reglas temporales...')"


DEV=$(ip -4 route show default | awk '{print $5}' | head -1)



if [[ -n "$DEV" ]]; then


iptables -t nat -S PREROUTING 2>/dev/null \
| grep "36712" \
| sed 's/-A/-D/' \
| while read RULE
do
iptables -t nat $RULE 2>/dev/null
done



iptables -S INPUT 2>/dev/null \
| grep "36712" \
| sed 's/-A/-D/' \
| while read RULE
do
iptables $RULE 2>/dev/null
done


fi



sed -i '/^UDP_CUSTOM=/d;/^UDPCUSTOM=/d' "$CONFIG"

echo "UDP_CUSTOM=OFF" >> "$CONFIG"


echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$(trx '✅ UDP CUSTOM ELIMINADO')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"


sleep 3

}



restart_udp(){


clear


echo "$(trx '🔄 Reiniciando UDP Custom...')"


svc_restart_anim "$SERVICE" "Reiniciando UDP Custom"



sleep 2



if systemctl is-active --quiet "$SERVICE"; then

echo "$(trx '✅ Servicio activo')"

else

echo "$(trx '❌ No pudo iniciar')"

journalctl -u "$SERVICE" --no-pager -n 15

fi


sleep 3


}



status_udp(){


clear


echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$(trx '       📊 ESTADO UDP CUSTOM')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"


echo ""


systemctl status "$SERVICE" --no-pager



echo ""

echo "Puerto interno: $PORT"


echo ""

echo "$(trx 'Escuchando UDP:')"


ss -ulnp | grep ":$PORT"



echo ""

read -n1 -r -p "$(trx 'Presiona una tecla para continuar...')"

}
# Navegación con flechitas
[[ -f "$BASE/lib/nav.sh" ]] && source "$BASE/lib/nav.sh"

# ── CLI headless: bash udpcustom.sh --install
if [[ "${1:-}" == "--install" ]]; then
    install_udp
    exit $?
fi

while true
do

clear

source "$CONFIG"


set_udp_status

mv_header "🚀 UDP Custom Manager" "$(trx 'Túnel UDP · bajo consumo')" "v6.2"
maxinet_contacts 2>/dev/null || true

echo -e " Estado   : $STATUS"
echo -e " Puerto   : $PORT"
echo -e "$(trx ' Servicio : udp-custom')"

echo ""

if [[ "$UDP_CUSTOM" == "ON" ]]; then
    LBL=("Desinstalar UDP Custom" "Reiniciar Servicio" "Ver Estado")
else
    LBL=("Instalar UDP Custom")
fi
SEL=$(nav_pick "► Opción:" "${LBL[@]}" "↩ Regresar") || SEL=0
[[ $SEL -eq $((${#LBL[@]}+1)) ]] && SEL=0
OP="$SEL"



case "$OP" in


1)


if [[ "$UDP_CUSTOM" == "ON" ]]; then

remove_udp

else

install_udp

fi

;;



2)


if [[ "$UDP_CUSTOM" == "ON" ]]; then

restart_udp

else

echo "$(trx '❌ UDP Custom no está instalado')"

sleep 2

fi

;;



3)


if [[ "$UDP_CUSTOM" == "ON" ]]; then

status_udp

else

echo "$(trx '❌ UDP Custom no está instalado')"

sleep 2

fi

;;



0)


if [[ -f "$BASE/protocolos/menu.sh" ]]; then

exec bash "$BASE/protocolos/menu.sh"

else

clear

echo "$(trx '❌ Menú principal no encontrado')"

sleep 2

exit

fi

;;



*)

echo "$(trx '❌ Opción inválida')"

sleep 2

;;


esac


done
