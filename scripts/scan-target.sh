#!/usr/bin/env bash
# =============================================================================
#  REALITY TARGET SCANNER  (v2)
#
#  Ищет кандидатов на роль target/dest для VLESS-Reality среди соседей
#  по подсети: настоящий сертификат, настоящий сайт, тот же датацентр.
#
#  Главные отличия от v1:
#   - сканируется именно /24, а не infinity mode от одного IP
#   - проверка на "фантомы": домен обязан резолвиться в ту же подсеть
#   - батч-обработка вместо запуска python на каждый IP
#   - параллельные сетевые проверки (кратно быстрее)
#   - работает и на Linux-ноде, и локально на macOS
#   - results.csv сохраняется, есть режим переанализа без пересканирования
#
#  ВНИМАНИЕ: авторы сканера рекомендуют запускать его локально, а не на VPS —
#  сканирование из облака может привести к пометке сервера у хостера.
#  Для этого есть флаг --subnet: сканируйте подсеть ноды со своей машины.
# =============================================================================

set -uo pipefail

# --- Параметры по умолчанию ---
SUBNET=""
THREADS=100
SCAN_TIMEOUT=180
PARALLEL=20
TOP_N=15
REUSE=0
KEEP_CSV=1

WORKDIR="$(pwd)"
CSV="$WORKDIR/results.csv"
TMPD="$(mktemp -d)"
SCANNER="$TMPD/RealiTLScanner"
trap 'rm -rf "$TMPD"' EXIT

C_G=$'\e[0;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[0;31m'; C_D=$'\e[1;30m'; C_0=$'\e[0m'

usage() {
cat <<'USAGE'
Использование: ./reality-target-scan.sh [опции]

  --subnet 1.2.3.0/24   Подсеть для сканирования.
                        По умолчанию — /24 собственного внешнего IP.
                        Укажите явно, чтобы сканировать подсеть ноды
                        со своей локальной машины (безопаснее для VPS).
  --reuse               Пропустить RealiTLScanner, взять IP/домены из
                        results.csv. DNS/whitelist/HTTP/OCSP-проверки
                        всё равно выполняются заново при каждом запуске.
  --top N               Сколько кандидатов показать (по умолчанию 15)
  --threads N           Потоков сканера (по умолчанию 100)
  --parallel N          Параллельных сетевых проверок (по умолчанию 20)
  --scan-timeout SEC    Лимит на сканирование (по умолчанию 180)
  -h, --help            Эта справка
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subnet)       SUBNET="${2:-}"; shift 2;;
        --reuse)        REUSE=1; shift;;
        --top)          TOP_N="${2:-15}"; shift 2;;
        --threads)      THREADS="${2:-100}"; shift 2;;
        --parallel)     PARALLEL="${2:-20}"; shift 2;;
        --scan-timeout) SCAN_TIMEOUT="${2:-180}"; shift 2;;
        -h|--help)      usage; exit 0;;
        *) echo "Неизвестный параметр: $1"; usage; exit 1;;
    esac
done

# =============================================================================
#  ПЛАТФОРМА И ЗАВИСИМОСТИ
# =============================================================================

OS="$(uname -s)"
ARCH="$(uname -m)"

# На macOS coreutils-овский timeout называется gtimeout и ставится через brew.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi

MISSING=""
for dep in curl openssl awk sort python3; do
    command -v "$dep" >/dev/null 2>&1 || MISSING="$MISSING $dep"
done
if [[ -n "$MISSING" ]]; then
    echo "${C_R}❌ Не хватает утилит:$MISSING${C_0}"
    [[ "$OS" == "Darwin" ]] && echo "   macOS: brew install coreutils openssl python3"
    exit 1
fi
if [[ -z "$TIMEOUT_BIN" ]]; then
    echo "${C_Y}⚠️  Нет timeout/gtimeout. На macOS: brew install coreutils${C_0}"
    echo "    Сканирование пойдёт без жёсткого лимита времени."
fi

# =============================================================================
#  ОПРЕДЕЛЕНИЕ ПОДСЕТИ
# =============================================================================

MY_IP="$(curl -s4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"

if [[ -z "$SUBNET" ]]; then
    if [[ -z "$MY_IP" ]]; then
        echo "${C_R}❌ Не удалось определить внешний IP и не задан --subnet.${C_0}"
        exit 1
    fi
    # КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ: сканируем /24, а не одиночный IP.
    # При одиночном IP сканер уходит в infinity mode и перебирает адреса
    # за пределами подсети, пока его не обрубит timeout.
    SUBNET="${MY_IP%.*}.0/24"
    echo "${C_Y}⚠️  Сканирование запущено с этой же машины ($MY_IP).${C_0}"
    echo "    Если это боевая нода — хостер может счесть это сканированием сети."
    echo "    Безопаснее: запустить локально с --subnet ${SUBNET}"
    echo ""
fi

if ! [[ "$SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo "${C_R}❌ Некорректный формат подсети: $SUBNET (ожидается 1.2.3.0/24)${C_0}"
    exit 1
fi

echo "🎯 Подсеть: $SUBNET"
[[ -n "$MY_IP" ]] && echo "📍 Свой IP: $MY_IP (будет исключён из кандидатов)"
echo ""

# =============================================================================
#  СКАНЕР
# =============================================================================

download_scanner() {
    echo "📥 Загрузка RealiTLScanner..."
    local base asset url
    base="https://github.com/XTLS/RealiTLScanner/releases/latest/download"

    case "$OS/$ARCH" in
        Linux/x86_64)          asset="RealiTLScanner-linux-amd64";;
        Linux/aarch64|Linux/arm64) asset="RealiTLScanner-linux-arm64";;
        Darwin/arm64)          asset="RealiTLScanner-darwin-arm64-v8a";;
        Darwin/x86_64)         asset="RealiTLScanner-darwin-64";;
        *) echo "${C_R}❌ Неизвестная платформа $OS/$ARCH${C_0}"; return 1;;
    esac

    url="$base/$asset"
    if ! curl -fsSL --max-time 120 -o "$SCANNER" "$url"; then
        echo "${C_R}❌ Не удалось скачать $url${C_0}"
        echo "   Если GitHub недоступен с этой машины — скачайте бинарник вручную"
        echo "   и положите рядом как ./RealiTLScanner"
        return 1
    fi
    chmod +x "$SCANNER"

    # Проверяем, что скачался бинарник, а не HTML-страница ошибки
    local size
    size="$(wc -c < "$SCANNER" | tr -d ' ')"
    if [[ "$size" -lt 500000 ]]; then
        echo "${C_R}❌ Файл подозрительно мал ($size байт) — вероятно, это не бинарник.${C_0}"
        rm -f "$SCANNER"
        return 1
    fi
    echo "${C_G}✅ Сканер загружен ($((size/1024)) KB)${C_0}"
}

if [[ "$REUSE" -eq 0 ]]; then
    [[ -x "$SCANNER" ]] || download_scanner || exit 1
fi

# =============================================================================
#  БЕЛЫЕ СПИСКИ
# =============================================================================

WL_BASE="https://raw.githubusercontent.com/hxehex/russia-mobile-internet-whitelist/main"

fetch_list() {
    local url="$1" dest="$2" name="$3"
    if curl -fsSL --max-time 30 -o "$dest" "$url" 2>/dev/null; then
        # Отсекаем случай, когда вместо списка пришла HTML-страница 404
        if head -c 200 "$dest" | grep -qi "<!DOCTYPE\|<html"; then
            echo "${C_Y}⚠️  $name: вместо списка пришёл HTML. Проверка по нему отключена.${C_0}"
            : > "$dest"; return 1
        fi
        local n; n="$(grep -cvE '^\s*(#|$)' "$dest" 2>/dev/null || echo 0)"
        if [[ "$n" -lt 5 ]]; then
            echo "${C_Y}⚠️  $name: подозрительно мало строк ($n). Проверка отключена.${C_0}"
            : > "$dest"; return 1
        fi
        echo "${C_G}✅ $name: $n записей${C_0}"
        return 0
    fi
    echo "${C_Y}⚠️  $name недоступен. Проверка по нему отключена.${C_0}"
    : > "$dest"; return 1
}

echo "📥 Белые списки ТСПУ..."
fetch_list "$WL_BASE/ipwhitelist.txt"   "$TMPD/wl_ip.txt"   "IP-whitelist"   || true
fetch_list "$WL_BASE/cidrwhitelist.txt" "$TMPD/wl_cidr.txt" "CIDR-whitelist" || true
fetch_list "$WL_BASE/whitelist.txt"     "$TMPD/wl_sni.txt"  "SNI-whitelist"  || true
echo ""

# =============================================================================
#  СКАНИРОВАНИЕ
# =============================================================================

if [[ "$REUSE" -eq 1 ]]; then
    if [[ ! -s "$CSV" ]]; then
        echo "${C_R}❌ --reuse указан, но $CSV пуст или отсутствует.${C_0}"
        exit 1
    fi
    echo "♻️  Режим переанализа: используем существующий $CSV"
else
    echo "🔍 Сканирование $SUBNET (лимит ${SCAN_TIMEOUT}с)..."
    rm -f "$CSV"
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" -k 5 "$SCAN_TIMEOUT" "$SCANNER" \
            -addr "$SUBNET" -port 443 -thread "$THREADS" -timeout 3 -out "$CSV" \
            >/dev/null 2>&1 || true
    else
        "$SCANNER" -addr "$SUBNET" -port 443 -thread "$THREADS" -timeout 3 -out "$CSV" \
            >/dev/null 2>&1 || true
    fi
fi

if [[ ! -s "$CSV" ]]; then
    echo "${C_R}❌ Сканер не вернул результатов.${C_0}"
    echo "   Возможные причины: подсеть пуста, исходящий 443 фильтруется,"
    echo "   или бинарник не запустился (проверьте: $SCANNER -addr 1.1.1.1)"
    exit 1
fi

TOTAL_RAW="$(( $(wc -l < "$CSV") - 1 ))"
[[ "$TOTAL_RAW" -lt 1 ]] && { echo "${C_R}❌ В CSV только заголовок.${C_0}"; exit 1; }
echo "${C_G}✅ Живых TLS-хостов: $TOTAL_RAW${C_0}"
echo "   (сканер уже отфильтровал всё, что не TLS 1.3 + h2)"
echo ""

# =============================================================================
#  РАЗБОР CSV ПО ЗАГОЛОВКУ
# =============================================================================
# Вытаскиваем домен из нужной КОЛОНКИ, а не regex'ом по всей строке:
# regex ловил первый попавшийся домен, включая домен издателя сертификата.

HEADER="$(head -n 1 "$CSV")"
IP_COL="$(echo "$HEADER" | awk -F',' '{for(i=1;i<=NF;i++){g=tolower($i); gsub(/[" ]/,"",g); if(g=="ip"){print i; exit}}}')"
DOM_COL="$(echo "$HEADER" | awk -F',' '{for(i=1;i<=NF;i++){g=tolower($i); gsub(/[" ]/,"",g); if(g ~ /domain/){print i; exit}}}')"
[[ -z "$IP_COL"  ]] && IP_COL=1
[[ -z "$DOM_COL" ]] && DOM_COL=3

# =============================================================================
#  ДЕШЁВЫЕ ФИЛЬТРЫ
# =============================================================================
# CDN и крупные площадки: общий IP на тысячи сайтов, характерный TLS-профиль.
BIG_CORP='apple\.com|cloudflare|yahoo|google|microsoft|amazon|aws|yandex|vk\.com|mail\.ru|facebook|netflix|akamai|fastly|cdn|github|bing|instagram|twitter|x\.com|gcore|selectel|bitrix'
# Техпанели хостера: живут на том же железе, но это не "сайт", маскировка слабая.
TECH_PANELS='^server[0-9]*\.|^cp[0-9]*\.|^host[0-9]*\.|^autoconfig\.|^autodiscover\.|^webmail\.|^cpanel\.|^plesk\.|^ispmanager\.|^directadmin\.|^mail\.|^ns[0-9]*\.|^mx[0-9]*\.|^smtp\.|^imap\.|^vpn\.|^test\.|^dev\.|^staging\.'

tail -n +2 "$CSV" | tr -d '"' | awk -F',' -v ic="$IP_COL" -v dc="$DOM_COL" '
    {
        ip=$ic; dom=$dc
        gsub(/^[ \t]+|[ \t]+$/,"",ip); gsub(/^[ \t]+|[ \t]+$/,"",dom)
        sub(/^\*\./,"",dom)
        dom=tolower(dom)
        if (ip=="" || dom=="") next
        if (dom ~ /^[0-9.]+$/) next
        if (dom !~ /^[a-z0-9.-]+\.[a-z]{2,}$/) next
        print ip "\t" dom
    }' | sort -u > "$TMPD/parsed.tsv"

# Исключаем собственный IP: использовать сам себя как dest — петля.
if [[ -n "$MY_IP" ]]; then
    grep -v "^${MY_IP}	" "$TMPD/parsed.tsv" > "$TMPD/p2.tsv" || true
    mv "$TMPD/p2.tsv" "$TMPD/parsed.tsv"
fi

grep -ivE "$BIG_CORP" "$TMPD/parsed.tsv" > "$TMPD/p3.tsv" || true
awk -F'\t' -v pat="$TECH_PANELS" 'tolower($2) !~ pat' "$TMPD/p3.tsv" > "$TMPD/candidates.tsv" || true

CAND_N="$(wc -l < "$TMPD/candidates.tsv" | tr -d ' ')"
echo "🧹 После отсева CDN, техпанелей и дублей: $CAND_N кандидатов"
[[ "$CAND_N" -lt 1 ]] && { echo "${C_R}❌ Не осталось кандидатов.${C_0}"; exit 1; }
echo ""

# =============================================================================
#  БАТЧ: БЕЛЫЕ СПИСКИ + DNS-ВЕРИФИКАЦИЯ
# =============================================================================
# Раньше python запускался на КАЖДЫЙ IP. Теперь один проход на весь список.
# Плюс добавлена проверка на "фантомы": домен должен резолвиться в ту же
# подсеть, где он найден. Иначе цензор видит несоответствие — сертификат
# отдаёт ваш сервер, а домен по DNS живёт в другом датацентре.

cat > "$TMPD/enrich.py" <<'PYEOF'
import ipaddress, os, socket, sys
from concurrent.futures import ThreadPoolExecutor

cand_file, ip_wl, cidr_wl, sni_wl = sys.argv[1:5]

def load_lines(p):
    if not p or not os.path.exists(p): return []
    out = []
    with open(p, encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line.split()[0].lower())
    return out

ip_set = set(load_lines(ip_wl))
sni_set = set(load_lines(sni_wl))

nets = []
for c in load_lines(cidr_wl):
    try:
        nets.append(ipaddress.ip_network(c, strict=False))
    except ValueError:
        pass

def ip_whitelisted(ip):
    if ip in ip_set:
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in n for n in nets)

def sni_whitelisted(dom):
    if dom in sni_set:
        return True
    # Домен считается в списке, если в списке есть его родительская зона
    parts = dom.split(".")
    for i in range(1, len(parts) - 1):
        if ".".join(parts[i:]) in sni_set:
            return True
    return False

def same_subnet(ip_a, ip_b):
    try:
        na = ipaddress.ip_network(ip_a + "/24", strict=False)
        return ipaddress.ip_address(ip_b) in na
    except ValueError:
        return False

def resolve(dom):
    try:
        socket.setdefaulttimeout(4)
        infos = socket.getaddrinfo(dom, 443, socket.AF_INET, socket.SOCK_STREAM)
        return sorted({i[4][0] for i in infos})
    except Exception:
        return []

rows = []
with open(cand_file, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        ip, _, dom = line.partition("\t")
        if ip and dom:
            rows.append((ip, dom))

def work(row):
    ip, dom = row
    resolved = resolve(dom)
    if not resolved:
        dns_state = "NXDOMAIN"
    elif ip in resolved:
        dns_state = "EXACT"          # домен резолвится ровно в этот IP
    elif any(same_subnet(ip, r) for r in resolved):
        dns_state = "SUBNET"         # резолвится в ту же /24
    else:
        dns_state = "ELSEWHERE"      # фантом: живёт в другом месте
    return "\t".join([
        ip, dom,
        "1" if sni_whitelisted(dom) else "0",
        "1" if ip_whitelisted(ip) else "0",
        dns_state,
    ])

with ThreadPoolExecutor(max_workers=32) as ex:
    for line in ex.map(work, rows):
        print(line)
PYEOF

echo "🌐 Проверка белых списков и DNS (обратная верификация)..."
python3 "$TMPD/enrich.py" \
    "$TMPD/candidates.tsv" \
    "$TMPD/wl_ip.txt" "$TMPD/wl_cidr.txt" "$TMPD/wl_sni.txt" \
    > "$TMPD/enriched.tsv" 2>/dev/null || {
        echo "${C_R}❌ Ошибка в обогащении данных.${C_0}"; exit 1; }

PHANTOMS="$(awk -F'\t' '$5=="ELSEWHERE" || $5=="NXDOMAIN"' "$TMPD/enriched.tsv" | wc -l | tr -d ' ')"
echo "   Отмечено как фантомы (домен живёт не здесь): $PHANTOMS"
echo ""

# =============================================================================
#  ПАРАЛЛЕЛЬНЫЕ СЕТЕВЫЕ ПРОВЕРКИ
# =============================================================================

# Проверяем, доступны ли соседи по подсети с этой машины.
PROBE_IP="$(head -n 1 "$TMPD/enriched.tsv" | cut -f1)"
ACTIVE=1
if [[ -n "$PROBE_IP" ]]; then
    if ! curl -s -o /dev/null --max-time 4 --connect-timeout 4 "https://$PROBE_IP" -k 2>/dev/null; then
        if ! (exec 3<>"/dev/tcp/$PROBE_IP/443") 2>/dev/null; then
            ACTIVE=0
        fi
    fi
fi

if [[ "$ACTIVE" -eq 1 ]]; then
    echo "${C_G}✅ Соседи по подсети доступны — активные проверки включены${C_0}"
else
    echo "${C_Y}⚠️  Соседи недоступны с этой машины — только пассивный анализ${C_0}"
    echo "   HTTP-статус, пинг и OCSP проверить не получится."
fi
echo ""

cat > "$TMPD/check.sh" <<'CHKEOF'
#!/usr/bin/env bash
line="$1"
IFS=$'\t' read -r ip dom wl_sni wl_ip dns_state <<< "$line"

http_code="N/A"; latency=9999; ocsp="NO"; cert_ok="?"; redirect=""

if [[ "$ACTIVE_MODE" -eq 1 ]]; then
    out="$(curl -o /dev/null -s \
            -w '%{time_appconnect}|%{http_code}|%{redirect_url}' \
            --max-time 6 --connect-timeout 4 \
            --resolve "$dom:443:$ip" "https://$dom" 2>/dev/null || echo "0|000|")"
    lat_raw="${out%%|*}"
    rest="${out#*|}"
    http_code="${rest%%|*}"
    redirect="${rest#*|}"

    latency="$(awk -v l="$lat_raw" 'BEGIN{v=int(l*1000); print (v>0?v:9999)}')"

    # -checkend портируем вместо арифметики с датами: работает и в macOS
    if echo | openssl s_client -connect "$ip:443" -servername "$dom" \
            -verify_return_error 2>/dev/null \
        | openssl x509 -checkend 2592000 -noout >/dev/null 2>&1; then
        cert_ok="30d+"
    else
        cert_ok="SOON"
    fi

    if echo | openssl s_client -connect "$ip:443" -servername "$dom" -status 2>/dev/null \
        | grep -qi "OCSP Response Status: successful"; then
        ocsp="YES"
    fi
fi

# --- Скоринг ---
score=0
[[ "$wl_sni" == "1" ]] && score=$((score + 100))
[[ "$wl_ip"  == "1" ]] && score=$((score + 100))
case "$dns_state" in
    EXACT)     score=$((score + 60));;
    SUBNET)    score=$((score + 40));;
    ELSEWHERE) score=$((score - 50));;
    NXDOMAIN)  score=$((score - 80));;
esac
case "$http_code" in
    200)     score=$((score + 30));;
    30[0-9]) score=$((score + 15));;
    N/A)     score=$((score + 0));;
    *)       score=$((score - 40));;
esac
[[ "$cert_ok" == "30d+" ]] && score=$((score + 10))
[[ "$ocsp"    == "YES"  ]] && score=$((score + 5))

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$score" "$latency" "$ocsp" "$cert_ok" "$http_code" \
    "$dns_state" "$wl_sni" "$wl_ip" "$dom" "$ip" >> "$RESULT_FILE"
CHKEOF
chmod +x "$TMPD/check.sh"

RESULT_FILE="$TMPD/scored.tsv"; : > "$RESULT_FILE"
export ACTIVE_MODE="$ACTIVE" RESULT_FILE

echo "🕵️  Глубокая проверка кандидатов (потоков: $PARALLEL)..."
# xargs вместо последовательного цикла: сотня проверок по 6 секунд
# в один поток — это 10 минут, в 20 потоков — полминуты.
tr -d '\r' < "$TMPD/enriched.tsv" | xargs -P "$PARALLEL" -I{} "$TMPD/check.sh" "{}" 2>/dev/null

echo "${C_G}✅ Проверено: $(wc -l < "$RESULT_FILE" | tr -d ' ')${C_0}"
echo ""

# =============================================================================
#  ВЫВОД
# =============================================================================

echo "🏆 ЛУЧШИЕ КАНДИДАТЫ НА REALITY TARGET"

if [[ -s "$RESULT_FILE" ]]; then
    # Ширина SNI рассчитывается по реальным доменам из выводимых строк.
    # Домены НИКОГДА не обрезаются.
    DOM_WIDTH="$(sort -k1,1nr -k2,2n "$RESULT_FILE" \
        | awk -F'\t' -v top="$TOP_N" '!seen[$9]++ { if (++n <= top && length($9) > max) max=length($9) } END { if (max < 12) max=12; print max }')"
else
    DOM_WIDTH=12
fi
    TOTAL_WIDTH=$((DOM_WIDTH + 66))
    printf -v SEP '%*s' "$TOTAL_WIDTH" ''
    SEP="${SEP// /-}"

    printf '%s\n' "$SEP"
    printf " %-6s | %-6s | %-5s | %-6s | %-9s | %-${DOM_WIDTH}s | %-15s\n" \
           "SCORE" "PING" "OCSP" "CERT" "DNS" "SNI (DOMAIN)" "IP"
    printf '%s\n' "$SEP"

if [[ -s "$RESULT_FILE" ]]; then
    sort -k1,1nr -k2,2n "$RESULT_FILE" | awk -F'\t' '!seen[$9]++' | head -n "$TOP_N" \
    | while IFS=$'\t' read -r score lat ocsp cert http dns wl_sni wl_ip dom ip; do
        # В таблице используем только ASCII-значения фиксированной ширины.
        # Это исключает визуальный сдвиг колонок из-за Unicode-символов.
        ping_s="${lat}ms"; [[ "$lat" == "9999" ]] && ping_s="N/A"

        case "$dns" in
            EXACT)     c_dns="$C_G"; dns_s="EXACT";;
            SUBNET)    c_dns="$C_G"; dns_s="SUBNET";;
            ELSEWHERE) c_dns="$C_R"; dns_s="PHANTOM";;
            *)         c_dns="$C_R"; dns_s="NXDOMAIN";;
        esac

        # Домен выводится ПОЛНОСТЬЮ — ничего не обрезаем.
        dom_s="$dom"

        c_dom="$C_0"; [[ "$wl_sni" == "1" ]] && c_dom="$C_G"
        c_ip="$C_0";  [[ "$wl_ip"  == "1" ]] && c_ip="$C_G"
        c_cert="$C_0"; [[ "$cert" == "SOON" ]] && c_cert="$C_Y"

        printf " %-6s | %-6s | %-5s | ${c_cert}%-6s${C_0} | ${c_dns}%-9s${C_0} | ${c_dom}%-${DOM_WIDTH}s${C_0} | ${c_ip}%-15s${C_0}\n" \
               "$score" "$ping_s" "$ocsp" "$cert" "$dns_s" "$dom_s" "$ip"
    done
else
    echo " Ни одного кандидата не прошло проверки."
fi

printf "%s\n" "$SEP"
echo ""
echo "Как читать:"
echo "  ${C_G}Зелёный домен${C_0}  — есть в белом списке ТСПУ по SNI (доступен при шатдаунах)"
echo "  ${C_G}Зелёный IP${C_0}     — адрес в белом списке ТСПУ"
echo "  DNS EXACT     — домен резолвится ровно в этот IP, идеально"
echo "  DNS SUBNET    — резолвится в ту же /24, тоже хорошо"
echo "  ${C_R}PHANTOM${C_0}       — сертификат здесь, а сам сайт живёт в другом месте."
echo "                  Цензор это увидит при сверке. Не использовать."
echo "  CERT SOON     — сертификат истекает меньше чем через 30 дней,"
echo "                  маскировка отвалится при его смене"

if [[ "$KEEP_CSV" -eq 1 ]]; then
    echo ""
    echo "💾 Сырые результаты сохранены: $CSV"
    echo "   Переанализ без пересканирования: mynode scan --reuse"
fi
