# Maxinet Network

Panel de gestión VPN todo-en-uno para servidores Linux (Ubuntu 20.04+/22.04+/24.04, Debian 11/12).

**Comando:** `mx` (también `menu`, `protocolos`, `herramientas`, `usuarios`)

---

## Instalación rápida

```bash
# Como root
bash <(curl -fsSL https://raw.githubusercontent.com/Eduarpj97/maxinet/main/install.sh)
```

O descarga y ejecuta localmente:

```bash
git clone https://github.com/Eduarpj97/maxinet.git
cd maxinet
sudo bash install.sh
```

---

## Requisitos

- Ubuntu 20.04 / 22.04 / 24.04 (x86_64 o ARM64)
- Debian 11 / 12
- Acceso root
- Conexión a Internet (para descargar dependencias)

---

## Protocolos incluidos

| Protocolo | Puertos por defecto |
|-----------|---------------------|
| **SSH / OpenSSH** | 22, 54321, 8012 |
| **Dropbear** | 90, 109, 143 |
| **SSL/TLS (Stunnel)** | 444, 445, 844 |
| **Squid Proxy** | 3128 |
| **Dante/SOCKS5** | 1080 |
| **Xray / V2Ray** | 443, 8080, 10000 |
| **ZiVPN** | UDP 5667 |
| **UDP Custom** | 36712 |
| **Hysteria 2** | 34830 |
| **Shadowsocks** | 8388 |
| **OpenVPN** | 1194 |
| **BadVPN (UDP GW)** | 7200, 7300 |
| **SlowDNS** | 53, 5300 |
| **WireGuard** | 51820 |
| **DTunnel** | 4443, 8081 |
| **Payload (WS/WSS)** | 8082-8085, 8799 |

---

## Menús principales

| Comando | Descripción |
|---------|-------------|
| `mx` / `menu` | Menú principal (usuarios, protocolos, herramientas, update) |
| `protocolos` | Gestión de protocolos VPN |
| `herramientas` | Utilidades: speedtest, firewall, fail2ban, optimizar, etc. |
| `usuarios` | Gestión de usuarios SSH, HWID, Xray, ZiVPN |

---

## Actualizaciones

El sistema incluye **auto-update** por cron (cada 2 días a las 03:00) que:
- Descarga el tarball del repo (`main`)
- Valida la estructura del paquete
- Ejecuta `install.sh --update` preservando configuración y usuarios

Para actualizar manualmente:
```bash
mx
# Opción 9 → Update / Remover → 1) Actualizar
```

O directamente:
```bash
bash /etc/maxinet/update.sh
```

---

## Estructura en disco

```
/etc/maxinet/
├── install.sh              # Instalador principal
├── update.sh               # Actualizador interactivo
├── auto-update.sh          # Cron silencioso
├── updater.sh              # Actualizador TUI premium
├── menu.sh                 # Menú principal
├── config.conf             # Configuración global
├── version.txt             # Versión instalada
├── launchers/              # mx, menu, protocolos, herramientas, usuarios
├── lib/                    # Librerías compartidas
├── protocolos/             # Scripts de cada protocolo
├── herramientas/           # Utilidades del sistema
├── usuarios/               # Gestión de usuarios
├── configs/                # Plantillas de config (haproxy, stunnel, squid, etc.)
├── systemd/                # Unidades systemd
├── languages/              # i18n (es, en, pt, fr, de, ar, hi, zh, sw, af)
└── vendor/                 # Binarios empaquetados (apiAccess, etc.)
```

---

## Características

- **Sin licencias ni phone-home** — totalmente libre
- **Multi-idioma** (10 idiomas incluidos)
- **Banner SSH 3D** personalizable
- **Fail2ban** integrado
- **Gestión de tráfico** por usuario
- **HWID** para cuentas vinculadas a dispositivo
- **Binario apiAccess** opcional (x86_64 ELF)

---

## Desarrollo

```bash
# Clonar
git clone https://github.com/Eduarpj97/maxinet.git
cd maxinet

# Verificar sintaxis
find . -name '*.sh' -exec bash -n {} \;

# Construir release
./build.sh 1.0.1

# Publicar (requiere gh CLI)
gh release create v1.0.1 maxinet-1.0.1.tar.gz maxinet-1.0.1.tar.gz.sha256
```

---

## Licencia

Código liberado sin restricciones de licencia. Uso libre.

---

**Maxinet Network** — Sistema Integral de Gestión de Red y VPN v3.1.3