#!/usr/bin/env bash
# =============================================================================
#  mynode — единая точка входа для скриптов SG VPN  (v3)
#
#  Изменения против v2:
#   - Новые команды: check (проверка ноды, scripts/node-check.sh) и
#     bench (проверка сервера хостера, scripts/host-bench.sh).
#   - Меню: "mynode" без аргументов в терминале или "mynode menu".
#     У каждого пункта указано, какую нагрузку он создаёт на сервер.
#   - check и bench ставят свой скрипт в /usr/local/sbin (node-check,
#     host-bench): ежечасные замеры по cron вызывают их оттуда.
#
#  Изменения v2 против v1:
#   - Временные файлы гарантированно чистятся при ЛЮБОМ выходе.
#   - install-node.sh принимает флаг --panel-ip=IP как альтернативу
#     переменной MYNODE_PANEL_IP.
#
#  Команды:
#    install         Настройка и установка Linux-ноды (на сервере, root)
#    check           Проверка ноды: нагрузка, соединения, настройки (root)
#    bench           Проверка сервера хостера перед установкой ноды (root)
#    scan            Поиск Reality-таргетов (Linux или macOS)
#    menu            Меню со всеми действиями
#    self-install    Установить эту команду глобально как /usr/local/bin/mynode
#    update          Обновить локальную копию mynode
#
#  Сам этот файл не содержит ничего чувствительного и может свободно лежать
#  в публичном репозитории — реальные IP и ключи передаются переменными
#  окружения или флагами в момент запуска, а не хранятся в тексте скрипта.
# =============================================================================

set -Eeuo pipefail

# === Заполнить один раз после создания репозитория ===
GH_USER="SilkTraders"
GH_REPO="sgvpn-scripts"
GH_REF="main"     # ветка или тег. Для боевого использования лучше зафиксировать
                   # тег релиза (например "v1") — тогда 'main' можно править
                   # без риска на лету изменить то, что выполняется прямо сейчас.
# ======================================================

RAW_BASE="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_REF}"
MIRROR_BASE="https://cdn.jsdelivr.net/gh/${GH_USER}/${GH_REPO}@${GH_REF}"
SELF_DEST="/usr/local/bin/mynode"

C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_OFF=$'\e[0m'
say()  { echo "${C_OK}$*${C_OFF}"; }
warn() { echo "${C_WARN}⚠️  $*${C_OFF}"; }
die()  { echo "${C_ERR}❌ $*${C_OFF}"; exit 1; }

# --- Гарантированная очистка временных файлов ---
# Не "local tmp" внутри функций: под set -e при ненулевом коде выхода
# команда после "bash "$TMP_FILE" ..." не выполняется, и локальная
# переменная всё равно исчезает по возврату из функции — trap на EXIT
# срабатывает независимо от того, как именно скрипт завершился.
TMP_FILE=""
trap 'rm -f "${TMP_FILE:-}"' EXIT

usage() {
cat <<USAGE
mynode — управление нодами SG VPN

Команды:
  menu                Меню со всеми действиями (то же, что mynode без аргументов)
  install [опции]     Установка Linux-ноды (требует root)
  check [опции]       Проверка ноды (требует root)
  bench [опции]       Проверка сервера хостера (требует root)
  scan [опции]        Поиск Reality-таргетов (Linux и macOS)
  self-install        Установить эту команду глобально как 'mynode'
  update              Обновить локальную копию до текущей версии из репозитория
  help                Эта справка

Опции install:
  --panel-ip=IP        IP панели — альтернатива переменной MYNODE_PANEL_IP.

Опции check (нагрузку на сервер не создаёт):
  (без опций)          полный отчёт на экран, ≈10 секунд
  --history            журнал ежечасных замеров
  --install            включить ежечасные замеры
  --uninstall          выключить ежечасные замеры

Опции bench:
  --quick              без нагрузки на процессор: паспорт, сеть, IP
  (без опций)          полный тест, ≈35 секунд грузит ВСЕ ядра
  --watch              суточный тест пустого сервера (нагрузка 15 с раз в час)
  --history            журнал суточного теста
  --unwatch            выключить суточный тест
  --iperf-server [IP]  ждать замер скорости от другого своего сервера
  --iperf-client IP    замерить скорость до другого своего сервера
  --to IP:ПОРТ         добавить свою точку в замер задержки

Примеры:
  MYNODE_PANEL_IP=1.2.3.4 sudo -E mynode install
  sudo mynode check
  sudo mynode bench --quick
  mynode scan --subnet 91.234.56.0/24

Первый запуск (без установки):
  bash <(curl -fsSL ${RAW_BASE}/mynode.sh) install
  bash <(curl -fsSL ${RAW_BASE}/mynode.sh) bench --quick
USAGE
}

# fetch <путь-в-репозитории> <куда-сохранить>
# Сначала GitHub напрямую, при неудаче — зеркало jsDelivr (на случай блокировки).
fetch() {
    local path="$1" dest="$2"
    if curl -fsSL --max-time 20 -o "$dest" "${RAW_BASE}/${path}" 2>/dev/null; then
        return 0
    fi
    warn "GitHub недоступен, пробую зеркало jsDelivr..."
    curl -fsSL --max-time 20 -o "$dest" "${MIRROR_BASE}/${path}"
}

cmd_install() {
    [[ "$EUID" -eq 0 ]] || die "install требует root. Запустите: sudo -E mynode install (флаг -E сохраняет MYNODE_PANEL_IP при переходе в root; если на этом хосте всё равно не долетает — используйте sudo -E mynode install --panel-ip=IP)"
    say "Загрузка install-node.sh (${GH_REF})..."
    TMP_FILE="$(mktemp)"
    fetch "scripts/install-node.sh" "$TMP_FILE" || die "Не удалось скачать install-node.sh"
    chmod +x "$TMP_FILE"
    bash "$TMP_FILE" "$@"
}

cmd_scan() {
    say "Загрузка scan-target.sh (${GH_REF})..."
    TMP_FILE="$(mktemp)"
    fetch "scripts/scan-target.sh" "$TMP_FILE" || die "Не удалось скачать scan-target.sh"
    chmod +x "$TMP_FILE"
    bash "$TMP_FILE" "$@"
}

# run_tool <путь-в-репозитории> <имя-в-/usr/local/sbin> [аргументы]
# Ставит свежую версию скрипта в /usr/local/sbin и запускает её.
# Локальная копия нужна потому, что ежечасные замеры по cron вызывают
# именно её. Если репозиторий недоступен, а копия уже есть — работает она.
run_tool() {
    local path="$1" name="$2"; shift 2
    local dest="/usr/local/sbin/$name"
    [[ "$(uname -s)" == "Linux" ]] || die "$name работает только на Linux-сервере."
    [[ "$EUID" -eq 0 ]] || die "$name требует root — запустите ту же команду через sudo."
    TMP_FILE="$(mktemp)"
    if fetch "$path" "$TMP_FILE" && [[ -s "$TMP_FILE" ]]; then
        install -m 755 "$TMP_FILE" "$dest"
        rm -f "$TMP_FILE"   # меню вызывает run_tool в подоболочке, trap EXIT там не действует
    elif [[ -x "$dest" ]]; then
        warn "Не удалось скачать $path — запускаю уже установленную копию."
    else
        die "Не удалось скачать $path"
    fi
    "$dest" "$@"
}

cmd_check() { run_tool "scripts/node-check.sh" "node-check" "$@"; }
cmd_bench() { run_tool "scripts/host-bench.sh" "host-bench" "$@"; }

# --- Меню ---
# Справа у каждого пункта — нагрузка, которую он создаёт на сервер.
# Пункты с пометкой "ВСЕ ЯДРА" запускать только на сервере без клиентов:
# host-bench сам спросит подтверждение, если увидит работающий Xray.
ask() { local v; read -r -p "$1" v; echo "$v"; }

cmd_menu() {
    local c ip port sni
    while true; do
        cat <<MENU

================  mynode  ================        нагрузка на сервер
 --- Рабочая нода ---
  1) Проверка ноды                                нет (замер 10 с)
  2) Журнал ежечасных замеров ноды                нет
  3) Ежечасные замеры ноды: включить              нет
  4) Ежечасные замеры ноды: выключить             нет
  5) Проверка моста с входной ноды                нет
 --- Новый сервер (до установки ноды) ---
  6) Тест хостера: быстрый                        канал, ≈150 МБ трафика
  7) Тест хостера: полный                         ВСЕ ЯДРА ≈35 с
  8) Суточный тест хостера: включить              ВСЕ ЯДРА 15 с раз в час
  9) Суточный тест хостера: журнал                нет
 10) Суточный тест хостера: выключить             нет
 11) Скорость между серверами: ждать замер        канал, 20 с
 12) Скорость между серверами: запустить замер    канал, 20 с
 --- Прочее ---
 13) Поиск Reality-таргетов                       сканирует подсеть
 14) Установка ноды
  0) Выход
MENU
        c="$(ask 'Номер: ')"
        # В подоболочке: ошибка одного пункта не закрывает меню.
        case "$c" in
            1)  ( cmd_check ) ;;
            2)  ( cmd_check --history ) ;;
            3)  ( cmd_check --install ) ;;
            4)  ( cmd_check --uninstall ) ;;
            5)  ip="$(ask 'IP моста: ')"; port="$(ask 'Порт моста [2087]: ')"; sni="$(ask 'SNI моста (можно пусто): ')"
                if command -v bridge-check >/dev/null 2>&1; then ( bridge-check "$ip" "${port:-2087}" $sni )
                else warn "bridge-check не установлен (ставится скриптом install)."; fi ;;
            6)  ( cmd_bench --quick ) ;;
            7)  ( cmd_bench ) ;;
            8)  ( cmd_bench --watch ) ;;
            9)  ( cmd_bench --history ) ;;
            10) ( cmd_bench --unwatch ) ;;
            11) ip="$(ask 'IP сервера, с которого придёт замер (нужен, если включён ufw): ')"
                # shellcheck disable=SC2086
                ( cmd_bench --iperf-server $ip ) ;;
            12) ip="$(ask 'IP сервера, который ждёт замер: ')"; ( cmd_bench --iperf-client "$ip" ) ;;
            13) ( cmd_scan ) ;;
            14) ( cmd_install ) ;;
            0|q|"") return 0 ;;
            *)  warn "Нет такого пункта." ;;
        esac || true
        read -r -p "Enter — вернуться в меню… " _
    done
}

cmd_self_install() {
    say "Загрузка mynode.sh (${GH_REF})..."
    TMP_FILE="$(mktemp)"
    fetch "mynode.sh" "$TMP_FILE" || die "Не удалось скачать mynode.sh"
    chmod +x "$TMP_FILE"

    local dest_dir; dest_dir="$(dirname "$SELF_DEST")"
    if [[ -w "$dest_dir" ]]; then
        mv "$TMP_FILE" "$SELF_DEST"
    elif command -v sudo >/dev/null 2>&1; then
        say "Нужны права на запись в $dest_dir — запрошу sudo."
        sudo mv "$TMP_FILE" "$SELF_DEST"
        sudo chmod +x "$SELF_DEST"
    else
        die "Нет прав на запись в $dest_dir и нет sudo. Скопируйте файл вручную."
    fi
    chmod +x "$SELF_DEST" 2>/dev/null || true

    say "Готово. Команда 'mynode' установлена."
    echo "Проверьте: mynode help"

    # /usr/local/bin обычно уже в PATH, но на некоторых системах — нет.
    if ! command -v mynode >/dev/null 2>&1; then
        warn "$dest_dir не найден в PATH."
        echo "Добавьте в ~/.zshrc или ~/.bashrc:"
        echo '  export PATH="/usr/local/bin:$PATH"'
    fi
}

cmd_update() {
    TMP_FILE="$(mktemp)"
    fetch "mynode.sh" "$TMP_FILE" || die "Не удалось скачать актуальную версию"
    chmod +x "$TMP_FILE"

    if [[ -f "$SELF_DEST" ]] && diff -q "$SELF_DEST" "$TMP_FILE" >/dev/null 2>&1; then
        say "Уже установлена актуальная версия (${GH_REF})."
        return 0
    fi

    if [[ -f "$SELF_DEST" ]]; then
        warn "Найдены отличия от установленной версии:"
        diff "$SELF_DEST" "$TMP_FILE" || true
        echo ""
    fi

    read -r -p "Установить эту версию как $SELF_DEST? (y/N): " ans
    if ! [[ "$ans" =~ ^[Yy]$ ]]; then
        say "Отменено."; return 0
    fi

    local dest_dir; dest_dir="$(dirname "$SELF_DEST")"
    if [[ -w "$dest_dir" ]]; then
        mv "$TMP_FILE" "$SELF_DEST"
    else
        sudo mv "$TMP_FILE" "$SELF_DEST"
    fi
    chmod +x "$SELF_DEST" 2>/dev/null || sudo chmod +x "$SELF_DEST"
    say "Обновлено до ${GH_REF}."
}

# Без аргументов: в терминале — меню, иначе (например, через pipe) — справка.
if [[ $# -eq 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then set -- menu; else set -- help; fi
fi

case "$1" in
    install)      shift; cmd_install "$@" ;;
    check)        shift; cmd_check "$@" ;;
    bench)        shift; cmd_bench "$@" ;;
    scan)         shift; cmd_scan "$@" ;;
    menu)         cmd_menu ;;
    self-install) cmd_self_install ;;
    update)       cmd_update ;;
    help|-h|--help) usage ;;
    *) echo "Неизвестная команда: $1"; echo ""; usage; exit 1 ;;
esac
