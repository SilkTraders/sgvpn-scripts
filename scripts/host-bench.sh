#!/usr/bin/env bash
# =============================================================================
#  host-bench — проверка сервера хостера ПЕРЕД тем, как ставить на него ноду (v1)
#
#  Отвечает на вопросы:
#    - какой процессор продали и сколько его на самом деле дают под нагрузкой
#      (steal — доля времени, когда хостер отдаёт ваше ядро другим клиентам);
#    - какая скорость и задержка у канала, в том числе до России;
#    - как IP выглядит снаружи: страна, владелец, доступен ли из России,
#      открываются ли с него нужные сервисы.
#
#  Режимы:
#    host-bench                      полный тест: ≈1,5 минуты, из них ≈35 секунд
#                                    полной нагрузки на ВСЕ ядра
#    host-bench --quick              без нагрузки на процессор: паспорт, сеть, IP
#    host-bench --watch              суточный тест: раз в час 15 секунд полной
#                                    нагрузки и запись в журнал (ловит перепродажу
#                                    процессора в часы пик)
#    host-bench --history            показать журнал суточного теста
#    host-bench --unwatch            выключить суточный тест
#    host-bench --iperf-server [IP]  ждать замер скорости от входной ноды
#    host-bench --iperf-client IP    замерить скорость до сервера (запускать на
#                                    входной ноде)
#    Опция --to IP:ПОРТ              добавить свою точку в замер задержки
#                                    (например, входную ноду); можно несколько
#
#  ВАЖНО: полный тест, --watch и iperf грузят процессор или канал. На ноде
#  с клиентами скрипт спросит подтверждение, а --watch откажется работать:
#  для рабочих нод есть node-check, он нагрузку не создаёт.
#
#  В файле нет IP, ключей и других секретов.
# =============================================================================

set -u
export LC_ALL=C

SELF="/usr/local/sbin/host-bench"
LOG="/var/log/host-bench.log"
CRON="/etc/cron.d/host-bench"
BURN_FULL=20        # секунд полной нагрузки в полном тесте
BURN_LOG=15         # секунд полной нагрузки в ежечасном замере
IPERF_PORT=5201

# --- Пороги ---
MAX_STEAL_LOAD=5    # % steal под нагрузкой: выше — хостер перепродаёт процессор
BAD_STEAL_LOAD=15   # % steal под нагрузкой: выше — сервер под ноду не годится
MIN_SCALE=75        # % от идеального ускорения на всех ядрах
MIN_AES_GBS=1.5     # ГБ/с AES-256-GCM на одном ядре
MAX_LOSS=1          # % потерь пакетов до России
MAX_RU_MS=80        # мс задержки до России (для моста и ноды прямого выхода)

WARNS=0
hdr()  { echo ""; echo "── $* ──"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; WARNS=$((WARNS + 1)); }
info() { echo "  ℹ️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }
gt()   { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a > b)}'; }
lt()   { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a < b)}'; }
have() { command -v "$1" >/dev/null 2>&1; }

NPROC="$(nproc)"
IF="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"

# Сколько клиентских соединений сейчас у Xray (0, если ноды нет)
xray_conns() {
    pgrep -x rw-core >/dev/null 2>&1 || { echo 0; return; }
    ss -tn state established 2>/dev/null | awk '$1 ~ /^[0-9]+$/' | wc -l
}

# Подтверждение перед нагрузкой на рабочей ноде
confirm_load() {
    local c
    c="$(xray_conns)"
    [ "$c" -lt 20 ] && return 0
    echo "⚠️  На этом сервере работает Xray, сейчас около $c соединений."
    echo "    $1"
    [ -t 0 ] || die "Запуск без терминала на рабочей ноде запрещён."
    read -r -p "    Продолжить? Введите YES: " ans
    [ "$ans" = "YES" ] || die "Отменено."
}

# --- Процессор: снимок /proc/stat и расчёт занятости и steal между снимками ---
cpu_snap() { awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8, $9}' /proc/stat; }
# cpu_diff "<снимок1>" "<снимок2>"  →  "steal% busy%"
cpu_diff() {
    echo "$1 $2" | awk '{ for (i = 1; i <= 8; i++) { d[i] = $(i + 8) - $i; t += d[i] }
                          if (t <= 0) t = 1
                          printf "%.1f %.0f\n", 100 * d[8] / t, 100 * (t - d[4] - d[5]) / t }'
}

# Скорость шифрования в ГБ/с: crypto_speed <алгоритм> <секунд> [потоков]
crypto_speed() {
    local multi=""
    [ "${3:-1}" -gt 1 ] && multi="-multi $3"
    # shellcheck disable=SC2086
    openssl speed $multi -seconds "$2" -bytes 16384 -evp "$1" 2>/dev/null |
        awk -v a="$1" 'tolower($1) == a {v = $NF} END {sub(/k$/, "", v); printf "%.2f", v / 1e6}'
}

# Полная нагрузка на все ядра с замером steal: burn <секунд> → "ГБ/с steal% busy%"
burn() {
    local s1 s2 sp
    s1="$(cpu_snap)"
    sp="$(crypto_speed aes-256-gcm "$1" "$NPROC")"
    s2="$(cpu_snap)"
    echo "${sp:-0} $(cpu_diff "$s1" "$s2")"
}

# -----------------------------------------------------------------------------
#  Разделы отчёта
# -----------------------------------------------------------------------------
sec_passport() {
    hdr "Паспорт сервера"
    local virt model ram aes kern bbr q drv
    virt="$(systemd-detect-virt 2>/dev/null || echo '?')"
    model="$(awk -F: '/model name/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)"
    ram="$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)"
    kern="$(uname -r)"
    info "Виртуализация: $virt, ядро Linux: $kern"
    info "Процессор: ${model:-?}, ядер: $NPROC, память: $ram МБ"
    case "$virt" in
        kvm|vmware|microsoft|xen|qemu|none) ok "Полная виртуализация ($virt): можно менять настройки ядра" ;;
        lxc|openvz|docker|podman) warn "Контейнерная виртуализация ($virt): настройки ядра и BBR могут быть недоступны" ;;
        *) info "Тип виртуализации не распознан" ;;
    esac
    if grep -qw aes /proc/cpuinfo; then ok "Аппаратное шифрование AES есть"
    else warn "Аппаратного шифрования AES нет — Xray будет тратить в разы больше процессора"; fi
    bbr="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    if echo "$bbr" | grep -qw bbr || modprobe -n tcp_bbr 2>/dev/null; then ok "BBR доступен"
    else warn "BBR недоступен в этом ядре"; fi
    if [ -n "$IF" ]; then
        q="$(ls -d /sys/class/net/"$IF"/queues/rx-* 2>/dev/null | wc -l)"
        drv="$(basename "$(readlink -f "/sys/class/net/$IF/device/driver" 2>/dev/null)" 2>/dev/null)"
        info "Сеть: $IF, драйвер ${drv:-?}, очередей приёма: $q, MTU $(cat "/sys/class/net/$IF/mtu" 2>/dev/null)"
    fi
    if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then info "IPv6-адрес есть (по стандарту выход только по IPv4)"
    else info "IPv6-адреса нет"; fi
    info "Диск: свободно $(df -h / | awk 'NR == 2 {print $4}')"
}

sec_cpu() {
    hdr "Процессор: что продали и что дают"
    have openssl || { warn "Нет openssl — тест процессора пропущен"; return; }
    local s1 s2 idle aes cha multi steal busy scale
    s1="$(cpu_snap)"; sleep 5; s2="$(cpu_snap)"
    idle="$(cpu_diff "$s1" "$s2" | cut -d' ' -f1)"
    info "Steal в покое: ${idle}% (мало что значит: в покое отбирать нечего)"

    aes="$(crypto_speed aes-256-gcm 5)"
    cha="$(crypto_speed chacha20-poly1305 5)"
    if lt "${aes:-0}" "$MIN_AES_GBS"; then warn "Одно ядро, AES-256-GCM: ${aes} ГБ/с — слабый процессор (ориентир от ${MIN_AES_GBS})"
    else ok "Одно ядро, AES-256-GCM: ${aes} ГБ/с"; fi
    info "Одно ядро, ChaCha20-Poly1305: ${cha} ГБ/с"

    read -r multi steal busy <<< "$(burn "$BURN_FULL")"
    scale="$(awk -v m="$multi" -v s="$aes" -v n="$NPROC" 'BEGIN {printf "%.0f", (s > 0) ? 100 * m / (s * n) : 0}')"
    info "Все $NPROC ядер, ${BURN_FULL} с: ${multi} ГБ/с, занятость ${busy}%"
    if gt "$steal" "$BAD_STEAL_LOAD"; then warn "Под нагрузкой хостер отбирает ${steal}% процессора — сервер под ноду не годится"
    elif gt "$steal" "$MAX_STEAL_LOAD"; then warn "Под нагрузкой хостер отбирает ${steal}% процессора (порог ${MAX_STEAL_LOAD}%)"
    else ok "Под нагрузкой хостер отбирает ${steal}% процессора"; fi
    if [ "$NPROC" -gt 1 ]; then
        if [ "$scale" -lt "$MIN_SCALE" ]; then warn "Все ядра вместе дают ${scale}% от ожидаемого — ядра не полноценные или перепроданы"
        else ok "Все ядра вместе дают ${scale}% от ожидаемого"; fi
    fi
    info "Один замер — это один момент времени. Перепродажу в часы пик ловит: host-bench --watch"
}

# Задержка: минимальное время TCP-подключения из трёх попыток, мс
tcp_ms() {
    local best="" t _
    for _ in 1 2 3; do
        t="$(curl -o /dev/null -s --max-time 5 -w '%{time_connect}' "$1" 2>/dev/null)" || continue
        [ -n "$t" ] && gt "$t" 0 && { [ -z "$best" ] || lt "$t" "$best"; } && best="$t"
    done
    [ -n "$best" ] && awk -v t="$best" 'BEGIN {printf "%.0f", t * 1000}'
}

sec_net() {
    hdr "Сеть"
    have curl || { warn "Нет curl — сетевые тесты пропущены"; return; }
    local out code spd ms p loss rtt
    out="$(curl -s -o /dev/null --max-time 20 -w '%{http_code} %{speed_download}' \
           'https://speed.cloudflare.com/__down?bytes=100000000' 2>/dev/null)"
    read -r code spd <<< "$out"
    if [ "${code:-0}" = "200" ]; then info "Загрузка с Cloudflare (один поток): $(awk -v s="$spd" 'BEGIN {printf "%.0f", s * 8 / 1e6}') Мбит/с"
    else info "Загрузка с Cloudflare: замер не удался (код ${code:-нет ответа})"; fi
    out="$(head -c 50000000 /dev/zero | curl -s -o /dev/null --max-time 20 -w '%{http_code} %{speed_upload}' \
           -X POST --data-binary @- 'https://speed.cloudflare.com/__up' 2>/dev/null)"
    read -r code spd <<< "$out"
    if [ "${code:-0}" = "200" ]; then info "Отдача в Cloudflare (один поток): $(awk -v s="$spd" 'BEGIN {printf "%.0f", s * 8 / 1e6}') Мбит/с"
    else info "Отдача в Cloudflare: замер не удался (код ${code:-нет ответа})"; fi
    info "Один поток занижает скорость быстрых каналов; точный замер до своей ноды: --iperf-server / --iperf-client"

    for p in https://ya.ru https://vk.com; do
        ms="$(tcp_ms "$p")"
        if [ -z "$ms" ]; then warn "До ${p#https://} подключиться не удалось"
        elif [ "$ms" -gt "$MAX_RU_MS" ]; then warn "Задержка до ${p#https://} (Россия): ${ms} мс (ориентир до ${MAX_RU_MS})"
        else ok "Задержка до ${p#https://} (Россия): ${ms} мс"; fi
    done
    for p in ${TO_LIST:-}; do
        ms="$(tcp_ms "http://$p")"
        if [ -z "$ms" ]; then warn "До $p подключиться не удалось (порт закрыт или не слушается)"
        else info "Задержка до $p: ${ms} мс"; fi
    done

    if have ping; then
        out="$(ping -c 20 -i 0.2 -q -W 2 77.88.8.8 2>/dev/null)"
        loss="$(echo "$out" | grep -o '[0-9.]*% packet loss' | cut -d% -f1)"
        rtt="$(echo "$out" | awk -F/ '/^rtt|^round-trip/ {printf "%.0f", $5}')"
        if [ -z "$loss" ]; then info "Потери до России: ping не сработал"
        elif gt "$loss" "$MAX_LOSS"; then warn "Потери пакетов до России (Яндекс DNS): ${loss}%, задержка ${rtt:-?} мс"
        else ok "Потери пакетов до России (Яндекс DNS): ${loss}%, задержка ${rtt:-?} мс"; fi
    fi
}

sec_ip() {
    hdr "IP-адрес: как он выглядит снаружи"
    have curl || { warn "Нет curl — проверки IP пропущены"; return; }
    local ip json country org city
    ip="$(curl -4 -s --max-time 8 https://api.ipify.org 2>/dev/null)"
    [ -n "$ip" ] || { warn "Не удалось определить внешний IPv4"; return; }
    json="$(curl -s --max-time 8 "https://ipinfo.io/$ip/json" 2>/dev/null)"
    country="$(echo "$json" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p' | head -1)"
    city="$(echo "$json" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p' | head -1)"
    org="$(echo "$json" | sed -n 's/.*"org": *"\([^"]*\)".*/\1/p' | head -1)"
    info "IPv4: $ip"
    info "Страна по базе ipinfo: ${country:-?} ${city:+($city)}, владелец сети: ${org:-?}"
    info "Номер сети (AS…) в строке выше — по нему ТСПУ блокирует целых хостеров; сверяйте с историей своих блокировок"

    if have python3; then check_from_ru "$ip"
    else info "Проверка доступности из России пропущена: нет python3"; fi

    hdr "Сервисы с этого IP"
    local name url code t
    while read -r name url; do
        [ -n "$name" ] || continue
        read -r code t <<< "$(curl -s -o /dev/null --max-time 8 -w '%{http_code} %{time_total}' "$url" 2>/dev/null)"
        if [ "${code:-000}" = "000" ]; then warn "$name: не открывается с этого IP"
        else info "$name: ответ ${code}, $(awk -v t="$t" 'BEGIN {printf "%.1f", t}') с"; fi
    done <<'URLS'
Google https://www.google.com/generate_204
YouTube https://www.youtube.com/generate_204
Gemini https://gemini.google.com/
ChatGPT https://chatgpt.com/
Claude https://claude.ai/
Instagram https://www.instagram.com/
Telegram https://web.telegram.org/
WhatsApp https://web.whatsapp.com/
Netflix https://www.netflix.com/
URLS
    info "Код 000 — сервис не отвечает этому IP. Коды 200/204/301/302 — открыт; 403 — сервис отвечает, но может требовать проверку"
    info "Регион, который сервисы видят у этого IP, скрипт не определяет"
}

# Доступность IP из России через узлы check-host.net (TCP на порт SSH)
check_from_ru() {
    local ip="$1" port
    port="$(ss -tlnp 2>/dev/null | awk '/sshd/ {n = split($4, a, ":"); print a[n]; exit}')"
    port="${port:-22}"
    python3 - "$ip" "$port" <<'PY'
import json, sys, time, urllib.parse, urllib.request
ip, port = sys.argv[1], sys.argv[2]
H = {"Accept": "application/json", "User-Agent": "host-bench"}
def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=15) as r:
        return json.load(r)
try:
    nodes = get("https://check-host.net/nodes/hosts")["nodes"]
    ru = [n for n, v in nodes.items() if v["location"][0] == "ru"]
    ctl = [n for n, v in nodes.items() if v["location"][0] in ("de", "nl", "fi", "fr")][:3]
    if not ru:
        print("  ℹ️  check-host.net не дал российских узлов — проверка пропущена"); sys.exit(0)
    q = "&".join("node=" + urllib.parse.quote(n) for n in ru + ctl)
    req = get("https://check-host.net/check-tcp?host=%s:%s&%s" % (ip, port, q))
    rid = req["request_id"]
    res = {}
    for _ in range(6):
        time.sleep(4)
        res = get("https://check-host.net/check-result/" + rid)
        if all(res.get(n) is not None for n in ru + ctl):
            break
    def good(n):
        r = res.get(n)
        return bool(r and isinstance(r[0], dict) and "time" in r[0])
    ru_ok = sum(good(n) for n in ru); ctl_ok = sum(good(n) for n in ctl)
    line = "порт %s: из России отвечает %d из %d узлов, из Европы %d из %d" % (port, ru_ok, len(ru), ctl_ok, len(ctl))
    if ctl_ok == 0:
        print("  ℹ️  Доступность снаружи, " + line + " — порт закрыт для всех, проверка не показательна")
    elif ru_ok == 0:
        print("  ⚠️  Доступность из России, " + line + " — похоже на блокировку IP"); sys.exit(3)
    elif ru_ok < len(ru) / 2:
        print("  ⚠️  Доступность из России, " + line + " — отвечает меньше половины"); sys.exit(3)
    else:
        print("  ✅ Доступность из России, " + line)
    print("  ℹ️  Узлы проверки стоят в дата-центрах. Блокировки на мобильных операторах они не видят — это проверяется только с телефона")
except Exception as e:
    print("  ℹ️  Проверка через check-host.net не удалась: %s" % e)
PY
    [ $? -eq 3 ] && WARNS=$((WARNS + 1))
}

sec_summary() {
    hdr "Итог"
    if [ "$WARNS" -eq 0 ]; then echo "  ✅ Замечаний нет"
    else echo "  ⚠️  Замечаний: $WARNS (строки с ⚠️ выше)"; fi
    echo "  Чего скрипт не видит: блокировки на мобильных операторах России."
    echo "  После установки ноды подключитесь к ней с телефона через мобильную сеть и через Wi‑Fi."
    echo ""
}

# -----------------------------------------------------------------------------
#  Суточный тест
# -----------------------------------------------------------------------------
do_log() {
    have openssl || exit 0
    local s1 s2 idle multi steal busy
    s1="$(cpu_snap)"; sleep 5; s2="$(cpu_snap)"
    idle="$(cpu_diff "$s1" "$s2" | cut -d' ' -f1)"
    read -r multi steal busy <<< "$(burn "$BURN_LOG")"
    [ -s "$LOG" ] || echo "дата время steal_покой% steal_нагрузка% занято% все_ядра_ГБ/с" > "$LOG"
    echo "$(date '+%F %H:%M') $idle $steal $busy $multi" >> "$LOG"
}

# -----------------------------------------------------------------------------
#  Замер скорости между двумя своими серверами (iperf3)
# -----------------------------------------------------------------------------
need_iperf() {
    have iperf3 && return 0
    echo "Устанавливаю iperf3…"
    DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 >/dev/null 2>&1 || die "Не удалось установить iperf3"
}

iperf_server() {
    local from="${1:-}" rule=0
    need_iperf
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        [ -n "$from" ] || die "ufw включён: укажите IP входной ноды — host-bench --iperf-server <IP>"
        ufw allow from "$from" to any port "$IPERF_PORT" proto tcp >/dev/null && rule=1
    fi
    echo "Жду два замера на порту $IPERF_PORT (до 5 минут)."
    echo "На входной ноде выполните:  host-bench --iperf-client <IP_ЭТОГО_СЕРВЕРА>"
    timeout 300 iperf3 -s -1 -p "$IPERF_PORT" >/dev/null 2>&1
    timeout 120 iperf3 -s -1 -p "$IPERF_PORT" >/dev/null 2>&1
    [ "$rule" -eq 1 ] && ufw delete allow from "$from" to any port "$IPERF_PORT" proto tcp >/dev/null
    echo "Готово, порт $IPERF_PORT закрыт."
}

iperf_client() {
    local ip="${1:-}" r
    [ -n "$ip" ] || die "Укажите IP сервера: host-bench --iperf-client <IP>"
    need_iperf
    confirm_load "Замер на 20 секунд займёт канал этой ноды — у клиентов просядет скорость."
    r="$(iperf3 -c "$ip" -p "$IPERF_PORT" -t 10 -P 4 2>/dev/null | awk '/SUM.*receiver/ {print $(NF - 2), $(NF - 1)}')"
    echo "  ℹ️  Отсюда на сервер: ${r:-замер не удался}"
    sleep 2
    r="$(iperf3 -c "$ip" -p "$IPERF_PORT" -t 10 -P 4 -R 2>/dev/null | awk '/SUM.*receiver/ {print $(NF - 2), $(NF - 1)}')"
    echo "  ℹ️  С сервера сюда:   ${r:-замер не удался}"
}

# -----------------------------------------------------------------------------
#  Точка входа
# -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Нужен root: sudo host-bench"

MODE="full"; TO_LIST=""; ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quick|--watch|--unwatch|--history|--log) MODE="${1#--}" ;;
        --iperf-server) MODE="iperf-server"; case "${2:-}" in ""|--*) ;; *) ARG="$2"; shift ;; esac ;;
        --iperf-client) MODE="iperf-client"; ARG="${2:-}"; [ $# -gt 1 ] && shift ;;
        --to) TO_LIST="$TO_LIST ${2:-}"; [ $# -gt 1 ] && shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Неизвестный параметр: $1 (справка: host-bench --help)" ;;
    esac
    shift
done

case "$MODE" in
    full)
        confirm_load "Полный тест на ≈35 секунд загрузит все ядра — у клиентов просядет скорость."
        echo "host-bench: $(hostname), $(date '+%F %T'), полный тест ≈1,5 минуты…"
        sec_passport; sec_cpu; sec_net; sec_ip; sec_summary ;;
    quick)
        echo "host-bench: $(hostname), $(date '+%F %T'), быстрый тест без нагрузки на процессор…"
        sec_passport; sec_net; sec_ip; sec_summary ;;
    log) do_log ;;
    watch)
        pgrep -x rw-core >/dev/null 2>&1 && die "На сервере работает Xray. Суточный тест грузит процессор и нужен только для пустого сервера; для рабочей ноды используйте node-check."
        [ -x "$SELF" ] || die "Скрипт должен лежать в $SELF (установите через: mynode bench)"
        echo "0 * * * * root $SELF --log" > "$CRON"
        do_log
        echo "✅ Суточный тест включён: раз в час $BURN_LOG секунд полной нагрузки. Первый замер записан."
        echo "   Журнал: host-bench --history    Выключить: host-bench --unwatch"
        echo "   Не забудьте выключить перед установкой ноды." ;;
    unwatch) rm -f "$CRON"; echo "✅ Суточный тест выключен. Журнал остался: $LOG" ;;
    history)
        [ -s "$LOG" ] || die "Журнал пуст: $LOG"
        if have column; then column -t "$LOG"; else cat "$LOG"; fi ;;
    iperf-server) iperf_server "$ARG" ;;
    iperf-client) iperf_client "$ARG" ;;
esac
