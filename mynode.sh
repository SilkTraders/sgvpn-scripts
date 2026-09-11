#!/usr/bin/env bash
# =============================================================================
#  mynode — единая точка входа для скриптов SG VPN
#
#  Подкоманды:
#    install         Настройка и установка Linux-ноды (запускать на сервере, root)
#    scan            Поиск Reality-таргетов (Linux или macOS)
#    self-install    Установить эту команду глобально как /usr/local/bin/mynode
#    update          Обновить локальную копию mynode
#
#  Сам этот файл не содержит ничего чувствительного и может свободно лежать
#  в публичном репозитории — реальные IP и ключи передаются переменными
#  окружения в момент запуска, а не хранятся в тексте скрипта.
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

usage() {
cat <<USAGE
mynode — управление нодами SG VPN

Команды:
  install [опции]     Установка Linux-ноды (требует root)
  scan [опции]        Поиск Reality-таргетов (Linux и macOS)
  self-install        Установить эту команду глобально как 'mynode'
  update              Обновить локальную копию до текущей версии из репозитория
  help                Эта справка

Примеры:
  MYNODE_PANEL_IP=1.2.3.4 sudo -E mynode install
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
    [[ "$EUID" -eq 0 ]] || die "install требует root. Запустите: sudo -E mynode install (флаг -E сохраняет MYNODE_PANEL_IP при переходе в root)"
    local tmp; tmp="$(mktemp)"
    say "Загрузка install-node.sh (${GH_REF})..."
    fetch "scripts/install-node.sh" "$tmp" || die "Не удалось скачать install-node.sh"
    chmod +x "$tmp"
    bash "$tmp" "$@"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

cmd_scan() {
    local tmp; tmp="$(mktemp)"
    say "Загрузка scan-target.sh (${GH_REF})..."
    fetch "scripts/scan-target.sh" "$tmp" || die "Не удалось скачать scan-target.sh"
    chmod +x "$tmp"
    bash "$tmp" "$@"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

cmd_self_install() {
    local tmp; tmp="$(mktemp)"
    say "Загрузка mynode.sh (${GH_REF})..."
    fetch "mynode.sh" "$tmp" || die "Не удалось скачать mynode.sh"
    chmod +x "$tmp"

    local dest_dir; dest_dir="$(dirname "$SELF_DEST")"
    if [[ -w "$dest_dir" ]]; then
        mv "$tmp" "$SELF_DEST"
    elif command -v sudo >/dev/null 2>&1; then
        say "Нужны права на запись в $dest_dir — запрошу sudo."
        sudo mv "$tmp" "$SELF_DEST"
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
    local tmp; tmp="$(mktemp)"
    fetch "mynode.sh" "$tmp" || die "Не удалось скачать актуальную версию"
    chmod +x "$tmp"

    if [[ -f "$SELF_DEST" ]] && diff -q "$SELF_DEST" "$tmp" >/dev/null 2>&1; then
        say "Уже установлена актуальная версия (${GH_REF})."
        rm -f "$tmp"; return 0
    fi

    if [[ -f "$SELF_DEST" ]]; then
        warn "Найдены отличия от установленной версии:"
        diff "$SELF_DEST" "$tmp" || true
        echo ""
    fi

    read -r -p "Установить эту версию как $SELF_DEST? (y/N): " ans
    if ! [[ "$ans" =~ ^[Yy]$ ]]; then
        rm -f "$tmp"; say "Отменено."; return 0
    fi

    local dest_dir; dest_dir="$(dirname "$SELF_DEST")"
    if [[ -w "$dest_dir" ]]; then
        mv "$tmp" "$SELF_DEST"
    else
        sudo mv "$tmp" "$SELF_DEST"
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
