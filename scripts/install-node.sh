#!/usr/bin/env bash
# =============================================================================
#  MASTER-СКРИПТ ПОДГОТОВКИ НОДЫ  (v4)
#
#  Изменения против v3:
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
  # Простая проверка формата IPv4
  if [[ "$PANEL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      VALID=true
      IFS='.' read -r -a OCT <<< "$PANEL_IP"
      for o in "${OCT[@]}"; do [ "$o" -le 255 ] || VALID=false; done
      [ "$VALID" = true ] && { say "IP панели: $PANEL_IP"; break; }
  fi
  warn "Некорректный IPv4-адрес."
done

# --- Дополнительные порты ---
echo ""
echo "=== Дополнительные порты ==="
echo "Уже открываются автоматически: SSH-порт (см. ниже), 443/tcp (Xray),"
echo "$NODE_PORT/tcp только с IP панели ($PANEL_IP)."
read -r -p "Ещё какие TCP-порты открыть всем (через запятую, например 80,8443; пусто = не нужно): " EXTRA_PORTS_INPUT
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
ufw allow 443/tcp comment 'Xray inbound'
ufw deny  443/udp comment 'Block QUIC'

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
echo "443/tcp           открыт (Xray)"
echo "443/udp           заблокирован (QUIC)"
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
echo "--- Параметры docker-compose (environment) ---"
echo "GOGC=$GOGC"
echo "GOMEMLIMIT=$GOMEM"
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
echo "--- JSON: inbound 8443 ---"
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
echo "Откройте ВТОРОЙ терминал и проверьте вход:"
echo ""
echo "    ssh -p $SSH_PORT $USER_NAME@$SERVER_IP"
echo ""
echo "====================================================================="
read -r -p "Вход работает? Введите YES для закрытия порта 22: " CONFIRM

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
    say "docker-compose.yml уже существует, открываем на правку."
else
    # В environment — только параметры, подобранные скриптом по железу
    # (GOGC/GOMEMLIMIT). Никаких плейсхолдеров под переменные панели
    # здесь больше нет — при необходимости добавьте их вручную в nano ниже.
    cat > docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    restart: always
    network_mode: host
    environment:
      - GOGC=$GOGC
      - GOMEMLIMIT=$GOMEM
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
EOF
    say "Создан docker-compose.yml с GOGC=$GOGC и GOMEMLIMIT=$GOMEM."
fi

echo ""
warn "Откроется nano. Если нужны дополнительные переменные (например, из панели) —"
warn "добавьте их сами; если нет — просто закройте файл."
warn "Сохранение: Ctrl+O, Enter, Ctrl+X."
read -n 1 -s -r -p "Нажмите любую клавишу..."
echo ""

nano docker-compose.yml

docker compose config >/dev/null || die "docker-compose.yml невалиден."
docker compose up -d

say "Контейнер запущен. Отчёт: $REPORT"
say "Диагностика: node-health"
echo "Логи (выход — Ctrl+C):"
docker compose logs -f -t
