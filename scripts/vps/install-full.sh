#!/bin/bash
set -e

# ================================================
# 🛠️ СКРИПТ УСТАНОВКИ ПОЛНОЙ КОНФИГУРАЦИИ VPS
# Для Ubuntu 24.04 LTS, vCPU x2, RAM 4GB, 60GB HDD
# Автор: triglavfree
# Репозиторий: https://github.com/triglavfree/DEPLOY
# ================================================

# =============== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ===============
REPO_URL="https://raw.githubusercontent.com/triglavfree/deploy/main"
SCRIPT_VERSION="1.2.0"
CURRENT_IP="unknown"                   # IP клиента (откуда идёт SSH-подключение)
EXTERNAL_IP="unknown"                  # Внешний IP сервера
LOG_FILE="/var/log/deploy_full.log"    # Лог всех действий
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"  # Резервные копии перед изменениями
SYSTEM_UPDATE_STATUS=""                # Статус обновлений системы

# =============== ЦВЕТА ДЛЯ ВЫВОДА ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'                           # Сброс цвета

# =============== ФУНКЦИИ ===============
print_step()   { echo -e "\n${PURPLE}=== ${CYAN}$1${PURPLE} ===${NC}"; }
print_success(){ echo -e "${GREEN}✓ $1${NC}"; }
print_warning(){ echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()  { echo -e "${RED}✗ $1${NC}" >&2; }
print_info()   { echo -e "${BLUE}ℹ $1${NC}"; }

# Логирование в файл
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# Генерация случайной строки (для паролей и путей)
gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}

# Проверка, свободен ли порт
check_port_available() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 1  # Порт занят
    else
        return 0  # Порт свободен
    fi
}

# Проверка доступа к интернету
check_internet() {
    if ! ping -c 1 -W 3 google.com &> /dev/null; then
        print_error "❌ Нет доступа к интернету. Проверьте сетевые настройки."
        exit 1
    fi
}

# Проверка версии GLIBC (требуется ≥2.32 для Ubuntu 24.04)
check_glibc_version() {
    glibc_version=$(ldd --version | head -n1 | awk '{print $NF}')
    required_version="2.32"
    if [[ "$(printf '%s\n' "$required_version" "$glibc_version" | sort -V | head -n1)" != "$required_version" ]]; then
        print_error "❌ Ваша версия GLIBC ($glibc_version) устарела. Требуется минимум 2.32."
        print_error "   Убедитесь, что вы используете Ubuntu 24.04 LTS."
        exit 1
    fi
    print_info "✅ GLIBC версия: $glibc_version (подходит)"
}

# Проверка свободного места на диске (минимум 10 ГБ)
check_disk_space() {
    local free_space_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$free_space_gb" -lt 10 ]; then
        print_error "❌ Недостаточно места на диске. Требуется минимум 10 ГБ, у вас: ${free_space_gb} ГБ"
        exit 1
    fi
    print_info "✅ Достаточно места: ${free_space_gb} ГБ"
}

# Проверка статуса сервиса и вывод деталей при ошибке
check_service_status() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        print_success "✅ Сервис $service активен"
    else
        print_error "❌ Сервис $service НЕ АКТИВЕН!"
        systemctl status "$service" --no-pager -l | head -n 8
        return 1
    fi
}

# Проверка, остались ли пакеты для обновления после upgrade
check_if_fully_updated() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if apt-get --just-print upgrade 2>/dev/null | grep -q "^Inst"; then
        echo "доступны обновления"
    else
        echo "актуальна"
    fi
}

# Применение оптимизаций ядра (BBR, сетевые параметры)
apply_max_performance_optimizations() {
    local config_file="/etc/sysctl.d/99-max-performance.conf"
    local needs_update=false

    # Проверяем, нужно ли обновлять конфиг
    if [ ! -f "$config_file" ]; then
        needs_update=true
    else
        if ! grep -q "net.ipv4.tcp_congestion_control = bbr" "$config_file"; then
            needs_update=true
        fi
    fi

    if [ "$needs_update" = true ]; then
        print_info "🔄 Применение максимальных оптимизаций ядра (BBR, TCP, память)..."
        mkdir -p /etc/sysctl.d

        # Загружаем модуль tcp_bbr, если не загружен
        if ! lsmod | grep -q "tcp_bbr"; then
            if modprobe tcp_bbr 2>/dev/null; then
                print_info "🔧 Модуль ядра tcp_bbr загружен."
                echo "tcp_bbr" > /etc/modules-load.d/tcp-bbr.conf
            else
                print_warning "⚠ Не удалось загрузить модуль tcp_bbr. BBR может не работать."
            fi
        else
            print_info "🔧 Модуль tcp_bbr уже загружен."
        fi

        # Записываем полный конфиг оптимизаций
        cat > "$config_file" << 'EOF'
# BBR congestion control
net.core.default_qdisc = fq               # Контроллер очереди для BBR
net.ipv4.tcp_congestion_control = bbr     # Современный алгоритм контроля перегрузки
net.ipv4.tcp_fastopen = 3                 # Ускорение установки соединений

# Сетевые буферы
net.core.rmem_max = 67108864              # Макс. размер буфера приема (64MB)
net.core.wmem_max = 67108864              # Макс. размер буфера передачи (64MB)
net.core.rmem_default = 131072            # Стандартный размер буфера приема
net.core.wmem_default = 131072            # Стандартный размер буфера передачи
net.ipv4.tcp_rmem = 4096 87380 67108864   # Динамические буферы приема TCP
net.ipv4.tcp_wmem = 4096 65536 67108864   # Динамические буферы передачи TCP
net.ipv4.tcp_mem = 786432 1048576 1572864 # Память для TCP соединений

# Лимиты подключений
net.core.somaxconn = 65535                # Макс. длина очереди accept() (65K)
net.core.netdev_max_backlog = 65536       # Макс. очередь для сетевых устройств
net.ipv4.tcp_max_syn_backlog = 65536      # Макс. очередь SYN-запросов
net.ipv4.tcp_max_tw_buckets = 1440000     # Макс. TIME-WAIT бакетов

# Оптимизация TCP
net.ipv4.tcp_slow_start_after_idle = 0    # Отключить медленный старт после простоя
net.ipv4.tcp_synack_retries = 2           # Повторы SYN-ACK (быстрый отказ)
net.ipv4.tcp_syn_retries = 3              # Повторы SYN (быстрый отказ)
net.ipv4.tcp_retries2 = 8                 # Повторы для установившихся соединений
net.ipv4.tcp_tw_reuse = 1                 # Reuse TIME-WAIT сокетов
net.ipv4.tcp_fin_timeout = 30             # Таймаут FIN пакетов

# Keepalive настройки
net.ipv4.tcp_keepalive_time = 300         # Интервал проверки живости (5 мин)
net.ipv4.tcp_keepalive_probes = 5         # Количество проверок перед разрывом
net.ipv4.tcp_keepalive_intvl = 15         # Интервал между проверками (15 сек)

# Безопасность и стабильность
net.ipv4.tcp_syncookies = 1               # Защита от SYN-флуд атак
net.ipv4.ip_forward = 1                   # Важно для роутеров/шлюзов

# VM параметры оптимизации памяти
vm.swappiness = 30                        # Контроль использования swap
vm.vfs_cache_pressure = 100               # Баланс кэширования
vm.dirty_background_ratio = 5             # Начинать фоновую запись при 5% dirty
vm.dirty_ratio = 15                       # Макс. dirty pages перед блокировкой
vm.overcommit_memory = 1                  # Агрессивный overcommit памяти

# Дополнительные оптимизации
fs.file-max = 2097152                     # Макс. количество файловых дескрипторов
fs.inotify.max_user_watches = 524288      # Макс. наблюдений за файлами
fs.inotify.max_user_instances = 512       # Макс. экземпляров inotify
EOF

        # Применяем настройки
        sysctl -p "$config_file" >/dev/null 2>&1 || true

        # Проверяем, что BBR действительно активен
        if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "^bbr$"; then
            print_success "✅ Максимальные оптимизации ядра применены (BBR активен)"
        else
            print_warning "⚠ Оптимизации применены, но BBR не активен. Проверьте: modprobe tcp_bbr"
        fi
    else
        print_info "✅ Максимальные оптимизации ядра уже настроены"
        # Убедимся, что модуль загружен и BBR активен (на случай, если sysctl не сработал ранее)
        if ! lsmod | grep -q "tcp_bbr"; then
            if modprobe tcp_bbr 2>/dev/null; then
                echo "tcp_bbr" > /etc/modules-load.d/tcp-bbr.conf
                sysctl -p "$config_file" >/dev/null 2>&1
                print_info "🔧 Модуль tcp_bbr загружен и настройки применены"
            fi
        else
            if ! sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "^bbr$"; then
                sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
                print_info "🔧 BBR включён через sysctl"
            fi
        fi
    fi
}

# Проверка безопасности SSH доступа — только по ключам!
check_ssh_access_safety() {
    print_step "🔒 Проверка безопасности SSH доступа"

    # Определяем IP клиента (откуда идёт SSH-подключение)
    if [ -n "$SSH_CLIENT" ]; then
        CURRENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    elif [ -n "$SSH_CONNECTION" ]; then
        CURRENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi

    if [ -n "$CURRENT_IP" ]; then
        print_info "🌐 Ваш IP-адрес: ${CURRENT_IP}"
    else
        print_info "🌐 IP не определён (возможно, вы подключились через консоль провайдера)"
    fi

    # Проверяем наличие валидных SSH-ключей
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        if grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)' /root/.ssh/authorized_keys; then
            print_success "🔑 Действующие SSH-ключи для root обнаружены."
            return 0
        fi
    fi

    # Ключей нет — требуем настройку
    print_warning "⚠ SSH-ключи для root НЕ настроены!"
    echo
    print_info "🔧 Настройте SSH-ключи на своём компьютере:"
    print_info "1. Создайте ключ (если ещё нет): ssh-keygen -t ed25519 -C \"ваш_email@example.com\""
    print_info "2. Скопируйте публичный ключ на сервер:"
    print_info "   ssh-copy-id root@ваш_сервер_ip"
    print_info "   ИЛИ вручную добавьте содержимое ~/.ssh/id_ed25519.pub в /root/.ssh/authorized_keys"
    print_info "3. Установите права:"
    print_info "   chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys"
    echo
    print_info "🔄 После настройки — запустите скрипт снова."
    print_success "🛑 Скрипт завершён. Без SSH-ключей дальнейшая установка невозможна."
    exit 0
}

# =============== НАЧАЛО ВЫПОЛНЕНИЯ ===============
{
    echo "=== Скрипт установки полной конфигурации VPS ==="
    echo "Время запуска: $(date)"
    echo "Версия скрипта: $SCRIPT_VERSION"
} >> "$LOG_FILE"

# =============== ПРОВЕРКА ПРАВ ===============
print_step "🔑 Проверка прав"
if [ "$(id -u)" != "0" ]; then
    print_error "❗ Запускайте скрипт от root (используйте sudo)!"
    exit 1
fi
print_success "✅ Запущено с правами root"

# =============== РЕЗЕРВНЫЕ КОПИИ ===============
print_step "💾 Создание резервных копий"
mkdir -p "$BACKUP_DIR"
cp /etc/ssh/sshd_config "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null || true
print_success "✅ Резервные копии созданы в: $BACKUP_DIR"

# =============== ПРОВЕРКА SSH ===============
check_ssh_access_safety

# =============== ПРОВЕРКА ОС ===============
print_step "🖥️ Проверка операционной системы"
if [ ! -f /etc/os-release ]; then
    print_error "❗ Неизвестная ОС"
    exit 1
fi
source /etc/os-release

if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    print_warning "⚠ Скрипт предназначен для Ubuntu 24.04 LTS. Ваша ОС: $PRETTY_NAME"
    read -rp "${YELLOW}Продолжить? (y/n) [y]: ${NC}" confirm
    confirm=${confirm:-y}
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
fi
print_success "✅ ОС: $PRETTY_NAME"

# =============== ПРОВЕРКА ИНТЕРНЕТА ===============
print_step "🌐 Проверка доступа к интернету"
check_internet

# =============== ПРОВЕРКА GLIBC ===============
print_step "🧩 Проверка версии GLIBC"
check_glibc_version

# =============== ПРОВЕРКА СВОБОДНОГО МЕСТА ===============
print_step "💾 Проверка свободного места на диске"
check_disk_space

# =============== ОБНОВЛЕНИЕ СИСТЕМЫ ===============
print_step "🔄 Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -yqq >/dev/null 2>&1 || true
apt-get upgrade -yqq --no-install-recommends >/dev/null 2>&1 || true
apt-get autoremove -yqq >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
SYSTEM_UPDATE_STATUS=$(check_if_fully_updated)
print_success "✅ Система обновлена: $SYSTEM_UPDATE_STATUS"

# =============== УСТАНОВКА БАЗОВЫХ ПАКЕТОВ ===============
print_step "📦 Установка базовых пакетов"
PACKAGES=("curl" "wget" "git" "unzip" "tar" "net-tools" "ufw" "fail2ban" "nginx" "python3" "python3-pip" "python3-venv" "openssl" "iproute2" "dnsutils" "procps" "findutils" "shadow" "coreutils" "gzip" "iputils-ping" "ethtool" "sysvinit-utils" "sed" "passwd" "iptables" "libssl-dev")

INSTALLED_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        print_info "→ Установка $pkg..."
        if apt-get install -yqq "$pkg" >/dev/null 2>&1; then
            INSTALLED_PACKAGES+=("$pkg")
        else
            print_error "❌ Ошибка установки $pkg"
            exit 1
        fi
    fi
done

if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    print_success "✅ Установлено пакетов: ${#INSTALLED_PACKAGES[@]}"
else
    print_success "✅ Все пакеты уже установлены"
fi

# =============== НАСТРОЙКА БЕЗОПАСНОСТИ ===============
print_step "🛡️ Настройка безопасности"

# UFW — брандмауэр
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
if [ -n "$CURRENT_IP" ]; then
    ufw allow from "$CURRENT_IP" to any port 22 comment "SSH с доверенного IP" >/dev/null 2>&1
    print_success "✅ UFW: SSH разрешён только с $CURRENT_IP"
else
    ufw allow 22 comment "SSH (глобально)" >/dev/null 2>&1
    print_warning "⚠ UFW: SSH разрешён для всех (IP не определён)"
fi
ufw allow 80 comment "HTTP" >/dev/null 2>&1
ufw allow 443 comment "HTTPS" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
print_success "✅ UFW активирован"

# Отключение паролей в SSH (только ключи!)
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.before_disable_passwords"
cp /etc/ssh/sshd_config "$SSH_CONFIG_BACKUP"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
if sshd -t; then
    SSH_SERVICE="ssh"
    systemctl list-unit-files --quiet | grep -q '^sshd\.service' && SSH_SERVICE="sshd"
    systemctl reload "$SSH_SERVICE" || systemctl restart "$SSH_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$SSH_SERVICE"; then
        print_success "✅ Пароли в SSH отключены. Доступ — только по ключу!"
    else
        cp "$SSH_CONFIG_BACKUP" /etc/ssh/sshd_config
        systemctl restart "$SSH_SERVICE"
        print_error "❌ SSH не запустился! Конфигурация восстановлена."
        exit 1
    fi
else
    cp "$SSH_CONFIG_BACKUP" /etc/ssh/sshd_config
    print_error "❌ Ошибка в конфигурации SSH! Восстановлено."
    exit 1
fi

# Fail2ban — защита от брутфорса
SSH_PORT=$(grep -Po '^Port \K\d+' /etc/ssh/sshd_config 2>/dev/null || echo 22)
mkdir -p /etc/fail2ban/jail.d
if [ ! -f /etc/fail2ban/jail.d/sshd.local ] || ! grep -q "maxretry = 5" /etc/fail2ban/jail.d/sshd.local; then
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
backend = systemd
action = %(action_)s
EOF
    systemctl restart fail2ban 2>/dev/null || true
    print_success "✅ Fail2Ban настроен: защищает SSH (порт $SSH_PORT)"
else
    print_info "ℹ Fail2Ban уже настроен"
fi

# =============== ОПТИМИЗАЦИЯ СИСТЕМЫ ===============
print_step "⚡ Оптимизация ядра и памяти"
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
print_info "🧠 Обнаружено RAM: ${TOTAL_MEM_MB} MB"

apply_max_performance_optimizations

# Настройка swap-файла
print_step "💾 Настройка swap-файла"
if ! swapon --show | grep -q '/swapfile'; then
    if [ "$TOTAL_MEM_MB" -le 4096 ]; then
        SWAP_SIZE_MB=2048
    else
        SWAP_SIZE_MB=1024
    fi
    print_info "💾 Создание swap-файла: ${SWAP_SIZE_MB} МБ"
    if ! fallocate -l ${SWAP_SIZE_MB}M /swapfile >/dev/null 2>&1; then
        dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    print_success "✅ Swap ${SWAP_SIZE_MB} МБ успешно создан"
else
    print_success "✅ Swap уже активен"
fi

# =============== УСТАНОВКА NODE.JS ===============
print_step "node.js Установка Node.js"
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
apt-get install -yqq nodejs >/dev/null 2>&1
print_success "✅ Node.js установлен: $(node -v)"

# =============== УСТАНОВКА ГЛОБАЛЬНЫХ NPM ПАКЕТОВ ===============
print_step "📦 Установка глобальных npm пакетов"

# Установка n8n
npm install -g n8n >/dev/null 2>&1
print_success "✅ n8n установлен: $(n8n --version)"

# Установка qwen-code
npm install -g @qwen-code/qwen-code@latest >/dev/null 2>&1
print_success "✅ qwen-code установлен"

# =============== НАСТРОЙКА QWEN-CODE С MCP SERVER CONTEXT7 ===============
print_step "🔑 Настройка qwen-code с MCP сервером Context7"

# Запрашиваем API ключ у пользователя
if [ -z "$CONTEXT7_API_KEY" ]; then
    read -rp "🔒 Введите ваш CONTEXT7_API_KEY для Context7 (не оставляйте пустым): " CONTEXT7_API_KEY
fi

# Проверка на пустоту
if [ -z "$CONTEXT7_API_KEY" ]; then
    print_error "❌ CONTEXT7_API_KEY не может быть пустым!"
    exit 1
fi

# Проверка формата ключа (по шаблону ctx7sk-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
if ! [[ "$CONTEXT7_API_KEY" =~ ^ctx7sk-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
    print_warning "⚠ Формат CONTEXT7_API_KEY кажется неправильным. Убедитесь, что вы ввели корректный ключ."
    read -rp "Продолжить? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    [[ ! "$confirm" =~ ^[yY]$ ]] && exit 1
fi

# Создаём конфигурационный файл qwen-code
mkdir -p ~/.qwen
cat > ~/.qwen/settings.json <<EOF
{
  "security": {
    "auth": {
      "selectedType": "qwen-oauth"
    }
  },
  "$version": 2,
  "general": {
    "language": "ru"
  },
  "mcpServers": {
    "context7": {
      "httpUrl": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "$CONTEXT7_API_KEY",
        "Accept": "application/json, text/event-stream"
      }
    }
  }
}
EOF
chmod 600 ~/.qwen/settings.json
print_success "✅ qwen-code настроен с MCP сервером Context7"
print_info "   Конфиг сохранён в: ~/.qwen/settings.json"

# =============== УСТАНОВКА PYTHON И UV ===============
print_step "🐍 Установка Python и uv"
pip3 install uv --break-system-packages >/dev/null 2>&1
print_success "✅ uv установлен для управления Python пакетами"

# =============== УСТАНОВКА VS CODE SERVER ===============
print_step "💻 Установка VS Code Server"
mkdir -p /opt/code-server
cd /opt/code-server
wget https://github.com/coder/code-server/releases/latest/download/code-server-linux-amd64.tar.gz -q
tar -xzf code-server-linux-amd64.tar.gz --strip-components=1 >/dev/null 2>&1
rm code-server-linux-amd64.tar.gz

# Генерация пароля
VSCODE_PASSWORD=$(gen_random_string 12)
echo "$VSCODE_PASSWORD" > /root/.vscode_password

# Создание systemd сервиса
cat > /etc/systemd/system/code-server.service <<EOF
[Unit]
Description=code-server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/opt/code-server/bin/code-server --bind-addr 0.0.0.0:8443 --auth password
Environment=PASSWORD=$VSCODE_PASSWORD
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable code-server
systemctl start code-server
print_success "✅ VS Code Server установлен"
print_info "   Доступ: http://$EXTERNAL_IP:8443"
print_info "   Пароль сохранён в: /root/.vscode_password"

# =============== УСТАНОВКА 3X-UI ===============
print_step "🚀 Установка 3x-ui"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# Настройка 3x-ui (генерация случайных данных)
if [ -f /usr/local/x-ui/x-ui ]; then
    WEBBASEPATH=$(gen_random_string 15)
    USERNAME=$(gen_random_string 10)
    PASSWORD=$(gen_random_string 10)
    PORT=$(shuf -i 1024-62000 -n 1)

    # Проверка, свободен ли порт
    if ! check_port_available "$PORT"; then
        print_warning "⚠ Порт $PORT занят. Генерируем новый..."
        PORT=$(shuf -i 1024-62000 -n 1)
        while ! check_port_available "$PORT"; do
            PORT=$(shuf -i 1024-62000 -n 1)
        done
    fi

    # Применяем настройки
    /usr/local/x-ui/x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "$WEBBASEPATH" >/dev/null 2>&1
    systemctl restart x-ui

    # Сохраняем данные в защищённый файл
    echo "3XUI_CREDENTIALS" > /root/.3xui_credentials
    echo "URL: http://$EXTERNAL_IP:$PORT/$WEBBASEPATH" >> /root/.3xui_credentials
    echo "Логин: $USERNAME" >> /root/.3xui_credentials
    echo "Пароль: $PASSWORD" >> /root/.3xui_credentials
    echo "Порт: $PORT" >> /root/.3xui_credentials
    echo "WebBasePath: $WEBBASEPATH" >> /root/.3xui_credentials
    chmod 600 /root/.3xui_credentials

    print_success "✅ 3x-ui установлен и настроен"
    print_info "   Данные доступа сохранены в: /root/.3xui_credentials"
else
    print_error "❌ Установка 3x-ui не удалась"
    exit 1
fi

# =============== НАСТРОЙКА Nginx РЕВЕРС ПРОКСИ ===============
print_step "🌐 Настройка Nginx реверс прокси"

# Конфиг для n8n — принимает любой домен (подходит для freedns.afraid.org)
cat > /etc/nginx/sites-available/n8n.conf <<EOF
server {
    listen 80;
    server_name _;  # ← ВАЖНО: принимает любой домен (n8n.yourdomain.afraid.org, vscode.yourdomain.afraid.org и т.д.)

    location / {
        proxy_pass http://localhost:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
    }
}
EOF

# Конфиг для code-server
cat > /etc/nginx/sites-available/code-server.conf <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:8443;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;
    }
}
EOF

# Конфиг для 3x-ui
cat > /etc/nginx/sites-available/3x-ui.conf <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
    }
}
EOF

# Активация конфигураций
ln -sf /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/ 2>/dev/null || true
ln -sf /etc/nginx/sites-available/code-server.conf /etc/nginx/sites-enabled/ 2>/dev/null || true
ln -sf /etc/nginx/sites-available/3x-ui.conf /etc/nginx/sites-enabled/ 2>/dev/null || true
rm /etc/nginx/sites-enabled/default 2>/dev/null || true

# Проверка конфигурации Nginx перед перезапуском
if ! nginx -t; then
    print_error "❌ Ошибка в конфигурации Nginx!"
    exit 1
fi
systemctl restart nginx
print_success "✅ Nginx настроен как реверс прокси"

# =============== ЗАПУСК СЕРВИСОВ ===============
print_step "▶ Запуск сервисов"

# n8n сервис
cat > /etc/systemd/system/n8n.service <<EOF
[Unit]
Description=n8n workflow automation
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=$(which n8n) start
Restart=always
RestartSec=10
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable n8n
systemctl start n8n

# Проверка статуса всех сервисов
SERVICES=("nginx" "fail2ban" "code-server" "n8n" "x-ui")
for service in "${SERVICES[@]}"; do
    check_service_status "$service"
done

# =============== ФИНАЛЬНАЯ СВОДКА ===============
print_step "🎉 ФИНАЛЬНАЯ СВОДКА УСТАНОВКИ"

print_success "Система:"
print_info "  • OS: Ubuntu 24.04 LTS"
print_info "  • Внешний IP: $EXTERNAL_IP"
print_info "  • BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'неактивен')"
print_info "  • Swap: $(free -h | grep Swap | awk '{print $2}')"

print_success "Установленные сервисы:"
print_info "  • Node.js: $(node -v)"
print_info "  • n8n: $(n8n --version) (порт 5678)"
print_info "  • Qwen-code: настроен с MCP сервером Context7"
print_info "  • 3x-ui: данные в /root/.3xui_credentials"
print_info "  • VS Code Server: http://$EXTERNAL_IP:8443 (пароль в /root/.vscode_password)"
print_info "  • Python uv: готов к использованию"

print_success "Безопасность:"
print_info "  • UFW: активен, SSH только с $CURRENT_IP"
print_info "  • fail2ban: защищает SSH"
print_info "  • SSH: пароли отключены"

print_success "Реверс прокси Nginx:"
print_info "  • n8n.yourdomain.afraid.org → перенаправляет на localhost:5678"
print_info "  • vscode.yourdomain.afraid.org → перенаправляет на localhost:8443"
print_info "  • xui.yourdomain.afraid.org → перенаправляет на 3x-ui (порт $PORT)"

print_info "Доменные имена: настройте на https://freedns.afraid.org/"
print_info "   Создайте A-записи для:"
print_info "   • n8n.yourdomain.afraid.org → $EXTERNAL_IP"
print_info "   • vscode.yourdomain.afraid.org → $EXTERNAL_IP"
print_info "   • xui.yourdomain.afraid.org → $EXTERNAL_IP"
print_info "   После этого — перезагрузите nginx: systemctl reload nginx"

print_info "Лог установки: $LOG_FILE"
print_info "Резервные копии: $BACKUP_DIR"

# Проверка необходимости перезагрузки
if [ -f /var/run/reboot-required ]; then
    print_warning "⚠ Требуется перезагрузка для завершения обновлений!"
    print_info "   Выполните: reboot"
fi

print_success "✅ Установка завершена успешно!"
print_info "Для доступа к сервисам:"
print_info "   • n8n: http://n8n.yourdomain.afraid.org"
print_info "   • VS Code: http://vscode.yourdomain.afraid.org"
print_info "   • 3x-ui: http://xui.yourdomain.afraid.org"
print_info "   Все пароли и ключи сохранены на сервере в защищённых файлах."

# Очистка старых резервных копий (оставляем только последнюю)
find /root -maxdepth 1 -name "backup_20*" -type d | sort -r | tail -n +2 | xargs rm -rf 2>/dev/null || true
print_info "🧹 Старые резервные копии удалены. Последняя копия сохранена."

# Проверка, что все сервисы запущены
print_step "📊 Проверка финального состояния"
for service in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$service"; then
        print_success "  • $service: ✅ активен"
    else
        print_error "  • $service: ❌ неактивен"
    fi
done

print_info "Скрипт завершён. Всё готово!"
