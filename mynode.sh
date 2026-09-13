#!/usr/bin/env bash
# =============================================================================
#  mynode — единая точка входа для скриптов SG VPN  (v2)
#
#  Изменения против v1:
#   - Временные файлы гарантированно чистятся при ЛЮБОМ выходе (успех, error
#     через set -e, Ctrl+C) — раньше "rm -f "$tmp"" после "bash "$tmp" "$@""
#     не выполнялся при ненулевом коде выхода из-за set -e, и tmp-файлы
#     копились в /tmp при каждой неудачной установке/сканировании.
#   - install-node.sh теперь принимает флаг --panel-ip=IP как альтернативу
#     переменной MYNODE_PANEL_IP — на случай, если sudo -E на конкретном
#     хосте не пробрасывает переменные окружения (сурового sudoers).
#     Задокументировано в usage() и подсказке при отсутствии root.
#
#  Подкоманды:
#    install         Настройка и установка Linux-ноды (запускать на сервере, root)
#    scan            Поиск Reality-таргетов (Linux или macOS)
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
  install [опции]     Установка Linux-ноды (требует root)
  scan [опции]        Поиск Reality-таргетов (Linux и macOS)
  self-install        Установить эту команду глобально как 'mynode'
  update              Обновить локальную копию до текущей версии из репозитория
  help                Эта справка

Опции install:
  --panel-ip=IP        IP панели — альтернатива переменной MYNODE_PANEL_IP.
                        Полезно, если sudo -E на этом хосте не пробрасывает
                        переменные окружения (см. примеры ниже).

Примеры:
  MYNODE_PANEL_IP=1.2.3.4 sudo -E mynode install
  sudo -E mynode install --panel-ip=1.2.3.4
  mynode scan --subnet 91.234.56.0/24

Первый запуск (без установки):
  bash <(curl -fsSL ${RAW_BASE}/mynode.sh) install
  bash <(curl -fsSL ${RAW_BASE}/mynode.sh) scan
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

case "${1:-help}" in
    install)      shift; cmd_install "$@" ;;
    scan)         shift; cmd_scan "$@" ;;
    self-install) cmd_self_install ;;
    update)       cmd_update ;;
    help|-h|--help) usage ;;
    *) echo "Неизвестная команда: $1"; echo ""; usage; exit 1 ;;
esac
