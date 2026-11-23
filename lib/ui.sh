#!/bin/bash
#=============================================================
# Maxinet Network — lib/ui.sh · DESIGN SYSTEM "NEBULA" v3.0
# Identidad visual premium 2026 — idéntica al banner oficial:
#   • Paleta ANSI-256: azul 39/33 · cian 45/51 · dorado 220 ·
#     amarillo 226 · morado 201 · naranja 208 · blanco 255
#   • Línea maestra  ══ azul (ancho completo)
#   • Header  ◆ M A X I N E T N E T W O R K ◆  (dorado/cian)
#   • Paneles  ┌─┐ │ └─┘  morado con filas alineadas
#   • Footer   ｡ﾟﾟ･｡  ⋆｡˚⊱ · protected · powered by ⋆
#
# v2.4 — 3 técnicas nuevas (aprobadas para superar referencias estilo
# Chumo SIN copiarlas, con identidad 100% Maxinet):
#   1) Gradiente por línea  → mv_grad_txt / mv_grad_rainbow / mv_banner_3d
#      (arcoíris real por carácter, SIN depender de lolcat/figlet)
#   2) Barra de progreso    → mv_fun_bar (con % real) + mv_progress
#      (barra animada con % real mientras corre el comando)
#   3) Serie de separadores → mv_sep / mv_sep_thin / mv_sep_dots /
#      mv_sep_gem / mv_sep_rainbow
#      (5 variantes: identidad propia, no msg-bar de Chumo)
#
# Uso:  source "$BASE/lib/ui.sh"
#   mv_header "TITULO" "Subtitulo" "v2.7"
#   mv_section "💻 SISTEMA"
#   mv_kv "IP" "$IP"
#   mv_pill "ON" "Cloudflare"
#   maxinet_contacts / maxinet_footer
#   mv_panel_top "TITULO" · mv_prow "icono" "label" "valor" · mv_panel_bot
#   mv_fun_bar "Instalando…" "apt-get install -y nginx"
#   mv_grad_txt "M A X I N E T" 45 33        # gradiente cian→azul
#   mv_sep_rainbow                            # separador arcoíris
#=============================================================

[[ -n "$MV_UI_LOADED" ]] && return 0
MV_UI_LOADED=1

# ── Paleta PREMIUM (ANSI-256, igual que banner v2.4) ──
# Importante: usar $'...' → byte ESC real, funciona con printf %s/%b, echo, etc.
MV_R=$'\e[0m'
MV_RED=$'\e[38;5;203m'; MV_GRN=$'\e[38;5;82m'; MV_GLD=$'\e[38;5;220m'; MV_YLW=$'\e[38;5;226m'
MV_BLU=$'\e[38;5;39m';  MV_BLU2=$'\e[38;5;33m'; MV_CYN=$'\e[38;5;45m'; MV_CYN2=$'\e[38;5;51m'
MV_MAG=$'\e[38;5;201m'; MV_ORA=$'\e[38;5;208m'; MV_WHT=$'\e[38;5;255m'; MV_DIM=$'\e[38;5;245m'
MV_BLD=$'\e[1m'

# ══════════════════════════════════════════════════════════
# TÉCNICA 1 · GRADIENTES (sin lolcat, por carácter ANSI-256)
# ══════════════════════════════════════════════════════════

# ── Gradiente LINEAL entre 2 colores de la paleta 0-255 ──
# mv_grad_txt "TEXTO" c_inicio c_fin [negrita]
#   Ej: mv_grad_txt "M A X I N E T" 45 33 1  → cian➜azul en negrita
# Devuelve/imprime el texto pintado, listo para mv_center/printf %b.
mv_grad_txt(){
    local txt="$1" c1="${2:-45}" c2="${3:-33}" bold="${4:-0}" out="" c i n step d
    [[ -z "$txt" ]] && return 0
    n=${#txt}
    (( n < 2 )) && n=2
    step=$(( (c2 - c1) * 100 / (n - 1) ))
    for (( i=0; i<n; i++ )); do
        d=$(( c1 + (step * i) / 100 ))
        (( d < 0 )) && d=0; (( d > 255 )) && d=255
        ch="${txt:i:1}"
        [[ "$ch" == '\' ]] && ch='\\'
        if (( bold )); then
            out+="\e[1;38;5;${d}m${ch}"
        else
            out+="\e[38;5;${d}m${ch}"
        fi
    done
    printf "%b%s%b" "$out" "" "$MV_R"
}

# ── Gradiente ARCOÍRIS (lista de colores, estilo "premium") ──
# mv_grad_rainbow "TEXTO" [negrita]  → rojo➜naranja➜amarillo➜verde➜cian➜morado
mv_grad_rainbow(){
    local txt="$1" bold="${2:-0}" out="" c i n seg pals ci cf j
    local pal=(203 208 226 82 45 201)
    [[ -z "$txt" ]] && return 0
    n=${#txt}
    (( n < 1 )) && return 0
    seg=$(( (n + ${#pal[@]} - 1) / ${#pal[@]} ))
    (( seg < 1 )) && seg=1
    j=0
    for (( i=0; i<n; i++ )); do
        if (( i > 0 && i % seg == 0 && j < ${#pal[@]} - 1 )); then
            (( j++ ))
        fi
        c=${pal[$j]}
        if (( bold )); then
            out+="\e[1;38;5;${c}m${txt:i:1}"
        else
            out+="\e[38;5;${c}m${txt:i:1}"
        fi
    done
    printf "%b%s%b" "$out" "" "$MV_R"
}

# ── Logo 3D oficial con gradiente por LÍNEA (v2.4) ──
# Cada línea del logo recibe un gradiente distinto (identidad Maxinet,
# superior al figlet|lolcat plano de Chumo: aquí cada letra se funde).
# mv_banner_3d [título]  → imprime el logo + título opcional
mv_banner_3d(){
    local titulo="${1:-}" line
    line=$(mv_grad_txt "    ███╗   ███╗ █████╗ ██╗  ██╗██╗███╗   ██╗███████╗████████╗" 51 45 1); mv_center "$line"
    line=$(mv_grad_txt "    ████╗ ████║██╔══██╗╚██╗██╔╝██║████╗  ██║██╔════╝╚══██╔══╝" 45 39 1); mv_center "$line"
    line=$(mv_grad_txt "    ██╔████╔██║███████║ ╚███╔╝ ██║██╔██╗ ██║█████╗     ██║   " 39 33 1); mv_center "$line"
    line=$(mv_grad_txt "    ██║╚██╔╝██║██╔══██║ ██╔██╗ ██║██║╚██╗██║██╔══╝     ██║   " 33 27 1); mv_center "$line"
    line=$(mv_grad_txt "    ██║ ╚═╝ ██║██║  ██║██╔╝ ██╗██║██║ ╚████║███████╗   ██║   " 27 21 1); mv_center "$line"
    line=$(mv_grad_txt "    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   " 21 15 1); mv_center "$line"
    if [[ -n "$titulo" ]]; then
        mv_grad_rainbow "◆  ${titulo}  ◆" 1; echo ""
    fi
}

# ══════════════════════════════════════════════════════════
# TÉCNICA 2 · BARRAS DE PROGRESO (% real)
# ══════════════════════════════════════════════════════════

# ── Barra rectangular fija con % ──
# mv_progress "valor" "total" [car_lleno] [car_vacio] [ancho]
#   • Calcula % real (redondeado), pinta ▮▮▮░░░ + "NN%"
#   • Colores: verde <60 · dorado <85 · rojo >=85
mv_progress(){
    local val="${1:-0}" total="${2:-100}" full="${3:-▮}" empty="${4:-░}" width="${5:-14}"
    local pct f e i color
    (( total < 1 )) && total=1
    pct=$(( val * 100 / total )); (( pct > 100 )) && pct=100; (( pct < 0 )) && pct=0
    f=$(( pct * width / 100 )); e=$(( width - f ))
    if (( pct < 60 )); then color="${MV_GRN}"
    elif (( pct < 85 )); then color="${MV_GLD}"
    else color="${MV_RED}"; fi
    printf "%b" "$color"
    for (( i=0; i<f; i++ )); do printf "%s" "$full"; done
    printf "%b" "$MV_DIM"
    for (( i=0; i<e; i++ )); do printf "%s" "$empty"; done
    printf "%b %s%3d%%%s" "$MV_R" "$MV_WHT" "$pct" "$MV_R"
}

# ── fun_bar MAXINET con % REAL ──
# mv_fun_bar "Título" "comando..."
#   • Ejecuta el comando en background; el % avanza en tiempo real
#     (contador con spinner + barra ▮▮ + %). Al terminar imprime
#     resultado: ✓ verde si exit=0 · ✗ rojo si falla.
#   • Barra de 18 unidades con ancho adaptado a terminal pequeño.
#   • A diferencia del fun_bar clásico de Chumo (solo animación
#     sin %), aquí el porcentaje avanza de verdad mientras corre.
mv_fun_bar(){
    local title="$1" cmd="${2:-true}" pid="" i=0 dots="" bar="" \
          out_file pct cur wid=20 done=0 exit_code=1
    printf "  ${MV_CYN}${title}${MV_R}  ${MV_DIM}...${MV_R}\n"
    out_file=$(mktemp 2>/dev/null || echo "/tmp/mv_funbar_$$")
    eval "$cmd" >"$out_file" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        (( i++ ))
        pct=$(( (i % 100) )); (( pct == 0 )) && pct=1
        cur=$(( pct * wid / 100 )); (( cur > wid )) && cur=$wid
        bar=""
        for (( b=0; b<cur; b++ )); do bar+="▮"; done
        for (( b=cur; b<wid; b++ )); do bar+="░"; done
        local sp chr
        case $(( i % 4 )) in
            0) sp="|" ;; 1) sp="/" ;; 2) sp="-" ;; 3) sp="\\" ;;
        esac
        printf "  \r${MV_GRN}%s${MV_R} ${MV_GLD}%s${MV_R} ${MV_GLD}%3d%%${MV_R} ${MV_DIM}%s${MV_R}  " \
            "$bar" "$sp" "$pct" "$(tr -d '\r' < "$out_file" 2>/dev/null | tail -1 | cut -c1-30)"
        sleep 0.05
    done
    wait "$pid" 2>/dev/null; exit_code=$?
    # 100% final
    bar=""
    for (( b=0; b<wid; b++ )); do bar+="▮"; done
    if (( exit_code == 0 )); then
        printf "  \r${MV_GRN}%s${MV_R} ${MV_WHT}%3d%%${MV_R} ${MV_GRN}✓${MV_R} ${MV_DIM}(ok)${MV_R}  \n" "$bar" 100
    else
        printf "  \r${MV_RED}%s${MV_R} ${MV_WHT}%3d%%${MV_R} ${MV_RED}✗${MV_R} ${MV_DIM}(fail)${MV_R}  \n" "$bar" 100
    fi
    rm -f "$out_file" 2>/dev/null
    return "$exit_code"
}

# ── Spinner simple (operaciones cortas <2s, sin barra) ──
# mv_spinner "Título" "comando..."
mv_spinner(){
    local title="$1" cmd="${2:-true}" pid i=0 sp exit_code
    printf "  ${MV_CYN}${title}${MV_R}  "
    eval "$cmd" >/dev/null 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        case $(( i % 4 )) in
            0) sp="|" ;; 1) sp="/" ;; 2) sp="-" ;; 3) sp="\\" ;;
        esac
        printf "\r  ${MV_CYN}${title}${MV_R}  ${MV_GLD}%s${MV_R}  " "$sp"
        (( i++ )); sleep 0.1
    done
    wait "$pid" 2>/dev/null; exit_code=$?
    if (( exit_code == 0 )); then
        printf "\r  ${MV_CYN}${title}${MV_R}  ${MV_GRN}✓${MV_R}  \n"
    else
        printf "\r  ${MV_CYN}${title}${MV_R}  ${MV_RED}✗${MV_R}  \n"
    fi
    return "$exit_code"
}

# ══════════════════════════════════════════════════════════
# TÉCNICA 3 · SERIE DE SEPARADORES (5 variantes — identidad propia)
# ══════════════════════════════════════════════════════════
# Chumo usa msg -bar/-bar1/-bar3/-bar4 (─── simples). Nosotros:
#   mv_sep            →  ═══ azul         (línea maestra)
#   mv_sep_thin       →  ─── gris         (sutil)
#   mv_sep_dots       →  ∙∙────◆───∙     (punteado premium)
#   mv_sep_gem        →  ◆───◆───◆        (gema dorada/cian)
#   mv_sep_rainbow    →  arcoíris real    (gradiente por segmento)

mv_sep(){ mv_line; }
mv_sep_thin(){ mv_line_thin; }

# ── Separador simple alineado al panel: línea fina sobria ──
mv_sep_dots(){ mv_line_thin; }

# ── Separador gema: ◆────◆────◆ (dorado/cian/morado) ──
mv_sep_gem(){ mv_signature; }

# ── Separador arcoíris (gradiente por segmentos) ──
# Pinta una línea completa con gradiente de color segmento a segmento,
# usando la paleta premium (NO interpola índices ciegos: la interpolación
# 45→201 atraviesa índices grisáceos del ANSI-256; aquí usamos pasos
# de color vivos: cian➜azul➜morado➜dorado➜naranja➜cian).
mv_sep_rainbow(){
    local W i seg pal=(45 39 201 220 208 51) pos cur="${MV_CYN2}"
    W=$(mv_cols)
    (( W < 20 )) && W=20
    seg=$(( W / ${#pal[@]} )); (( seg < 3 )) && seg=3
    for (( i=0; i<W; i++ )); do
        pos=$(( i / seg )); (( pos >= ${#pal[@]} )) && pos=$(( ${#pal[@]} - 1 ))
        printf "\e[38;5;${pal[$pos]}m─"
    done
    printf "%b\n" "$MV_R"
}

# ══════════════════════════════════════════════════════════
# v2.N — BASE COMPATIBLE (todo lo que ya existía, intacto)
# ══════════════════════════════════════════════════════════

# ── Ancho del terminal (cap estético 110, mínimo seguro 30) ──
mv_cols(){
    local C=""
    C=$(tput cols 2>/dev/null) || true
    [[ -z "$C" || ! "$C" =~ ^[0-9]+$ ]] && C="${COLUMNS:-80}"
    (( C < 30 )) && C=30
    (( C > 110 )) && C=110
    echo "$C"
}

# ── Ancho visible real (ignora ANSI; usa wc -L = wcwidth de glibc, igual que el terminal) ──
mv_w(){
    local s="${1:-}"
    local c n skip clean
    local i=0
    skip=0; clean=""
    n=${#s}
    while (( i < n )); do
        c="${s:i:1}"
        if (( skip )); then
            [[ "$c" == "m" ]] && skip=0
            ((i++)); continue
        fi
        if [[ "$c" == $'\x1b' ]]; then skip=1; ((i++)); continue; fi
        if [[ "$c" == '\' && "${s:i+1:1}" == "e" && "${s:i+2:1}" == "[" ]]; then
            skip=1; ((i+=3)); continue
        fi
        clean+="$c"
        ((i++))
    done
    s="$clean"
    if command -v wc >/dev/null 2>&1; then
        LC_ALL=C.UTF-8 printf '%s' "$s" | LC_ALL=C.UTF-8 wc -L 2>/dev/null || echo "${#s}"
    else
        echo "${#s}"
    fi
}

# ── Imprimir centrado en el ancho actual ──
mv_center(){
    local W txt vis pad
    W=$(mv_cols)
    txt="$1"
    vis=$(mv_w "$txt")
    pad=$(( (W - vis) / 2 )); (( pad < 0 )) && pad=0
    printf "%*s%b\n" "$pad" "" "$txt"
}

# ── Línea horizontal completa ──
# mv_line [carácter] [color]   → defecto: ═ azul 39 (línea maestra del banner)
mv_line(){
    local W ch="${1:-═}" col="${2:-${MV_BLU}}"
    W=$(mv_cols)
    printf "%b%s%b\n" "$col" "$(printf "${ch}%.0s" $(seq 1 $W))" "$MV_R"
}
mv_line_thin(){ mv_line "─" "$MV_DIM"; }
mv_line_morado(){ mv_line "─" "$MV_MAG"; }

# ── Barra de firma premium: ──◆────◆──── (dorado/cian/morado) ──
mv_signature(){
    local W seg part
    W=$(mv_cols)
    seg=$(( (W - 4) / 3 )); (( seg < 4 )) && seg=4
    part=$(( W - 2*seg - 4 )); (( part < 1 )) && part=1
    printf "%b◆%b" "$MV_MAG" "$MV_R"
    printf "%b" "$MV_GLD"; printf '─%.0s' $(seq 1 "$seg"); printf "%b◆%b" "$MV_R" "$MV_R"
    printf "%b" "$MV_CYN"; printf '─%.0s' $(seq 1 "$seg"); printf "%b◆%b" "$MV_GLD" "$MV_R"
    printf "%b" "$MV_CYN"; printf '─%.0s' $(seq 1 "$part"); printf "%b◆%b\n" "$MV_GLD" "$MV_R"
}

# ── Header principal: ═══ + ◆ título ◆ + ═══ (estilo banner) ──
mv_header(){
    local TITLE="$1" SUB="${2:-}" VER="${3:-v2.7}"
    mv_line
    mv_center "${MV_GLD}◆${MV_R}  ${MV_BLD}${MV_WHT}${TITLE}${MV_R}  ${MV_DIM}[${MV_R}${MV_CYN}${VER}${MV_R}${MV_DIM}]${MV_R}  ${MV_GLD}◆${MV_R}"
    [[ -n "$SUB" ]] && mv_center "${MV_YLW}${SUB}${MV_R}"
    mv_line
}

# ── Header dorado con sello (idéntico al banner: ── ◆ MAXINET ◆ ──) ──
mv_gold_header(){
    mv_line
    mv_center "${MV_RED}── ${MV_R}${MV_RED}◆${MV_R} ${MV_RED}M A X I N E T${MV_R} ${MV_RED}◆${MV_R} ${MV_RED}──${MV_R}"
    mv_line
}

# ── Contactos centrados (chips) — estilo banner oficial ──
maxinet_contacts(){
    if mv_simple_mode 2>/dev/null; then
        mv_center "${MV_ORA}📢${MV_R} ${MV_WHT}t.me/Maxinet${MV_R}"
        mv_center "${MV_ORA}👥${MV_R} ${MV_WHT}t.me/MaxinetNet${MV_R} ${MV_DIM}·${MV_R} ${MV_WHT}@Maxinet${MV_R}"
        mv_center "${MV_CYN}🌐${MV_R} ${MV_WHT}maxinet-network.web.app${MV_R}"
        mv_center "${MV_ORA}📱${MV_R} ${MV_WHT}+57 311 700 8185${MV_R}"
    else
        mv_center "${MV_ORA}📢${MV_R} ${MV_WHT}t.me/Maxinet${MV_R} ${MV_DIM}·${MV_R} ${MV_WHT}t.me/MaxinetNet${MV_R} ${MV_DIM}·${MV_R} ${MV_WHT}@Maxinet${MV_R}"
        mv_center "${MV_CYN}🌐${MV_R} ${MV_WHT}maxinet-network.web.app${MV_R} ${MV_DIM}·${MV_R} ${MV_ORA}📱${MV_R} ${MV_WHT}+57 311 700 8185${MV_R}"
    fi
}

# ── Header para SUBMENÚS: marco PREMIUM completo (logo 3D + contacts) ──
# Usado por todo script que llame maxinet_sub_header "TÍTULO"
maxinet_sub_header(){
    local TITLE="$1"
    mv_brand_header "$TITLE"
}

# ── Mini-logo 3D MAXINET compacto (estilo banner SSH, centrado) ──
# Reutilizable en TODOS los menús: banner_maxinet "TÍTULO" (o sin título)
# Logo + título centrados; el llamador decide las líneas de marco ════.
# v2.4: banner_maxinet usa el GRADIENTE por línea (mv_banner_3d).
banner_maxinet(){
    local titulo="${1:-}"
    mv_banner_3d "$titulo"
}

# ── Header de marco completo: ═══ + logo + título + contactos + ═══ ──
# mv_brand_header "TÍTULO" "SUBTÍTULO"  → mismo marco del menú principal
mv_brand_header(){
    local TITLE="$1" SUB="${2:-}"
    mv_line
    banner_maxinet "$TITLE"
    [[ -n "$SUB" ]] && mv_center "${MV_YLW}${SUB}${MV_R}"
    maxinet_contacts 2>/dev/null || true
    mv_line
}

# ── Sección interior premium:  ┃ ◆ TÍTULO ──────────── ┃ ──
mv_section(){
    local W txt vis dash
    W=$(mv_cols)
    txt="${1:-}"
    vis=$(mv_w "◆ ${txt}")
    dash=$(( W - vis - 8 )); (( dash < 1 )) && dash=1
    printf "\n ${MV_MAG}┃${MV_R}${MV_GLD}◆${MV_R} ${MV_BLD}${MV_WHT}%s${MV_R} ${MV_DIM}%s${MV_R}\n" \
        "$txt" "$(printf '─%.0s' $(seq 1 "$dash"))"
}

# ── Clave/valor alineado premium:   label ······ valor ──
mv_kv(){
    local key="$1" valc="${2:-${MV_WHT}}" val="${3:-}" W kw pad
    W=$(mv_cols)
    kw=14
    pad=$(( W - kw - ${#val} - 8 )); (( pad < 1 )) && pad=1
    printf " ${MV_CYN}%-${kw}s${MV_R}${MV_DIM}%s${MV_R}${valc}%s${MV_R}\n" "${key}" \
        "$(printf '.%.0s' $(seq 1 5))" "$val"
}

# ── Pill de estado premium:  [● ON] / [◐ WARN] / [○ OFF] ──
mv_pill(){
    if [[ "$1" == "ON" || "$1" == "on" || "$1" == "active" ]]; then
        printf "${MV_GRN}[● ON]${MV_R}"
    elif [[ "$1" == "WARN" ]]; then
        printf "${MV_GLD}[◐ WARN]${MV_R}"
    else
        printf "${MV_RED}[○ OFF]${MV_R}"
    fi
}

# ══════════════════════════════════════════════════════════
# PANELES PREMIUM (estilo INFORMACIÓN DEL SERVIDOR del banner)
#   mv_panel_top "TÍTULO"          →  ┌── ◆ TÍTULO ◆ ────────┐
#   mv_prow "icono" "Clave" valor  →  │ 🔥 Clave ···· valor  │
#   mv_panel_mid ["TÍTULO"]        →  ├── ◆ TÍTULO ◆ ────────┤
#   mv_panel_bot                   →  └──────────────────────┘
# ══════════════════════════════════════════════════════════
mv_panel_width(){
    mv_cols
}

mv_panel_top(){
    local TITLE="$1" PW vis pad rpad
    PW=$(mv_panel_width)
    vis=$(mv_w "$TITLE")
    pad=$(( (PW - vis - 4) / 2 )); (( pad < 1 )) && pad=1
    rpad=$(( PW - vis - 4 - pad )); (( rpad < 1 )) && rpad=1
    printf "%b┌%b%s%b◆%b %b%s%b %b◆%b%s%b┐%b\n" \
        "$MV_MAG" "$MV_MAG" "$(printf '─%.0s' $(seq 1 "$pad"))" \
        "$MV_GLD" "$MV_R" "$MV_BLD" "$TITLE" "$MV_R" "$MV_GLD" "$MV_R" \
        "$(printf '─%.0s' $(seq 1 "$rpad"))" "$MV_MAG" "$MV_R"
}

mv_prow(){
    local icon="$1" label="$2" val="$3" PW vis pad
    PW=$(mv_panel_width)
    vis=$(mv_w " ${icon} ${label} ")
    pad=$(( PW - vis - 3 - ${#val} )); (( pad < 1 )) && pad=1
    printf "%b│ ${MV_ORA}%s${MV_R} ${MV_CYN}%s${MV_R} ${MV_DIM}·${MV_R} ${MV_WHT}%s${MV_R}%*s%b│%b\n" \
        "$MV_MAG" "$icon" "$label" "$val" "$pad" "" "$MV_MAG" "$MV_R"
}

# ── Fila con BARRAS DE PROGRESO en color (v2.4 TÉCNICA 2) ──
# Uso: mv_prow_bars "RAM" "56" "CPU" "88"
#   │ RAM ▮▮▮▮░░░░░░░░ 56%   CPU ▮▮▮▮▮▮▮▮░░ 88%  │
# Difiere de mv_prow: calcula el padding con mv_w (limpia ANSI),
# porque aqui el "valor" contiene códigos de color (mv_progress).
mv_prow_bars(){
    local l1="$1" p1="$2" l2="$3" p2="$4" PW b1 b2 vis pad
    PW=$(mv_panel_width)
    b1=$(mv_progress "${p1:-0}" 100)
    b2=$(mv_progress "${p2:-0}" 100)
    # ancho visible entre borde izquierdo y padding derecho:
    # l1 + espacio + barra1 + 2 espacios + l2 + espacio + barra2
    vis=$(( $(mv_w "$l1") + 1 + $(mv_w "$b1") + 2 + $(mv_w "$l2") + 1 + $(mv_w "$b2") ))
    pad=$(( PW - vis )); (( pad < 1 )) && pad=1
    printf "%b│ %b%s%b %b%b%b  %b%s%b %b%b%b%*s%b│%b\n" \
        "$MV_MAG" "$MV_CYN" "$l1" "$MV_R" "$MV_WHT" "$b1" "$MV_R" \
        "$MV_CYN" "$l2" "$MV_R" "$MV_WHT" "$b2" "$MV_R" \
        "$pad" "" "$MV_MAG" "$MV_R"
}

mv_panel_mid(){
    local PW TITLE="$1" vis pad rpad
    PW=$(mv_panel_width)
    if [[ -n "$TITLE" ]]; then
        vis=$(mv_w "$TITLE")
        pad=$(( (PW - vis - 4) / 2 )); (( pad < 1 )) && pad=1
        rpad=$(( PW - vis - 4 - pad )); (( rpad < 1 )) && rpad=1
        printf "%b├%b%s%b◆%b %b%s%b %b◆%b%s%b┤%b\n" \
            "$MV_MAG" "$MV_MAG" "$(printf '─%.0s' $(seq 1 "$pad"))" \
            "$MV_GLD" "$MV_R" "$MV_BLD" "$TITLE" "$MV_R" "$MV_GLD" "$MV_R" \
            "$(printf '─%.0s' $(seq 1 "$rpad"))" "$MV_MAG" "$MV_R"
    else
        printf "%b├%b%s%b┤%b\n" "$MV_MAG" "$MV_MAG" "$(printf '─%.0s' $(seq 1 $PW))" "$MV_MAG" "$MV_R"
    fi
}

mv_panel_bot(){
    local PW
    PW=$(mv_panel_width)
    printf "%b└%b%s%b┘%b\n" "$MV_MAG" "$MV_MAG" "$(printf '─%.0s' $(seq 1 $PW))" "$MV_MAG" "$MV_R"
}

# ── Fila de MENÚ dentro de panel:  │ [1] 🔥 Opción ......... │ ──
mv_prow_menu(){
    local txt="$1" PW vis pad
    PW=$(mv_panel_width)
    vis=$(mv_w "$txt")
    pad=$(( PW - vis - 2 )); (( pad < 1 )) && pad=1
    printf "%b│%b%b%s%b%*s%b│%b\n" "$MV_MAG" "$MV_R" "$MV_WHT" "$txt" "$MV_R" "$pad" "" "$MV_MAG" "$MV_R"
}

# ── Fila CENTRADA dentro de panel (mensajes / gracias) ──
mv_prow_center(){
    local txt="$1" PW vis pad rest
    PW=$(mv_panel_width)
    vis=$(mv_w "$txt")
    pad=$(( (PW - 2 - vis) / 2 )); (( pad < 0 )) && pad=0
    rest=$(( PW - 2 - vis - pad )); (( rest < 0 )) && rest=0
    printf "%b│%b%b%*s%b%b%s%b%b%*s%b%b│%b\n" \
        "$MV_MAG" "$MV_R" "$MV_GLD" "$pad" "" "$MV_R" \
        "$MV_BLD" "$txt" "$MV_R" \
        "$MV_GLD" "$rest" "" "$MV_R" "$MV_MAG" "$MV_R"
}

# ── Footer de contactos premium (despedida banner oficial) ──
maxinet_footer(){
    echo ""
    mv_line_thin
    mv_center "${MV_ORA}｡ﾟﾟ･｡･ﾟﾟ｡ ${MV_R}${MV_CYN}⋆｡˚⊱ ${MV_RED} M A X I N E T${MV_R}${MV_CYN} ⊰˚｡⋆${MV_R} ${MV_ORA}｡ﾟﾟ･｡･ﾟﾟ｡${MV_R}"
    mv_center "${MV_DIM}🤝 Socios:${MV_R} ${MV_WHT}t.me/FreeNetZonevip${MV_R} ${MV_DIM}·${MV_R} ${MV_WHT}t.me/FreeNetZonevips${MV_R}"
    mv_line_thin
}