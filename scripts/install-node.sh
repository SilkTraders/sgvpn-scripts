#!/usr/bin/env bash
# =============================================================================
#  MASTER-СКРИПТ ПОДГОТОВКИ НОДЫ  (v5)
#
#  Изменения против v4:
#   - Мост (роль 2): спрашивается порт инбаунда моста и IP входящих нод.
#     Порт моста открывается в UFW ТОЛЬКО для этих IP. Раньше скрипт его
#     не открывал вовсе: при default deny мост молча дропал SYN от RU-нод,
#     а панель показывала ноду "зелёной".
#   - Мост больше не открывает 443/tcp всему миру — ему это не нужно.
#   - Утилита bridge-allow (на мосту): добавить/убрать/показать входящие ноды
#     без ручного синтаксиса ufw.
#   - Утилита bridge-check (на любой ноде): проверить с входящей ноды, что
#     мост доступен по TCP и (опционально) отвечает TLS 1.3 с нужным SNI.
#     Работает без nc — через /dev/tcp встроенного bash.
#   - Отчёт: порт инбаунда моста берётся из ввода (раньше было жёстко "8443").
#   - SSH: если sshd не переехал на новый порт, 22 больше не закрывается по
#     YES (раньше SSH_PORT_OK вычислялся, но не использовался — риск
#     потерять доступ к серверу).
#   - Цветное приглашение терминала: user@host зелёный у пользователя,
#     красный у root.
#   - docker-compose.yml открывается ПУСТЫМ под вставку из панели.
#     GOGC/GOMEMLIMIT вынесены в docker-compose.override.yml (Compose
#     объединяет его автоматически). Пустой файл и сервис не с именем
#     remnanode — ловятся до запуска.
#
#  Изменения v4 против v3:
#   - Проверка SSH-ключа: сначала строгий формат-чек (тип ключа + base64),
#     затем ssh-keygen -l -f — одиночный мусорный символ больше не проходит
#   - Вопросы про порт 80 и 8443 убраны, вместо них — свободный список
#     дополнительных портов на открытие (см. EXTRA_PORTS)
#   - docker-compose.yml содержит в environment только GOGC/GOMEMLIMIT,
#     подобранные скриптом; блок для переменных панели убран из шаблона
#   - Итоговый отчёт: логин и порт SSH выводятся отдельными строками,
#     а не готовой командой подключения
#   - Добавлен флаг --panel-ip=IP как альтернатива переменной MYNODE_PANEL_IP
#     (см. примечание в блоке ПРЕДПОЛЁТНЫЕ ПРОВЕРКИ)
# =============================================================================

set -Eeuo pipefail
trap 'echo ""; echo "❌ ОШИБКА на строке $LINENO. Команда: ${BASH_COMMAND}"; exit 1' ERR

export DEBIAN_FRONTEND=noninteractive

C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_INF=$'\e[36m'; C_OFF=$'\e[0m'
say()  { echo "${C_OK}$*${C_OFF}"; }
inf()  { echo "${C_INF}$*${C_OFF}"; }
warn() { echo "${C_WARN}⚠️  $*${C_OFF}"; }
die()  { echo "${C_ERR}❌ $*${C_OFF}"; exit 1; }

# Проверка IPv4. 10# — чтобы октет с ведущим нулём ("08") не считался
# восьмеричным числом внутри (( )).
valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a _OCT <<< "$ip"
    for o in "${_OCT[@]}"; do (( 10#$o <= 255 )) || return 1; done
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# --- IP панели управления ---
# Реальный IP НЕ хардкодится здесь — этот файл лежит в публичном репозитории.
# Передайте его переменной окружения прямо в команде запуска:
#   MYNODE_PANEL_IP=1.2.3.4 bash <(curl -fsSL .../mynode.sh) install
# Либо флагом при прямом запуске этого файла: install-node.sh --panel-ip=1.2.3.4
# (флаг полезен, если переменная окружения не долетает через обёртку/sudo —
#  аргументы командной строки переживают такие хопы надёжнее, чем env).
# Если ничего не задано, скрипт просто спросит IP без варианта по умолчанию —
# ничего не сломается, будет на одно нажатие Enter больше.
for arg in "$@"; do
    case "$arg" in
        --panel-ip=*) MYNODE_PANEL_IP="${arg#*=}" ;;
    esac
done

DEFAULT_PANEL_IP="${MYNODE_PANEL_IP:-}"
DEFAULT_NODE_PORT="${MYNODE_NODE_PORT:-2222}"
DEFAULT_BRIDGE_PORT="${MYNODE_BRIDGE_PORT:-2087}"

# =============================================================================
#  ПРЕДПОЛЁТНЫЕ ПРОВЕРКИ
# =============================================================================

[ "$EUID" -eq 0 ] || die "Запустите с правами root (sudo -i)."
command -v apt-get >/dev/null 2>&1 || die "Скрипт рассчитан на Debian/Ubuntu."

OS_ID=""; OS_VER=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi

CPU_CORES="$(nproc)"
RAM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
RAM_MB=$(( RAM_KB / 1024 ))

echo ""
inf "Система:  ${OS_ID:-unknown} ${OS_VER:-}"
inf "CPU:      $CPU_CORES ядер"
inf "RAM:      ${RAM_MB} MB"
echo ""

# =============================================================================
#  СБОР ВВОДА — всё до любых изменений в системе
# =============================================================================

echo "=== Роль сервера ==="
echo "1) Входящая нода  — принимает трафик от пользователей"
echo "2) Транзитный мост — принимает трафик только от входящей ноды"
while true; do
  read -r -p "Выберите цифру (1 или 2): " NODE_ROLE
  [[ "$NODE_ROLE" =~ ^[12]$ ]] && break
  warn "Введите 1 или 2."
done

while true; do
  read -r -p "Имя хоста (hostname): " HOST_NAME
  [[ "$HOST_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] && break
  warn "Только латиница, цифры и дефис (1-63 символа)."
done

while true; do
  read -r -p "Имя нового пользователя (например, admin): " USER_NAME
  if [ -z "$USER_NAME" ]; then warn "Не может быть пустым."
  elif [ "$USER_NAME" = "root" ]; then warn "root нельзя, создайте отдельного пользователя."
  elif ! [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then warn "Строчные латинские буквы, цифры, дефис, подчёркивание."
  else break; fi
done

# --- SSH-ключ ---
# Формат-чек ДО ssh-keygen: строка обязана начинаться с известного типа ключа
# и base64-данных. Так одиночный мусорный символ (например, случайно
# вставленная буква) отсекается сразу, даже если бы ssh-keygen на пустом/
# однобайтовом файле почему-то не дал ошибку.
KEY_TYPE_RE='^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/]+=*([[:space:]].*)?$'

while true; do
  read -r -p "Публичный SSH-ключ (содержимое .pub): " SSH_PUB_KEY
  SSH_PUB_KEY="$(echo "$SSH_PUB_KEY" | xargs || true)"

  if ! [[ "$SSH_PUB_KEY" =~ $KEY_TYPE_RE ]]; then
      warn "Не похоже на публичный SSH-ключ (нет типа ключа и/или base64-данных). Скопирована ли строка целиком?"
      continue
  fi

  TMP_KEY="$(mktemp)"; printf '%s\n' "$SSH_PUB_KEY" > "$TMP_KEY"
  if ssh-keygen -l -f "$TMP_KEY" >/dev/null 2>&1; then
      say "Ключ принят: $(ssh-keygen -l -f "$TMP_KEY")"
      rm -f "$TMP_KEY"; break
  fi
  rm -f "$TMP_KEY"
  warn "Ключ не прошёл проверку ssh-keygen. Скопирована ли строка целиком?"
done

# --- Порт связи панели с нодой ---
echo ""
echo "=== Связь панели с нодой ==="
echo "Этот порт НЕ должен быть открыт всему интернету — только IP панели."
echo "Документация Remnawave требует ограничивать его именно так."
echo ""

read -r -p "Порт ноды [$DEFAULT_NODE_PORT]: " NODE_PORT
NODE_PORT="${NODE_PORT:-$DEFAULT_NODE_PORT}"
while ! [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || [ "$NODE_PORT" -lt 1 ] || [ "$NODE_PORT" -gt 65535 ]; do
    warn "Некорректный порт."
    read -r -p "Порт ноды [$DEFAULT_NODE_PORT]: " NODE_PORT
    NODE_PORT="${NODE_PORT:-$DEFAULT_NODE_PORT}"
done

echo ""
if [[ -n "$DEFAULT_PANEL_IP" ]]; then
    echo "IP панели по умолчанию: $DEFAULT_PANEL_IP  (передан через MYNODE_PANEL_IP/--panel-ip)"
fi
while true; do
  if [[ -n "$DEFAULT_PANEL_IP" ]]; then
      read -r -p "Использовать этот IP? (Y/n): " ANS
      case "$ANS" in
        [Nn]*|[Нн]*) read -r -p "Введите IP панели: " PANEL_IP ;;
        *) PANEL_IP="$DEFAULT_PANEL_IP" ;;
      esac
  else
      read -r -p "Введите IP панели: " PANEL_IP
  fi
  if valid_ipv4 "$PANEL_IP"; then
      say "IP панели: $PANEL_IP"; break
  fi
  warn "Некорректный IPv4-адрес."
done

# --- Мост: порт инбаунда и входящие ноды ---
# Порт моста НЕ открывается всему миру: на него ходят только наши RU-ноды.
# Открытый всем порт моста = лишняя поверхность для сканеров и пробинга.
BRIDGE_PORT=""
ENTRY_IPS=()
if [ "$NODE_ROLE" = "2" ]; then
    echo ""
    echo "=== Мост: порт инбаунда и входящие ноды ==="
    echo "Порт инбаунда моста откроется ТОЛЬКО для IP входящих нод."
    echo "Должен совпадать с \"port\" инбаунда моста в профиле Remnawave."
    echo ""
    read -r -p "Порт инбаунда моста [$DEFAULT_BRIDGE_PORT]: " BRIDGE_PORT
    BRIDGE_PORT="${BRIDGE_PORT:-$DEFAULT_BRIDGE_PORT}"
    while ! valid_port "$BRIDGE_PORT" || [ "$BRIDGE_PORT" = "$NODE_PORT" ]; do
        warn "Некорректный порт или совпадает с портом панели ($NODE_PORT)."
        read -r -p "Порт инбаунда моста [$DEFAULT_BRIDGE_PORT]: " BRIDGE_PORT
        BRIDGE_PORT="${BRIDGE_PORT:-$DEFAULT_BRIDGE_PORT}"
    done

    read -r -p "IP входящих нод через запятую (пусто = добавлю позже командой bridge-allow): " ENTRY_IPS_INPUT
    if [ -n "$ENTRY_IPS_INPUT" ]; then
        IFS=',' read -r -a RAW_IPS <<< "$ENTRY_IPS_INPUT"
        for ip in "${RAW_IPS[@]}"; do
            ip="$(echo "$ip" | xargs)"
            [ -z "$ip" ] && continue
            if valid_ipv4 "$ip"; then
                ENTRY_IPS+=("$ip")
            else
                warn "IP '$ip' некорректен, пропущен."
            fi
        done
    fi
    if [ "${#ENTRY_IPS[@]}" -eq 0 ]; then
        warn "Ни одного IP входящей ноды. Мост будет недоступен, пока не выполните"
        warn "на нём: sudo bridge-allow <IP_ВХОДЯЩЕЙ_НОДЫ>"
    fi
fi

# --- Дополнительные порты ---
echo ""
echo "=== Дополнительные порты ==="
if [ "$NODE_ROLE" = "1" ]; then
    echo "Уже открываются автоматически: SSH-порт (см. ниже), 443/tcp (Xray),"
    echo "$NODE_PORT/tcp только с IP панели ($PANEL_IP)."
else
    echo "Уже открываются автоматически: SSH-порт (см. ниже),"
    echo "$BRIDGE_PORT/tcp только с IP входящих нод, $NODE_PORT/tcp только с IP панели ($PANEL_IP)."
    warn "Мосту обычно НЕ нужны порты, открытые всему интернету."
    warn "Локальные сервисы (Psiphon на 127.0.0.1:1080 и т.п.) открывать здесь не нужно."
fi
read -r -p "Ещё какие TCP-порты открыть ВСЕМ (через запятую, например 80,8443; пусто = не нужно): " EXTRA_PORTS_INPUT
EXTRA_PORTS=()
if [ -n "$EXTRA_PORTS_INPUT" ]; then
    IFS=',' read -r -a RAW_PORTS <<< "$EXTRA_PORTS_INPUT"
    for p in "${RAW_PORTS[@]}"; do
        p="$(echo "$p" | xargs)"
        if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
            EXTRA_PORTS+=("$p")
        else
            [ -n "$p" ] && warn "Порт '$p' некорректен, пропущен."
        fi
    done
fi

# --- Обслуживание ---
echo ""
echo "=== Регламентное обслуживание ==="
echo "Перезапуск контейнера освобождает память Xray за ~2 секунды."
echo "Полный ребут делает то же самое, но за 60-90 секунд простоя."
echo ""
while true; do
  read -r -p "Перезапуск контейнера: 0 = не нужен, 1 = ежедневно, 2 = через день, 3 = раз в неделю: " RESTART_MODE
  [[ "$RESTART_MODE" =~ ^[0123]$ ]] && break
  warn "Введите 0, 1, 2 или 3."
done

while true; do
  read -r -p "Полный ребут: 0 = не нужен, 1 = раз в неделю, 2 = дважды в неделю, 3 = трижды в неделю: " REBOOT_MODE
  [[ "$REBOOT_MODE" =~ ^[0123]$ ]] && break
  warn "Введите 0, 1, 2 или 3."
done

SSH_PORT="$(shuf -i 20000-60000 -n 1)"
while [ "$SSH_PORT" = "$NODE_PORT" ] || [ "$SSH_PORT" = "$BRIDGE_PORT" ]; do
    SSH_PORT="$(shuf -i 20000-60000 -n 1)"
done
echo ""
say "Сгенерирован SSH-порт: $SSH_PORT"
echo "======================================"

# =============================================================================
#  ПАРАМЕТРЫ ПО ЖЕЛЕЗУ
# =============================================================================

if   [ "$RAM_MB" -le 2300 ]; then GOMEM="1200MiB"; GOGC="30"; SC_BUFF="15"
elif [ "$RAM_MB" -le 4600 ]; then GOMEM="2500MiB"; GOGC="50"; SC_BUFF="15"
elif [ "$RAM_MB" -le 9200 ]; then GOMEM="6000MiB"; GOGC="50"; SC_BUFF="30"
else                              GOMEM="12000MiB"; GOGC="60"; SC_BUFF="45"
fi

if [ "$NODE_ROLE" = "1" ]; then
    ROLE_NAME="ВХОДЯЩАЯ НОДА (Entry Node)"; CONN_IDLE="120"
else
    ROLE_NAME="ТРАНЗИТНЫЙ МОСТ (Transit Bridge)"; CONN_IDLE="300"
fi

# =============================================================================
#  [1/12] HOSTNAME
# =============================================================================
say "[1/12] Hostname..."
hostnamectl set-hostname "$HOST_NAME" || warn "hostnamectl не сработал, продолжаем."
if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1 $HOST_NAME/" /etc/hosts
else
    echo "127.0.1.1 $HOST_NAME" >> /etc/hosts
fi

# =============================================================================
#  [2/12] ПАКЕТЫ
# =============================================================================
say "[2/12] Пакеты..."
apt-get update -y
apt-get -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" upgrade
apt-get install -y sudo ufw chrony curl wget nano irqbalance ca-certificates cron nload \
                   jq conntrack iproute2 unattended-upgrades bc
apt-get autoremove -y
apt-get clean

# =============================================================================
#  [3/12] ПОЛЬЗОВАТЕЛЬ
# =============================================================================
say "[3/12] Пользователь и ключи..."
if id "$USER_NAME" &>/dev/null; then
    say "Пользователь $USER_NAME уже есть."
else
    adduser --disabled-password --gecos "" "$USER_NAME"
fi

echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-$USER_NAME"
chmod 0440 "/etc/sudoers.d/90-$USER_NAME"
visudo -cf "/etc/sudoers.d/90-$USER_NAME" >/dev/null || die "Ошибка в sudoers."

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[ -n "$USER_HOME" ] || die "Не определён домашний каталог."

mkdir -p "$USER_HOME/.ssh"
touch "$USER_HOME/.ssh/authorized_keys"
grep -qxF "$SSH_PUB_KEY" "$USER_HOME/.ssh/authorized_keys" || \
    printf '%s\n' "$SSH_PUB_KEY" >> "$USER_HOME/.ssh/authorized_keys"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.ssh"

# --- Цветное приглашение терминала (PS1) ---
# Обычный пользователь: зелёный user@host. root (sudo -i): КРАСНЫЙ user@host,
# чтобы сразу было видно, что сессия с полными правами.
# \$ bash сам превращает в "$" для пользователя и в "#" для root.
# Маркер sgvpn-custom-ps1 — защита от дублирования при повторном запуске.
PS1_USER="PS1='\\[\\e[1;32m\\]\\u@\\h\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]\\[\\e[1;31m\\]\\\$\\[\\e[0m\\] '"
PS1_ROOT="PS1='\\[\\e[1;31m\\]\\u@\\h\\[\\e[0m\\]:\\[\\e[1;34m\\]\\w\\[\\e[0m\\]\\[\\e[1;31m\\]\\\$\\[\\e[0m\\] '"
for rc_pair in "$USER_HOME/.bashrc|$PS1_USER" "/root/.bashrc|$PS1_ROOT"; do
    rc_file="${rc_pair%%|*}"; rc_ps1="${rc_pair#*|}"
    if [ -f "$rc_file" ] && ! grep -qF "sgvpn-custom-ps1" "$rc_file"; then
        printf '\n# sgvpn-custom-ps1\n%s\n' "$rc_ps1" >> "$rc_file"
    fi
done
# Без проверки -f: если .bashrc нет, chown падает и set -e обрывает установку.
if [ -f "$USER_HOME/.bashrc" ]; then
    chown "$USER_NAME:$USER_NAME" "$USER_HOME/.bashrc"
fi

# =============================================================================
#  [4/12] SSH
# =============================================================================
say "[4/12] SSH..."
cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

CLOUD_INIT="/etc/ssh/sshd_config.d/50-cloud-init.conf"
[ -f "$CLOUD_INIT" ] && sed -i -E 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$CLOUD_INIT"

sshd -t || die "Конфиг sshd не прошёл проверку. Ничего не перезапускаем."

# Socket-активация (Ubuntu 22.10+) игнорирует директиву Port из sshd_config.
# Переводим на классический ssh.service, иначе порт не сменится,
# а UFW следом закроет 22 — и доступ потерян.
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
    if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
        warn "Socket-активация SSH обнаружена. Переключаемся на ssh.service."
        systemctl disable --now ssh.socket || true
        rm -f /etc/systemd/system/ssh.service.d/00-socket.conf
        rm -f /etc/systemd/system/ssh.socket.d/addresses.conf
        systemctl daemon-reload
        systemctl enable ssh.service || true
    fi
fi

systemctl daemon-reload
systemctl restart ssh 2>/dev/null || systemctl restart sshd
sleep 2

if ss -tlnH "sport = :$SSH_PORT" | grep -q ":$SSH_PORT"; then
    say "sshd слушает порт $SSH_PORT."
    SSH_PORT_OK=true
else
    warn "sshd НЕ слушает $SSH_PORT. Порт 22 останется открытым."
    SSH_PORT_OK=false
fi

# =============================================================================
#  [5/12] SWAP
# =============================================================================
say "[5/12] Swap..."
if   [ "$RAM_MB" -le 2048 ]; then SWAP_MB=2048
elif [ "$RAM_MB" -le 4096 ]; then SWAP_MB="$RAM_MB"
else SWAP_MB=4096; fi

if swapon --show --noheadings | grep -q .; then
    say "Swap уже активен."
elif [ -f /swapfile ]; then
    say "/swapfile существует."
else
    fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null || \
        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# =============================================================================
#  [6/12] ВРЕМЯ
# =============================================================================
say "[6/12] Время (UTC)..."
timedatectl set-timezone UTC
systemctl enable --now chrony
chronyc makestep >/dev/null 2>&1 || warn "chronyc makestep не сработал."
systemctl enable --now irqbalance || warn "irqbalance недоступен."

# =============================================================================
#  [7/12] ЛИМИТЫ И DOCKER DAEMON
# =============================================================================
say "[7/12] Лимиты..."

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-nofile.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1000000
EOF

cat > /etc/security/limits.d/99-highload.conf <<'EOF'
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF

systemctl daemon-reexec

mkdir -p /etc/docker
DOCKER_CFG_NEW='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" },
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 1000000, "Soft": 1000000 }
  }
}'

if [ -s /etc/docker/daemon.json ]; then
    cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
    if jq -e . /etc/docker/daemon.json >/dev/null 2>&1; then
        jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$DOCKER_CFG_NEW") > /tmp/daemon.merged
        mv /tmp/daemon.merged /etc/docker/daemon.json
        say "daemon.json объединён с существующим."
    else
        warn "Существующий daemon.json невалиден, заменяем (бэкап создан)."
        echo "$DOCKER_CFG_NEW" > /etc/docker/daemon.json
    fi
else
    echo "$DOCKER_CFG_NEW" > /etc/docker/daemon.json
fi

# =============================================================================
#  [8/12] ЯДРО
# =============================================================================
say "[8/12] Тюнинг ядра..."

modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
modprobe nf_conntrack 2>/dev/null || true
echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf

cat > /etc/sysctl.d/99-xray-highload.conf <<'EOF'
# =============================================================================
#  IPv6 здесь НАМЕРЕННО не отключается.
#
#  Отключение на уровне ядра ломает сервисы, биндящиеся на [::] (известная
#  проблема docker-proxy), режет доступ к IPv6-зеркалам apt и не всегда
#  применяется к уже поднятым интерфейсам.
#
#  Цель — не дать Xray утекать в IPv6 — достигается точнее на уровне Xray:
#     "dns":       { "queryStrategy": "UseIPv4" }
#     freedom-out: { "domainStrategy": "UseIPv4" }   вместо UseIP / AsIs
#  Это обратимо без перезагрузки и не трогает саму систему.
# =============================================================================

# --- Память и файлы ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
fs.file-max = 1000000

# --- Очереди ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384

# Нижняя граница 10240, а не 1024: иначе эфемерный порт исходящего соединения
# может занять 8443 раньше, чем контейнер успеет на него забиндиться.
net.ipv4.ip_local_port_range = 10240 65000

# --- TCP ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_mtu_probing = 1

# --- Буферы 16MB: нужны для длинного RTT на межстрановой магистрали ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- UDP ---
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- BBR ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Conntrack: при сотнях CCU таблица переполняется и ядро дропает пакеты ---
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF

sysctl --system >/dev/null 2>&1 || warn "Часть sysctl не применилась."

# --- Диагностика IPv6: не отключаем, но сообщаем состояние ---
IPV6_STATUS="отсутствует"
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    if curl -6 -s --max-time 6 https://ifconfig.co >/dev/null 2>&1; then
        IPV6_STATUS="РАБОТАЕТ (нужен queryStrategy UseIPv4 в Xray, иначе утечки)"
    else
        IPV6_STATUS="АДРЕС ЕСТЬ, СВЯЗИ НЕТ (частая причина тормозов на дуал-стек сайтах)"
    fi
fi

# =============================================================================
#  [9/12] FIREWALL
# =============================================================================
say "[9/12] UFW..."

UFW_BEFORE="/etc/ufw/before.rules"
if [ -f "$UFW_BEFORE" ] && ! grep -q "XRAY-ICMP-HARDENING" "$UFW_BEFORE"; then
    cp -a "$UFW_BEFORE" "$UFW_BEFORE.bak.$(date +%s)"
    sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/g' "$UFW_BEFORE"
    sed -i 's/-A ufw-before-forward -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP/g' "$UFW_BEFORE"
    sed -i '1i # XRAY-ICMP-HARDENING applied' "$UFW_BEFORE"
fi

ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

ufw limit "$SSH_PORT"/tcp comment 'SSH'

if [ "$NODE_ROLE" = "1" ]; then
    ufw allow 443/tcp comment 'Xray inbound'
    ufw deny  443/udp comment 'Block QUIC'
else
    # Мост: порт инбаунда — только для входящих нод. Без этого правила
    # default deny молча дропает SYN от RU-нод (ни RST, ни ошибки в панели).
    for ip in "${ENTRY_IPS[@]}"; do
        ufw allow from "$ip" to any port "$BRIDGE_PORT" proto tcp comment 'Entry node -> bridge'
    done
    mkdir -p /etc/sgvpn
    echo "$BRIDGE_PORT" > /etc/sgvpn/bridge-port
fi

# Порт ноды — ТОЛЬКО с IP панели. Открытый всему миру API ноды это точка,
# через которую управляется Xray.
ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Panel API'

# Дополнительные порты, заданные на шаге сбора ввода (открываются всем).
for p in "${EXTRA_PORTS[@]}"; do
    ufw allow "$p"/tcp comment 'Custom port'
done

ufw limit 22/tcp comment 'SSH legacy - закрыть после проверки'
ufw --force enable >/dev/null

# =============================================================================
#  [10/12] DOCKER
# =============================================================================
say "[10/12] Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
else
    say "Docker уже установлен."
fi
systemctl enable --now docker
systemctl restart docker
usermod -aG docker "$USER_NAME"

# =============================================================================
#  [11/12] УТИЛИТА ДИАГНОСТИКИ
# =============================================================================
say "[11/12] Утилита node-health..."

cat > /usr/local/bin/node-health <<'HEALTH'
#!/usr/bin/env bash
# Быстрая диагностика ноды. Отвечает на вопрос "что именно упёрлось".
CORES="$(nproc)"
LA="$(awk '{print $1, $2, $3}' /proc/loadavg)"
LA1="$(awk '{print $1}' /proc/loadavg)"
LA_PCT="$(echo "scale=0; $LA1 * 100 / $CORES" | bc 2>/dev/null || echo "?")"

echo "=============================================="
echo " NODE HEALTH — $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "=============================================="
echo ""
echo "--- CPU ---"
echo "Ядер:              $CORES"
echo "Load Average:      $LA"
echo "LA1 на ядро:       ${LA_PCT}%   (>100% = очередь на CPU)"
echo ""
echo "--- Память ---"
echo "Значение имеет колонка available, а не used:"
free -h
echo ""
echo "--- Swap ---"
swapon --show 2>/dev/null || echo "swap не используется"
echo ""
echo "--- Conntrack ---"
CT_CUR="$(conntrack -C 2>/dev/null || echo '?')"
CT_MAX="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '?')"
echo "Соединений: $CT_CUR из $CT_MAX"
echo ""
echo "--- Сетевые соединения ---"
echo "ESTABLISHED: $(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)"
echo "TIME-WAIT:   $(ss -tn state time-wait 2>/dev/null | tail -n +2 | wc -l)"
echo ""
echo "--- Диск ---"
df -h / | tail -n 1
echo ""
echo "--- Контейнеры ---"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null || echo "docker недоступен"
echo ""
echo "--- Полоса (5 сек) ---"
IFACE="$(ip route | awk '/default/ {print $5; exit}')"
if [ -n "$IFACE" ]; then
    R1=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes")
    T1=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes")
    sleep 5
    R2=$(cat "/sys/class/net/$IFACE/statistics/rx_bytes")
    T2=$(cat "/sys/class/net/$IFACE/statistics/tx_bytes")
    echo "Интерфейс $IFACE:"
    echo "  RX: $(( (R2-R1)*8/5/1000000 )) Mbit/s"
    echo "  TX: $(( (T2-T1)*8/5/1000000 )) Mbit/s"
    echo "  Если упирается в круглое число (100/200/300) — это лимит тарифа,"
    echo "  и ни перезапуск, ни ребут тут не помогут."
fi
echo ""
echo "=============================================="
HEALTH

chmod +x /usr/local/bin/node-health

# --- bridge-check: ставится на любую ноду, запускается на ВХОДЯЩЕЙ ---
# Проверяет то, что панель не видит: доходит ли TCP от этой ноды до моста
# и отвечает ли мост TLS 1.3 с нужным SNI. Без nc — через /dev/tcp bash.
cat > /usr/local/bin/bridge-check <<'BCHECK'
#!/usr/bin/env bash
# Использование: bridge-check <IP_МОСТА> [ПОРТ=2087] [SNI]
set -uo pipefail
IP="${1:-}"; PORT="${2:-2087}"; SNI="${3:-}"
if [ -z "$IP" ]; then
    echo "Использование: bridge-check <IP_МОСТА> [ПОРТ=2087] [SNI]"
    echo "Запускать на ВХОДЯЩЕЙ ноде."
    exit 2
fi

if timeout 5 bash -c "</dev/tcp/$IP/$PORT" 2>/dev/null; then
    echo "✓ TCP $IP:$PORT доступен с этой ноды"
else
    MY_IP="$(curl -s4 --max-time 5 https://ifconfig.me || echo '<IP_ЭТОЙ_НОДЫ>')"
    echo "✗ TCP $IP:$PORT недоступен с этой ноды"
    echo "  Чаще всего — файрвол моста. На мосту выполните:"
    echo "    sudo bridge-allow $MY_IP"
    echo "  Если не помогло — проверьте, что Xray на мосту слушает порт:"
    echo "    ss -tlnp | grep :$PORT"
    exit 1
fi

if [ -n "$SNI" ]; then
    OUT="$(curl -vk -m 10 --resolve "$SNI:$PORT:$IP" "https://$SNI:$PORT" 2>&1 || true)"
    if grep -q 'TLSv1.3' <<< "$OUT"; then
        echo "✓ TLS 1.3 с SNI $SNI"
        grep -m1 'subject:' <<< "$OUT" | sed 's/^\*[[:space:]]*/  /'
    else
        echo "✗ TLS 1.3 с SNI $SNI не получен. Последние строки curl:"
        tail -5 <<< "$OUT" | sed 's/^/  /'
        echo "  Проверьте на мосту: доступен ли target Reality и отдаёт ли он TLS 1.3."
        exit 1
    fi
fi
BCHECK
chmod +x /usr/local/bin/bridge-check

# --- bridge-allow: только на мосту ---
if [ "$NODE_ROLE" = "2" ]; then
cat > /usr/local/bin/bridge-allow <<'BALLOW'
#!/usr/bin/env bash
# Управление доступом входящих нод к порту моста.
#   bridge-allow <IP>       открыть порт моста для IP
#   bridge-allow -d <IP>    закрыть порт моста для IP
#   bridge-allow -l         показать, для кого открыт
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "Нужен root: sudo bridge-allow ..."; exit 1; }
PORT="$(cat /etc/sgvpn/bridge-port 2>/dev/null || true)"
[ -n "$PORT" ] || { echo "Не найден /etc/sgvpn/bridge-port (порт моста)."; exit 1; }

is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

case "${1:--l}" in
    -l)
        ufw status | grep -E "^${PORT}/tcp" || echo "Порт $PORT не открыт ни для одной ноды."
        ;;
    -d)
        IP="${2:-}"; is_ip "$IP" || { echo "Некорректный IP: '$IP'"; exit 1; }
        ufw delete allow from "$IP" to any port "$PORT" proto tcp
        ;;
    *)
        IP="$1"; is_ip "$IP" || { echo "Некорректный IP: '$IP'"; exit 1; }
        ufw allow from "$IP" to any port "$PORT" proto tcp comment 'Entry node -> bridge'
        echo "Готово. Проверка с входящей ноды:"
        echo "  bridge-check <IP_ЭТОГО_МОСТА> $PORT <SNI_МОСТА>"
        ;;
esac
BALLOW
chmod +x /usr/local/bin/bridge-allow
fi

# =============================================================================
#  [12/12] РЕГЛАМЕНТНОЕ ОБСЛУЖИВАНИЕ
# =============================================================================
say "[12/12] Автообновления и расписание..."

cat > /etc/apt/apt.conf.d/51-unattended-security <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || warn "unattended-upgrades не запустился."

# Окно 03:00-05:00 МСК = 00:00-02:00 UTC (система переведена в UTC).
# Минута и час случайны на каждой ноде: иначе все ноды балансира
# перезапускаются одновременно и балансиру некуда переводить пользователей.
R_HOUR="$(shuf -i 0-1 -n 1)"
R_MIN="$(shuf -i 0-59 -n 1)"
B_HOUR="$(shuf -i 0-1 -n 1)"
B_MIN="$(shuf -i 0-59 -n 1)"

CRON_TMP="$(mktemp)"
crontab -l 2>/dev/null \
    | grep -v -F "/sbin/reboot" \
    | grep -v -F "docker compose restart" \
    | grep -v -F "node-restart" > "$CRON_TMP" || true

RESTART_DESC="отключён"
case "$RESTART_MODE" in
  1) RESTART_SCHED="* * *";            RESTART_DESC="ежедневно";;
  2) RESTART_SCHED="*/2 * *";          RESTART_DESC="через день";;
  3) D="$(shuf -i 0-6 -n 1)"; RESTART_SCHED="* * $D"; RESTART_DESC="раз в неделю, день $D";;
  0) RESTART_SCHED="";;
esac

if [ -n "$RESTART_SCHED" ]; then
    echo "$R_MIN $R_HOUR $RESTART_SCHED cd /opt/remnanode && /usr/bin/docker compose restart >> /var/log/node-restart.log 2>&1" >> "$CRON_TMP"
    RESTART_DESC="$RESTART_DESC, в $(printf '%02d:%02d' "$R_HOUR" "$R_MIN") UTC ($(printf '%02d:%02d' "$(( (R_HOUR+3) % 24 ))" "$R_MIN") МСК)"
fi

REBOOT_DESC="отключён"
case "$REBOOT_MODE" in
  1) DAYS="$(shuf -i 0-6 -n 1)";;
  2) DAYS="$(shuf -i 0-6 -n 2 | sort -n | paste -sd ',' -)";;
  3) DAYS="$(shuf -i 0-6 -n 3 | sort -n | paste -sd ',' -)";;
  0) DAYS="";;
esac

if [ -n "$DAYS" ]; then
    echo "$B_MIN $B_HOUR * * $DAYS /sbin/reboot" >> "$CRON_TMP"
    REBOOT_DESC="дни [$DAYS] в $(printf '%02d:%02d' "$B_HOUR" "$B_MIN") UTC ($(printf '%02d:%02d' "$(( (B_HOUR+3) % 24 ))" "$B_MIN") МСК)"
fi

crontab "$CRON_TMP"
rm -f "$CRON_TMP"
systemctl enable --now cron

# Ротация лога перезапусков, чтобы он не рос бесконечно
cat > /etc/logrotate.d/node-restart <<'EOF'
/var/log/node-restart.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

# =============================================================================
#  ОТЧЁТ
# =============================================================================

SERVER_IP="$(curl -s --max-time 10 https://ifconfig.me || true)"
[ -n "$SERVER_IP" ] || SERVER_IP="<IP_СЕРВЕРА>"

REPORT="/root/node-setup-info.txt"
{
echo "====================================================================="
echo " НАСТРОЙКА ЗАВЕРШЕНА — $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "====================================================================="
echo "Роль:             $ROLE_NAME"
echo "Hostname:         $HOST_NAME"
echo "IP сервера:       $SERVER_IP"
echo "CPU:              $CPU_CORES ядер"
echo "RAM:              ${RAM_MB} MB"
echo ""
echo "--- Доступ ---"
echo "Логин:            $USER_NAME"
echo "Порт SSH:         $SSH_PORT"
echo ""
echo "--- Firewall ---"
if [ "$NODE_ROLE" = "1" ]; then
echo "443/tcp           открыт (Xray)"
echo "443/udp           заблокирован (QUIC)"
else
if [ "${#ENTRY_IPS[@]}" -gt 0 ]; then
echo "$BRIDGE_PORT/tcp          только с входящих нод: ${ENTRY_IPS[*]}"
else
echo "$BRIDGE_PORT/tcp          ЗАКРЫТ — входящие ноды не указаны!"
fi
echo "Добавить ноду:    sudo bridge-allow <IP>   (список: sudo bridge-allow -l)"
fi
echo "$NODE_PORT/tcp           только с $PANEL_IP (панель)"
if [ "${#EXTRA_PORTS[@]}" -gt 0 ]; then
    echo "Доп. порты:       ${EXTRA_PORTS[*]}/tcp (открыты всем)"
fi
echo ""
echo "--- Обслуживание ---"
echo "Рестарт контейнера: $RESTART_DESC"
echo "Полный ребут:       $REBOOT_DESC"
echo ""
echo "--- IPv6 ---"
echo "Состояние: $IPV6_STATUS"
echo "На уровне ядра IPv6 НЕ отключён. Если нужно исключить утечки,"
echo "добавьте в конфиг Xray:"
echo "    \"dns\": { \"queryStrategy\": \"UseIPv4\" }"
echo "и замените domainStrategy UseIP/AsIs на UseIPv4 в freedom-outbound."
echo ""
echo "--- Параметры Go-рантайма (docker-compose.override.yml) ---"
echo "GOGC=$GOGC"
echo "GOMEMLIMIT=$GOMEM"
echo "Файл: /opt/remnanode/docker-compose.override.yml"
echo "docker-compose.yml открывается пустым — вставьте compose из панели."
echo ""
if [ "$NODE_ROLE" = "1" ]; then
echo "--- JSON: inbound 443 ---"
echo "xmux.maxConcurrency:    \"8\""
echo "xmux.cMaxReuseTimes:    64"
echo "xmux.hMaxRequestTimes:  \"400-600\""
echo "xmux.hMaxReusableSecs:  \"120\""
echo "scStreamUpServerSecs:   \"120\""
echo ""
echo "--- JSON: outbound BRIDGE ---"
echo "xmux.maxConcurrency:    \"512\""
echo "xmux.hMaxRequestTimes:  \"1000-1500\""
echo "xmux.hMaxReusableSecs:  \"300\""
echo "scMaxBufferedPosts:     $SC_BUFF"
echo "scMaxConcurrentPosts:   64"
echo "scStreamUpServerSecs:   \"300\""
else
echo "--- JSON: inbound $BRIDGE_PORT ---"
echo "xmux.maxConcurrency:    \"512\""
echo "xmux.hMaxRequestTimes:  \"1000-1500\""
echo "xmux.hMaxReusableSecs:  \"300\""
echo "scMaxBufferedPosts:     $SC_BUFF"
echo "scMaxConcurrentPosts:   64"
echo "scStreamUpServerSecs:   \"300\""
fi
echo ""
echo "--- JSON: policy ---"
echo "connIdle: $CONN_IDLE"
echo ""
echo "--- Диагностика ---"
echo "Команда node-health покажет, что именно упёрлось:"
echo "CPU, память, conntrack, соединения, полосу."
echo "Доступность моста (запускать на входящей ноде):"
echo "  bridge-check <IP_МОСТА> [ПОРТ] [SNI]"
echo "====================================================================="
} > "$REPORT"

chmod 600 "$REPORT"
cat "$REPORT"

# =============================================================================
#  ПОДТВЕРЖДЕНИЕ ДОСТУПА
# =============================================================================

echo ""
echo "====================================================================="
warn "НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ."

# Если sshd не переехал на новый порт, единственный рабочий вход — 22.
# Закрыть его в этом состоянии = потерять SSH (останется только консоль хостера).
if [ "$SSH_PORT_OK" != true ]; then
    warn "sshd НЕ слушает новый порт $SSH_PORT — порт 22 НЕ закрываю."
    warn "Разберитесь с sshd (ss -tlnp | grep sshd), проверьте вход на $SSH_PORT, затем:"
    warn "  ufw delete limit 22/tcp && ufw deny 22/tcp"
    CONFIRM="SKIP"
else
    warn "Откройте НОВОЕ окно терминала и войдите: пользователь $USER_NAME, порт $SSH_PORT."
    read -r -p "Вход в новом окне работает? Введите YES для закрытия порта 22: " CONFIRM
fi

if [ "$CONFIRM" = "YES" ]; then
    ufw delete limit 22/tcp >/dev/null 2>&1 || true
    ufw deny 22/tcp comment 'SSH legacy closed' >/dev/null
    say "Порт 22 закрыт."
else
    warn "Порт 22 оставлен открытым."
    warn "Закрыть вручную: ufw delete limit 22/tcp && ufw deny 22/tcp"
fi

# =============================================================================
#  РАЗВЁРТЫВАНИЕ
# =============================================================================

mkdir -p /opt/remnanode
cd /opt/remnanode

if [ -f docker-compose.yml ] && [ -s docker-compose.yml ]; then
    cp -a docker-compose.yml "docker-compose.yml.bak.$(date +%s)"
    say "Существующий docker-compose.yml сохранён в бэкап, пишем заново."
fi

# docker-compose.yml открывается ПУСТЫМ: в него целиком вставляется compose
# из панели Remnawave. Параметры Go-рантайма, подобранные по железу,
# лежат отдельно в docker-compose.override.yml — Docker Compose сам
# объединяет его с docker-compose.yml при любой команде в этой папке
# (up, restart, cron-перезапуск). Лимиты логов уже заданы глобально
# в /etc/docker/daemon.json, поэтому в compose они не нужны.
: > docker-compose.yml

cat > docker-compose.override.yml <<EOF
# Создан install-node.sh — параметры Go-рантайма под железо этой ноды.
# Docker Compose автоматически объединяет этот файл с docker-compose.yml.
services:
  remnanode:
    environment:
      - GOGC=$GOGC
      - GOMEMLIMIT=$GOMEM
EOF
say "GOGC=$GOGC и GOMEMLIMIT=$GOMEM записаны в docker-compose.override.yml."

echo ""
warn "Откроется ПУСТОЙ docker-compose.yml."
warn "Вставьте в него docker-compose из панели Remnawave целиком."
warn "Сохранение: Ctrl+O, Enter, Ctrl+X."
read -n 1 -s -r -p "Нажмите любую клавишу..."
echo ""

nano docker-compose.yml

if ! grep -q '[^[:space:]]' docker-compose.yml; then
    die "docker-compose.yml пустой. Вставьте compose из панели и запустите: cd /opt/remnanode && nano docker-compose.yml && docker compose up -d"
fi

# Override рассчитан на сервис с именем remnanode (так его называет панель).
# Если имя другое, объединение сломает конфиг — тогда убираем override.
if ! docker compose -f docker-compose.yml config --services 2>/dev/null | grep -qx remnanode; then
    warn "В compose из панели нет сервиса 'remnanode' — GOGC/GOMEMLIMIT не применятся."
    warn "Добавьте их вручную в environment: GOGC=$GOGC, GOMEMLIMIT=$GOMEM"
    rm -f docker-compose.override.yml
fi

docker compose config >/dev/null || die "docker-compose.yml невалиден. Исправьте: cd /opt/remnanode && nano docker-compose.yml"
docker compose up -d

say "Контейнер запущен. Отчёт: $REPORT"
say "Диагностика: node-health"
