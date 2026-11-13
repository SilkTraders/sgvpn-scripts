#!/usr/bin/env bash
# =============================================================================
#  node-check — проверка ноды SG VPN (v1.2)
#
#  v1.2: предупреждение, если порт моста не открыт ни для одной входной
#  ноды; проверка DNS внутри контейнера.
#  v1.1: добавлены swap, диск и таблица conntrack — то, что раньше
#  показывала утилита node-health; node-check её полностью заменяет.
#
#  Что делает: читает состояние сервера и Xray и сверяет его со стандартом.
#  Ничего не меняет в работе ноды (кроме режима --install, который ставит
#  ежечасную запись замеров в журнал).
#
#  Режимы:
#    node-check              полный отчёт на экран с вердиктами (≈10 секунд)
#    node-check --log        одна строка замера в журнал (для cron)
#    node-check --history    показать журнал замеров
#    node-check --install    включить ежечасную запись в журнал
#    node-check --uninstall  выключить ежечасную запись (журнал остаётся)
#
#  Что скрипт НЕ видит (проверяется с телефона клиента):
#    - с какого IP клиент выходит в интернет (IPv4 на выходе);
#    - идут ли российские сайты напрямую с входной ноды;
#    - какие именно домены уходят в Psiphon.
#
#  В файле нет IP, ключей и других секретов — можно держать в публичном
#  репозитории.
# =============================================================================

set -u
export LC_ALL=C

SELF="/usr/local/sbin/node-check"
LOG="/var/log/node-check.log"
CRON="/etc/cron.d/node-check"
SAMPLE=10                                   # длительность замера, секунд
CLIENT_PORTS="443 2053 2083"                # XHTTP, gRPC, Vision
BRIDGE_PORT="$(cat /etc/sgvpn/bridge-port 2>/dev/null || echo 2087)"

# --- Пороги стандарта ---
MAX_PER_IP=5            # соединений на один клиентский IP (норма 2–4)
MAX_SILENT_PCT=5        # % соединений на 443 без данных дольше 10 минут
MIN_KEEPALIVE_PCT=90    # % клиентских соединений с включённым keepalive
MAX_BRIDGE_PIPES=300    # соединений вход → мост (норма — десятки)
MAX_STEAL=5             # % процессора, отобранного хостером
MAX_CPU=80              # % занятости процессора
MAX_RETR=5              # % повторных отправок пакетов
MAX_RSS_PCT=85          # % памяти Xray от лимита GOMEMLIMIT

WARNS=0
hdr()  { echo ""; echo "── $* ──"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; WARNS=$((WARNS + 1)); }
info() { echo "  ℹ️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Нужен root: sudo node-check"
command -v ss >/dev/null 2>&1 || die "Не найдена утилита ss (пакет iproute2)"

# -----------------------------------------------------------------------------
#  Сбор данных
# -----------------------------------------------------------------------------
PID="$(pgrep -x rw-core 2>/dev/null | head -1)"
IF="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
NPROC="$(nproc)"
HZ="$(getconf CLK_TCK 2>/dev/null || echo 100)"

# Порты, которые слушает Xray
LISTEN="$(ss -tlnp 2>/dev/null | awk '/rw-core/ {n=split($4,a,":"); print a[n]}' | sort -n | tr '\n' ' ')"
has_port() { case " $LISTEN" in *" $1 "*) return 0 ;; esac; return 1; }

if has_port 443; then ROLE="client"; else ROLE="bridge"; fi

# Установленные соединения: est sport 443 | est dport 2087
est() { ss -tn state established "( $1 = :$2 )" 2>/dev/null | awk '$1 ~ /^[0-9]+$/'; }

# "всего уникальных_IP" для входящих соединений на порт
conn_stat() {
    est sport "$1" | awk '{sub(/:[0-9]+$/, "", $4); if (!($4 in ip)) n++; ip[$4] = 1; t++}
                          END {printf "%d %d\n", t + 0, n + 0}'
}

# "всего молчащих" — соединения без входящих данных дольше 10 минут
silent_stat() {
    ss -tni state established "( sport = :$1 )" 2>/dev/null | grep -o 'lastrcv:[0-9]*' |
        awk -F: '{t++; if ($2 > 600000) d++} END {printf "%d %d\n", t + 0, d + 0}'
}

keepalive_count() {
    ss -tno state established "( sport = :$1 )" 2>/dev/null | grep -c 'timer:(keepalive'
}

netstat_val() {
    awk -v k="$1" '/^TcpExt:/ { if (!h) { split($0, n, " "); h = 1 }
                                 else for (i = 2; i <= NF; i++) if (n[i] == k) { print $i; exit } }' \
        /proc/net/netstat 2>/dev/null
}

snap() {
    {
        grep '^cpu' /proc/stat
        if [ -n "$PID" ] && [ -r "/proc/$PID/stat" ]; then
            sed 's/^.*) //' "/proc/$PID/stat" | awk '{print "xray", $12 + $13}'
        fi
        if [ -n "$IF" ]; then
            awk -v i="$IF:" '{sub(/:/, ": ")} $1 == i {print "net", $2, $10}' /proc/net/dev
        fi
        awk '/^Tcp:/ { if (!h) { split($0, n, " "); h = 1 }
                       else { for (i = 2; i <= NF; i++) { if (n[i] == "OutSegs") o = $i
                                                          if (n[i] == "RetransSegs") r = $i }
                              print "tcp", o, r } }' /proc/net/snmp
    } > "$1"
}

# Замер за SAMPLE секунд: процессор, Xray, трафик, повторные отправки
CPU_BUSY=0; CPU_STEAL=0; CPU_SOFT=0; CORES_BUSY=""; CORES_SOFT=""
XRAY_CPU=0; RX_MBIT=0; TX_MBIT=0; RETR_PCT=0
measure() {
    local t1 t2
    t1="$(mktemp)"; t2="$(mktemp)"
    snap "$t1"; sleep "$SAMPLE"; snap "$t2"
    eval "$(awk -v dt="$SAMPLE" -v hz="$HZ" '
        FNR == NR { for (i = 2; i <= NF; i++) a[$1, i] = $i; next }
        $1 ~ /^cpu/ {
            tot = 0
            for (i = 2; i <= 9; i++) { d[i] = $i - a[$1, i]; tot += d[i] }
            if (tot <= 0) tot = 1
            busy = 100 * (tot - d[5] - d[6]) / tot
            if ($1 == "cpu") printf "CPU_BUSY=%.0f\nCPU_STEAL=%.1f\nCPU_SOFT=%.1f\n", busy, 100 * d[9] / tot, 100 * d[8] / tot
            else { cb = cb sprintf("%.0f ", busy); cs = cs sprintf("%.0f ", 100 * d[8] / tot) }
        }
        $1 == "xray" { printf "XRAY_CPU=%.0f\n", 100 * ($2 - a["xray", 2]) / hz / dt }
        $1 == "net"  { printf "RX_MBIT=%.1f\nTX_MBIT=%.1f\n", ($2 - a["net", 2]) * 8 / dt / 1e6, ($3 - a["net", 3]) * 8 / dt / 1e6 }
        $1 == "tcp"  { o = $2 - a["tcp", 2]; r = $3 - a["tcp", 3]; printf "RETR_PCT=%.2f\n", (o > 0) ? 100 * r / o : 0 }
        END { printf "CORES_BUSY=\"%s\"\nCORES_SOFT=\"%s\"\n", cb, cs }' "$t1" "$t2")"
    rm -f "$t1" "$t2"
}

xray_rss_mb() {
    [ -n "$PID" ] && awk '/^VmRSS:/ {printf "%d", $2 / 1024}' "/proc/$PID/status" 2>/dev/null
}

xray_env() {
    [ -n "$PID" ] && { tr '\0' '\n' < "/proc/$PID/environ"; } 2>/dev/null | awk -F= -v k="$1" '$1 == k {print $2; exit}'
}

# "1500MiB" / "2GiB" / "1500000000" → мегабайты
to_mb() {
    echo "$1" | awk '{ v = $1 + 0; u = $1; gsub(/[0-9.]/, "", u)
                       if (u == "GiB") v *= 1024; else if (u == "KiB") v /= 1024
                       else if (u == "MiB") v = v; else v /= 1048576
                       printf "%d", v }'
}

gt() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a > b)}'; }   # gt 5.2 5 → истина

# Соединения стыка вход → мост
bridge_pipes() {
    if [ "$ROLE" = "bridge" ]; then est sport "$BRIDGE_PORT" | wc -l
    else est dport "$BRIDGE_PORT" | wc -l; fi
}

# -----------------------------------------------------------------------------
#  Режим --log: одна строка в журнал
# -----------------------------------------------------------------------------
do_log() {
    measure
    local c443 ip443 perip c2053 c2083 load1 rss drops
    read -r c443 ip443 <<< "$(conn_stat 443)"
    read -r c2053 _ <<< "$(conn_stat 2053)"
    read -r c2083 _ <<< "$(conn_stat 2083)"
    perip="$(awk -v t="$c443" -v n="$ip443" 'BEGIN {printf "%.1f", n ? t / n : 0}')"
    load1="$(cut -d' ' -f1 /proc/loadavg)"
    rss="$(xray_rss_mb)"; rss="${rss:-0}"
    drops="$(( $(netstat_val ListenDrops || echo 0) + 0 ))"

    [ -s "$LOG" ] || echo "дата время load cpu% steal% soft% xray% rssMB rxMbit txMbit c443 ip443 наIP c2053 c2083 мост retr% drops" > "$LOG"
    echo "$(date '+%F %H:%M') $load1 $CPU_BUSY $CPU_STEAL $CPU_SOFT $XRAY_CPU $rss $RX_MBIT $TX_MBIT $c443 $ip443 $perip $c2053 $c2083 $(bridge_pipes) $RETR_PCT $drops" >> "$LOG"
}

# -----------------------------------------------------------------------------
#  Режим отчёта
# -----------------------------------------------------------------------------
do_report() {
    echo "node-check: $(hostname), $(date '+%F %T'), замер ${SAMPLE} с…"
    measure

    hdr "Нода"
    if [ "$ROLE" = "client" ]; then info "Роль: клиентская (вход или нода прямого выхода)"
    else info "Роль: мост"; fi
    info "Ядер: $NPROC, память: $(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo) МБ, сервер работает: $(uptime -p 2>/dev/null | sed 's/^up //')"

    hdr "Xray"
    if [ -z "$PID" ]; then
        warn "Процесс rw-core не найден — Xray не запущен"
    else
        ok "rw-core запущен, работает без перезапуска: $(ps -o etime= -p "$PID" | tr -d ' ')"
    fi
    if [ -n "$LISTEN" ]; then info "Слушает порты: $LISTEN"; else warn "Xray не слушает ни одного порта"; fi
    if command -v docker >/dev/null 2>&1; then
        local rc
        rc="$(docker inspect -f '{{.RestartCount}}' remnanode 2>/dev/null)"
        if [ -z "$rc" ]; then info "Контейнер remnanode не найден"
        elif [ "$rc" -gt 0 ]; then warn "Контейнер remnanode перезапускался сам: $rc раз"
        else ok "Контейнер remnanode сам не перезапускался"; fi
    fi
    # Разрешает ли контейнер имена: без этого Reality не доходит до сайта
    # маскировки (target задан именем) и мост обрывает каждое соединение.
    if command -v docker >/dev/null 2>&1 && docker exec remnanode sh -c 'command -v getent' >/dev/null 2>&1; then
        if docker exec remnanode getent hosts cloudflare.com >/dev/null 2>&1; then ok "Контейнер разрешает имена (DNS работает)"
        else warn "Контейнер не разрешает имена (DNS): Reality с target в виде имени работать не будет — задайте target IP-адресом"; fi
    fi
    local oom
    oom="$(journalctl -k --since '-24h' 2>/dev/null | grep -ciE 'out of memory|oom-kill')"
    if [ "${oom:-0}" -gt 0 ]; then warn "Нехватка памяти (OOM) за сутки: $oom записей в журнале ядра"
    else ok "Нехватки памяти (OOM) за сутки не было"; fi

    hdr "Нагрузка (за ${SAMPLE} с)"
    local load1
    load1="$(cut -d' ' -f1 /proc/loadavg)"
    if gt "$load1" "$NPROC"; then warn "Load $load1 при $NPROC ядрах — очередь к процессору"
    else ok "Load $load1 при $NPROC ядрах"; fi
    if gt "$CPU_BUSY" "$MAX_CPU"; then warn "Процессор занят на ${CPU_BUSY}% (порог ${MAX_CPU}%)"
    else ok "Процессор занят на ${CPU_BUSY}%"; fi
    info "По ядрам, занято %: ${CORES_BUSY}| на разбор сети (softirq) %: ${CORES_SOFT}"
    if gt "$CPU_STEAL" "$MAX_STEAL"; then warn "Хостер отбирает ${CPU_STEAL}% процессора (steal, порог ${MAX_STEAL}%)"
    else ok "Хостер отбирает ${CPU_STEAL}% процессора (steal)"; fi
    info "Xray: ${XRAY_CPU}% CPU (100% = одно ядро), память $(xray_rss_mb) МБ"
    info "Трафик: приём ${RX_MBIT} Мбит/с, отдача ${TX_MBIT} Мбит/с"
    local avail
    avail="$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END {printf "%d", 100 * a / t}' /proc/meminfo)"
    if [ "$avail" -lt 15 ]; then warn "Свободной памяти осталось ${avail}%"
    else ok "Свободной памяти ${avail}%"; fi
    local sw du ctc ctm
    sw="$(awk '/^SwapTotal:/ {t = $2} /^SwapFree:/ {f = $2} END {printf "%d", (t - f) / 1024}' /proc/meminfo)"
    if [ "${sw:-0}" -gt 200 ]; then warn "В swap ушло ${sw} МБ — серверу не хватает оперативной памяти"
    else ok "Swap почти не используется (${sw:-0} МБ)"; fi
    du="$(df -P / 2>/dev/null | awk 'NR == 2 {sub(/%/, "", $5); print $5}')"
    if [ "${du:-0}" -gt 85 ]; then warn "Диск занят на ${du}%"
    else ok "Диск занят на ${du:-?}%"; fi
    ctc="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)"
    ctm="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
    if [ -n "$ctc" ] && [ "${ctm:-0}" -gt 0 ]; then
        if [ $((100 * ctc / ctm)) -gt 80 ]; then warn "Таблица соединений ядра (conntrack) заполнена: $ctc из $ctm — новые соединения будут отбрасываться"
        else ok "Таблица соединений ядра (conntrack): $ctc из $ctm"; fi
    fi

    hdr "Качество сети"
    if gt "$RETR_PCT" "$MAX_RETR"; then warn "Повторных отправок пакетов ${RETR_PCT}% (порог ${MAX_RETR}%)"
    else ok "Повторных отправок пакетов ${RETR_PCT}%"; fi
    local ld lo
    ld="$(netstat_val ListenDrops)"; lo="$(netstat_val ListenOverflows)"
    info "Отброшено новых подключений с загрузки сервера: ${ld:-0} (переполнений очереди: ${lo:-0})"

    if [ "$ROLE" = "client" ]; then
        hdr "Клиентские соединения"
        local p t n k s d pct perip
        for p in $CLIENT_PORTS; do
            has_port "$p" || { info "Порт $p: Xray не слушает"; continue; }
            read -r t n <<< "$(conn_stat "$p")"
            if [ "$t" -eq 0 ]; then info "Порт $p: слушает, подключений нет"; continue; fi
            perip="$(awk -v t="$t" -v n="$n" 'BEGIN {printf "%.1f", t / n}')"
            if [ "$p" = "443" ] && gt "$perip" "$MAX_PER_IP"; then
                warn "Порт $p: $t соединений, $n IP, на IP $perip (порог $MAX_PER_IP) — xmux не действует или копятся мёртвые"
            else
                ok "Порт $p: $t соединений, $n IP, на IP $perip"
            fi
            if [ "$t" -ge 20 ]; then
                k="$(keepalive_count "$p")"; pct=$((100 * k / t))
                if [ "$pct" -lt "$MIN_KEEPALIVE_PCT" ]; then warn "Порт $p: keepalive только у ${pct}% соединений — проверь sockopt в инбаунде"
                else ok "Порт $p: keepalive у ${pct}% соединений"; fi
                read -r s d <<< "$(silent_stat "$p")"
                pct=$((s ? 100 * d / s : 0))
                if [ "$p" = "443" ] && [ "$pct" -gt "$MAX_SILENT_PCT" ]; then
                    warn "Порт $p: ${pct}% соединений молчат дольше 10 минут (порог ${MAX_SILENT_PCT}%)"
                else
                    info "Порт $p: молчат дольше 10 минут ${pct}%"
                fi
            fi
        done
    fi

    hdr "Стык вход → мост (порт $BRIDGE_PORT)"
    local pipes
    pipes="$(bridge_pipes)"
    if [ "$ROLE" = "bridge" ]; then
        if [ "$pipes" -eq 0 ]; then warn "От входных нод нет ни одного соединения"
        else
            est sport "$BRIDGE_PORT" | awk '{sub(/:[0-9]+$/, "", $4); c[$4]++}
                END {for (ip in c) {v = ip; gsub(/^\[::ffff:|\]$/, "", v); print c[ip], v}}' | while read -r cnt ip; do
                if [ "$cnt" -gt "$MAX_BRIDGE_PIPES" ]; then echo "  ⚠️  От входа $ip: $cnt соединений (порог $MAX_BRIDGE_PIPES) — xmux на входе не действует"
                else echo "  ✅ От входа $ip: $cnt соединений"; fi
            done
            [ "$pipes" -gt "$MAX_BRIDGE_PIPES" ] && WARNS=$((WARNS + 1))
        fi
    elif [ "$pipes" -eq 0 ]; then
        info "Соединений к мосту нет (нода прямого выхода)"
    elif [ "$pipes" -gt "$MAX_BRIDGE_PIPES" ]; then
        warn "К мосту $pipes соединений (порог $MAX_BRIDGE_PIPES) — xmux в outbound не действует"
    else
        ok "К мосту $pipes соединений"
    fi

    hdr "Настройки сервера"
    # RPS: нужен, если ядер больше, чем очередей у сетевой карты
    if [ -n "$IF" ] && [ -d "/sys/class/net/$IF/queues" ]; then
        local q mask
        q="$(ls -d /sys/class/net/"$IF"/queues/rx-* 2>/dev/null | wc -l)"
        mask="$(tr -d ',0' < "/sys/class/net/$IF/queues/rx-0/rps_cpus" 2>/dev/null)"
        if [ "$NPROC" -le 1 ] || [ "$q" -ge "$NPROC" ]; then ok "RPS не нужен (очередей сетевой карты: $q, ядер: $NPROC)"
        elif [ -n "$mask" ]; then ok "RPS включён (маска $(cat "/sys/class/net/$IF/queues/rx-0/rps_cpus"))"
        else info "RPS выключен: у сетевой карты $q очередь на $NPROC ядер — входящую сеть разбирает одно ядро"; fi
    fi
    local gogc gml rss lim
    gogc="$(xray_env GOGC)"; gml="$(xray_env GOMEMLIMIT)"; rss="$(xray_rss_mb)"
    if [ -n "$PID" ]; then
        info "GOGC=${gogc:-не задан}, GOMEMLIMIT=${gml:-не задан}"
        if [ -n "$gml" ] && [ -n "$rss" ]; then
            lim="$(to_mb "$gml")"
            if [ "$lim" -gt 0 ] && [ $((100 * rss / lim)) -gt "$MAX_RSS_PCT" ]; then
                warn "Память Xray $rss МБ — это $((100 * rss / lim))% от лимита $lim МБ: сборщик мусора работает на износ"
            elif [ "$lim" -gt 0 ]; then
                ok "Память Xray $rss МБ из лимита $lim МБ ($((100 * rss / lim))%)"
            fi
        fi
    fi
    local cc qd
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"; qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    if [ "$cc" = "bbr" ]; then ok "Алгоритм TCP: bbr, очередь: $qd"
    else warn "Алгоритм TCP: ${cc:-?} (по стандарту bbr)"; fi

    if ss -tln 2>/dev/null | grep -q ':1080 '; then
        hdr "Psiphon"
        local viap outb
        viap="$(est dport 1080 | wc -l)"
        outb="$(ss -tn state established "( sport != :$BRIDGE_PORT and sport != :2222 and sport != :1080 )" 2>/dev/null | awk '$1 ~ /^[0-9]+$/' | wc -l)"
        ok "Psiphon слушает порт 1080"
        info "Сейчас через Psiphon $viap соединений из $outb исходящих — должна быть малая доля (только нейросети)"
    fi
    ip link show warp >/dev/null 2>&1 && info "Интерфейс warp есть"

    hdr "Firewall"
    if command -v ufw >/dev/null 2>&1; then
        local st
        st="$(ufw status 2>/dev/null)"
        if echo "$st" | grep -q '^Status: active'; then
            ok "ufw включён"
            if [ "$ROLE" = "bridge" ]; then
                local allowed
                allowed="$(echo "$st" | awk -v p="$BRIDGE_PORT/tcp" '$1 == p {f = ($3 == "IN") ? $4 : $3; print f}' | tr '\n' ' ')"
                if echo "$st" | grep -E "^$BRIDGE_PORT/tcp" | grep -q 'Anywhere'; then
                    warn "Порт моста $BRIDGE_PORT открыт для всех — должен быть открыт только для входных нод"
                elif [ -z "${allowed// /}" ]; then
                    warn "Порт моста $BRIDGE_PORT не открыт ни для одной входной ноды — мост недоступен. Открыть: bridge-allow <IP_ВХОДНОЙ_НОДЫ>"
                else
                    ok "Порт моста $BRIDGE_PORT открыт только для: $allowed"
                fi
            fi
        else
            warn "ufw выключен"
        fi
    fi

    hdr "Итог"
    if [ "$WARNS" -eq 0 ]; then echo "  ✅ Замечаний нет"
    else echo "  ⚠️  Замечаний: $WARNS (строки с ⚠️ выше)"; fi
    if [ -f "$CRON" ]; then echo "  Ежечасная запись включена, журнал: node-check --history"
    else echo "  Ежечасная запись выключена. Включить: node-check --install"; fi
    echo ""
}

# -----------------------------------------------------------------------------
#  Точка входа
# -----------------------------------------------------------------------------
case "${1:-}" in
    --log) do_log ;;
    --history)
        [ -s "$LOG" ] || die "Журнал пуст: $LOG"
        if command -v column >/dev/null 2>&1; then column -t "$LOG"; else cat "$LOG"; fi ;;
    --install)
        echo "0 * * * * root $SELF --log" > "$CRON"
        do_log
        echo "✅ Ежечасная запись включена. Первый замер записан."
        echo "   Журнал: node-check --history    Выключить: node-check --uninstall" ;;
    --uninstall)
        rm -f "$CRON"
        echo "✅ Ежечасная запись выключена. Журнал остался: $LOG" ;;
    "") do_report ;;
    *) die "Неизвестный режим: $1. Допустимо: --log, --history, --install, --uninstall" ;;
esac
