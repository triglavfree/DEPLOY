#!/bin/bash
set -e

# ================================================
# ИДЕМПОТЕНТНЫЙ СКРИПТ УСТАНОВКИ ПОЛНОЙ КОНФИГУРАЦИИ VPS
# Для Ubuntu 24.04 LTS, vCPU x2, RAM 4GB, 60GB HDD
# Автор: triglavfree
# Репозиторий: https://github.com/triglavfree/DEPLOY
# ================================================

# =============== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ===============
REPO_URL="https://raw.githubusercontent.com/triglavfree/deploy/main"
SCRIPT_VERSION="1.4.0"
CURRENT_IP="unknown"
EXTERNAL_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "unknown")
LOG_FILE="/var/log/deploy_full.log"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
SYSTEM_UPDATE_STATUS=""
IDEMPOTENT_MARKER="/root/.deploy_full_installed"  # Метка завершённой установки

# =============== ЦВЕТА ДЛЯ ВЫВОДА ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============== ФУНКЦИИ ===============
print_step()   { echo -e "\n${PURPLE}=== ${CYAN}$1${PURPLE} ===${NC}"; }
print_success(){ echo -e "${GREEN}[OK] $1${NC}"; }
print_warning(){ echo -e "${YELLOW}[WARN] $1${NC}"; }
print_error()  { echo -e "${RED}[ERROR] $1${NC}" >&2; }
print_info()   { echo -e "${BLUE}[INFO] $1${NC}"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}

check_port_available() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 1
    else
        return 0
    fi
}

check_internet() {
    if ! ping -c 1 -W 3 google.com &> /dev/null; then
        print_error "Нет доступа к интернету. Проверьте сетевые настройки."
        exit 1
    fi
}

check_glibc_version() {
    glibc_version=$(ldd --version | head -n1 | awk '{print $NF}')
    required_version="2.32"
    if [[ "$(printf '%s\n' "$required_version" "$glibc_version" | sort -V | head -n1)" != "$required_version" ]]; then
        print_error "Ваша версия GLIBC ($glibc_version) устарела. Требуется минимум 2.32."
        print_error "   Убедитесь, что вы используете Ubuntu 24.04 LTS."
        exit 1
    fi
    print_info "GLIBC версия: $glibc_version (подходит)"
}

check_disk_space() {
    local free_space_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$free_space_gb" -lt 10 ]; then
        print_error "Недостаточно места на диске. Требуется минимум 10 ГБ, у вас: ${free_space_gb} ГБ"
        exit 1
    fi
    print_info "Достаточно места: ${free_space_gb} ГБ"
}

check_service_status() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        print_success "Сервис $service активен"
    else
        print_error "Сервис $service НЕ АКТИВЕН!"
        systemctl status "$service" --no-pager -l | head -n 8
        return 1
    fi
}

check_if_fully_updated() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if apt-get --just-print upgrade 2>/dev/null | grep -q "^Inst"; then
        echo "доступны обновления"
    else
        echo "актуальна"
    fi
}

apply_max_performance_optimizations() {
    local config_file="/etc/sysctl.d/99-max-performance.conf"
    local needs_update=false

    if [ ! -f "$config_file" ]; then
        needs_update=true
    else
        if ! grep -q "net.ipv4.tcp_congestion_control = bbr" "$config_file"; then
            needs_update=true
        fi
    fi

    if [ "$needs_update" = true ]; then
        print_info "Применение максимальных оптимизаций ядра..."
        mkdir -p /etc/sysctl.d

        if ! lsmod | grep -q "tcp_bbr"; then
            if modprobe tcp_bbr 2>/dev/null; then
                print_info "Модуль ядра tcp_bbr загружен."
                echo "tcp_bbr" > /etc/modules-load.d/tcp-bbr.conf
            else
                print_warning "Не удалось загрузить модуль tcp_bbr. BBR может не работать."
            fi
        else
            print_info "Модуль tcp_bbr уже загружен."
        fi

        cat > "$config_file" << 'EOF'
# BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# Сетевые буферы
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = 786432 1048576 1572864

# Лимиты подключений
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 1440000

# Оптимизация TCP
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# Keepalive настройки
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Безопасность и стабильность
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 1

# VM параметры оптимизации памяти
vm.swappiness = 30
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.overcommit_memory = 1

# Дополнительные оптимизации
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

        sysctl -p "$config_file" >/dev/null 2>&1 || true

        if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "^bbr$"; then
            print_success "Максимальные оптимизации ядра применены (BBR активен)"
        else
            print_warning "Оптимизации применены, но BBR не активен."
        fi
    else
        print_info "Максимальные оптимизации ядра уже настроены"
    fi
}

check_ssh_access_safety() {
    print_step "Проверка безопасности SSH доступа"

    if [ -n "$SSH_CLIENT" ]; then
        CURRENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    elif [ -n "$SSH_CONNECTION" ]; then
        CURRENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi

    if [ -n "$CURRENT_IP" ]; then
        print_info "Ваш IP-адрес: ${CURRENT_IP}"
    else
        print_info "IP не определён (возможно, консоль провайдера)"
    fi

    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        if grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)' /root/.ssh/authorized_keys; then
            print_success "Действующие SSH-ключи для root обнаружены."
            return 0
        fi
    fi

    print_warning "SSH-ключи для root НЕ настроены!"
    echo
    print_info "Настройте SSH-ключи на своём компьютере:"
    print_info "1. ssh-keygen -t ed25519 -C \"ваш_email@example.com\""
    print_info "2. ssh-copy-id root@ваш_сервер_ip"
    print_info "3. chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys"
    echo
    print_info "После настройки — запустите скрипт снова."
    print_success "Скрипт завершён. Без SSH-ключей дальнейшая установка невозможна."
    exit 0
}

# =============== НАЧАЛО ВЫПОЛНЕНИЯ ===============
{
    echo "=== Идемпотентный скрипт установки VPS ==="
    echo "Время запуска: $(date)"
    echo "Версия скрипта: $SCRIPT_VERSION"
} >> "$LOG_FILE"

# =============== ПРОВЕРКА ЗАВЕРШЁННОСТИ ===============
if [ -f "$IDEMPOTENT_MARKER" ]; then
    print_success "Скрипт уже выполнен ранее. Пропускаем полную установку."
    print_info "Для повторной настройки удалите файл: $IDEMPOTENT_MARKER"
    exit 0
fi

# =============== ПРОВЕРКА ПРАВ ===============
print_step "Проверка прав"
if [ "$(id -u)" != "0" ]; then
    print_error "Запускайте скрипт от root (используйте sudo)!"
    exit 1
fi
print_success "Запущено с правами root"

# =============== РЕЗЕРВНЫЕ КОПИИ ===============
print_step "Создание резервных копий"
mkdir -p "$BACKUP_DIR"
cp /etc/ssh/sshd_config "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null || true
print_success "Резервные копии созданы в: $BACKUP_DIR"

# =============== ПРОВЕРКА SSH ===============
check_ssh_access_safety

# =============== ПРОВЕРКА ОС ===============
print_step "Проверка операционной системы"
if [ ! -f /etc/os-release ]; then
    print_error "Неизвестная ОС"
    exit 1
fi
source /etc/os-release

if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    print_warning "Скрипт предназначен для Ubuntu 24.04 LTS. Ваша ОС: $PRETTY_NAME"
    read -rp "${YELLOW}Продолжить? (y/n) [y]: ${NC}" confirm
    confirm=${confirm:-y}
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
fi
print_success "ОС: $PRETTY_NAME"

# =============== ПРОВЕРКА ИНТЕРНЕТА ===============
print_step "Проверка доступа к интернету"
check_internet

# =============== ПРОВЕРКА GLIBC ===============
print_step "Проверка версии GLIBC"
check_glibc_version

# =============== ПРОВЕРКА СВОБОДНОГО МЕСТА ===============
print_step "Проверка свободного места на диске"
check_disk_space

# =============== ОБНОВЛЕНИЕ СИСТЕМЫ ===============
print_step "Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -yqq >/dev/null 2>&1 || true
apt-get upgrade -yqq --no-install-recommends >/dev/null 2>&1 || true
apt-get autoremove -yqq >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
SYSTEM_UPDATE_STATUS=$(check_if_fully_updated)
print_success "Система обновлена: $SYSTEM_UPDATE_STATUS"

# =============== УСТАНОВКА БАЗОВЫХ ПАКЕТОВ ===============
print_step "Установка базовых пакетов"

PACKAGES=("curl" "wget" "git" "unzip" "tar" "net-tools" "ufw" "fail2ban" "nginx" "python3" "python3-pip" "python3-venv" "openssl" "iproute2" "dnsutils" "procps" "findutils" "coreutils" "gzip" "iputils-ping" "ethtool" "sysvinit-utils" "sed" "passwd" "iptables" "libssl-dev" "ca-certificates")

INSTALLED_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "^install ok installed$"; then
        print_info "→ Установка $pkg..."
        if apt-get install -yqq "$pkg" >/dev/null 2>&1; then
            INSTALLED_PACKAGES+=("$pkg")
        else
            print_error "Ошибка установки $pkg"
            exit 1
        fi
    fi
done

# Проверка shadow по наличию бинарника
if ! command -v passwd >/dev/null 2>&1; then
    print_info "→ Установка системного пакета shadow..."
    if apt-get install -yqq shadow >/dev/null 2>&1; then
        INSTALLED_PACKAGES+=("shadow")
    else
        print_error "Ошибка установки shadow"
        exit 1
    fi
else
    print_info "→ Системные утилиты управления пользователями уже установлены"
fi

if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    print_success "Установлено пакетов: ${#INSTALLED_PACKAGES[@]}"
else
    print_success "Все пакеты уже установлены"
fi

# =============== НАСТРОЙКА БЕЗОПАСНОСТИ ===============
print_step "Настройка безопасности"

# UFW — брандмауэр
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1

# Открываем порты ДО установки 3x-ui, VS Code, n8n и выпуска сертификатов!
# Порт 22 — SSH (только с вашего IP)
# Порт 80 — HTTP (Let's Encrypt ACME challenge + Nginx reverse proxy)
# Порт 443 — HTTPS (резерв для будущих сервисов)
if [ -n "$CURRENT_IP" ]; then
    ufw allow from "$CURRENT_IP" to any port 22 comment "SSH с доверенного IP" >/dev/null 2>&1
    print_success "UFW: SSH разрешён только с $CURRENT_IP"
else
    ufw allow 22 comment "SSH (глобально)" >/dev/null 2>&1
    print_warning "UFW: SSH разрешён для всех (IP не определён)"
fi
ufw allow 80 comment "HTTP (ACME + Nginx)" >/dev/null 2>&1
ufw allow 443 comment "HTTPS" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
print_success "UFW активирован"

# Отключение паролей в SSH (только ключи!)
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.before_disable_passwords"
if [ ! -f "$SSH_CONFIG_BACKUP" ]; then
    cp /etc/ssh/sshd_config "$SSH_CONFIG_BACKUP"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    if sshd -t; then
        SSH_SERVICE="ssh"
        systemctl list-unit-files --quiet | grep -q '^sshd\.service' && SSH_SERVICE="sshd"
        systemctl reload "$SSH_SERVICE" || systemctl restart "$SSH_SERVICE"
        sleep 2
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            print_success "Пароли в SSH отключены. Доступ — только по ключу!"
        else
            cp "$SSH_CONFIG_BACKUP" /etc/ssh/sshd_config
            systemctl restart "$SSH_SERVICE"
            print_error "SSH не запустился! Конфигурация восстановлена."
            exit 1
        fi
    else
        cp "$SSH_CONFIG_BACKUP" /etc/ssh/sshd_config
        print_error "Ошибка в конфигурации SSH! Восстановлено."
        exit 1
    fi
else
    print_info "SSH уже настроен без паролей — пропускаем"
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
    print_success "Fail2Ban настроен: защищает SSH (порт $SSH_PORT)"
else
    print_info "Fail2Ban уже настроен — пропускаем"
fi

# =============== ОПТИМИЗАЦИЯ СИСТЕМЫ ===============
print_step "Оптимизация ядра и памяти"
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
print_info "Обнаружено RAM: ${TOTAL_MEM_MB} MB"

apply_max_performance_optimizations

# Настройка swap
print_step "Настройка swap-файла"
if ! swapon --show | grep -q '/swapfile'; then
    if [ "$TOTAL_MEM_MB" -le 4096 ]; then
        SWAP_SIZE_MB=2048
    else
        SWAP_SIZE_MB=1024
    fi
    print_info "Создание swap-файла: ${SWAP_SIZE_MB} МБ"
    if ! fallocate -l ${SWAP_SIZE_MB}M /swapfile >/dev/null 2>&1; then
        dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    print_success "Swap ${SWAP_SIZE_MB} МБ успешно создан"
else
    print_success "Swap уже активен — пропускаем"
fi

# =============== УСТАНОВКА NODE.JS ===============
print_step "Установка Node.js"
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
    apt-get install -yqq nodejs >/dev/null 2>&1
    print_success "Node.js установлен: $(node -v)"
else
    print_info "Node.js уже установлен — пропускаем"
fi

# =============== УСТАНОВКА ГЛОБАЛЬНЫХ NPM ПАКЕТОВ ===============
print_step "Установка глобальных npm пакетов"

# Установка n8n
if ! command -v n8n >/dev/null 2>&1; then
    print_info "→ Установка n8n..."
    npm install -g n8n >/dev/null 2>&1
    print_success "n8n установлен: $(n8n --version)"
else
    print_info "→ n8n уже установлен — пропускаем"
fi

# Установка qwen-code
if ! command -v qwen-code >/dev/null 2>&1; then
    print_info "→ Установка qwen-code..."
    npm install -g @qwen-code/qwen-code@latest >/dev/null 2>&1
    print_success "qwen-code установлен"
else
    print_info "→ qwen-code уже установлен — пропускаем"
fi

# =============== НАСТРОЙКА QWEN-CODE С MCP SERVER CONTEXT7 ===============
print_step "Настройка qwen-code с MCP сервером Context7"

CONTEXT7_CONFIG_FILE="$HOME/.qwen/settings.json"
CONTEXT7_MARKER="/root/.context7_configured"

if [ -f "$CONTEXT7_MARKER" ] && [ -f "$CONTEXT7_CONFIG_FILE" ]; then
    print_success "MCP Context7 уже настроен — пропускаем запрос API-ключа"
else
    if [ -z "$CONTEXT7_API_KEY" ]; then
        if [ -t 0 ]; then
            read -rp "Введите ваш CONTEXT7_API_KEY для Context7 (не оставляйте пустым): " CONTEXT7_API_KEY
        else
            print_error "Скрипт запущен через pipe. Для интерактивного ввода:"
            print_error "curl -O https://.../install-full.sh && chmod +x install-full.sh && sudo -E ./install-full.sh"
            exit 1
        fi
    fi

    if [ -z "$CONTEXT7_API_KEY" ]; then
        print_error "CONTEXT7_API_KEY не может быть пустым!"
        exit 1
    fi

    if ! [[ "$CONTEXT7_API_KEY" =~ ^ctx7sk-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        print_warning "Формат CONTEXT7_API_KEY кажется неправильным."
        read -rp "Продолжить? (y/n) [y]: " confirm
        confirm=${confirm:-y}
        [[ ! "$confirm" =~ ^[yY]$ ]] && exit 1
    fi

    mkdir -p ~/.qwen
    cat > "$CONTEXT7_CONFIG_FILE" <<EOF
{
  "security": {
    "auth": {
      "selectedType": "qwen-oauth"
    }
  },
  "\$version": 2,
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
    chmod 600 "$CONTEXT7_CONFIG_FILE"
    print_success "qwen-code настроен с MCP сервером Context7"
    print_info "Конфиг сохранён в: $CONTEXT7_CONFIG_FILE"

    # Сохраняем метку настройки (без ключа!)
    echo "CONTEXT7_CONFIGURED=true" > "$CONTEXT7_MARKER"
    chmod 600 "$CONTEXT7_MARKER"
fi

# =============== УСТАНОВКА PYTHON И UV ===============
print_step "Установка Python и uv"
if ! command -v uv >/dev/null 2>&1; then
    pip3 install uv --break-system-packages >/dev/null 2>&1
    print_success "uv установлен для управления Python пакетами"
else
    print_info "uv уже установлен — пропускаем"
fi

# =============== УСТАНОВКА VS CODE SERVER ===============
print_step "Установка VS Code Server"
if ! command -v code-server >/dev/null 2>&1; then
    print_info "→ Установка code-server (вывод скрыт)..."
    if ! curl -fsSL https://code-server.dev/install.sh | sh >/dev/null 2>&1; then
        print_error "Не удалось установить code-server"
        exit 1
    fi
else
    print_info "→ code-server уже установлен — пропускаем"
fi

# Генерация пароля (если ещё не создан)
VSCODE_PASSWORD_FILE="/root/.vscode_password"
if [ ! -f "$VSCODE_PASSWORD_FILE" ]; then
    VSCODE_PASSWORD=$(gen_random_string 12)
    echo "$VSCODE_PASSWORD" > "$VSCODE_PASSWORD_FILE"
    chmod 600 "$VSCODE_PASSWORD_FILE"
fi
VSCODE_PASSWORD=$(cat "$VSCODE_PASSWORD_FILE")

# Настройка config.yaml
CONFIG_DIR="/root/.config/code-server"
mkdir -p "$CONFIG_DIR" >/dev/null 2>&1
cat > "$CONFIG_DIR/config.yaml" <<EOF >/dev/null 2>&1
bind-addr: 0.0.0.0:8443
auth: password
password: $VSCODE_PASSWORD
cert: false
EOF

# Включаем linger для root — чтобы пользовательские сервисы работали без активной сессии
loginctl enable-linger root >/dev/null 2>&1

# Перезагружаем systemd и запускаем пользовательский сервис
systemctl --user daemon-reload >/dev/null 2>&1
systemctl --user enable --now code-server >/dev/null 2>&1

# Проверка статуса
if systemctl --user is-active --quiet code-server; then
    print_success "VS Code Server установлен и запущен"
    print_info "Доступ: http://$EXTERNAL_IP:8443"
    print_info "Пароль сохранён в: /root/.vscode_password"
else
    print_error "Не удалось запустить VS Code Server"
    exit 1
fi
# =============== УСТАНОВКА 3X-UI ===============
print_step "Установка 3x-ui"
XUI_SERVICE="/etc/systemd/system/x-ui.service"
if [ ! -f "$XUI_SERVICE" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

    if [ -f /usr/local/x-ui/x-ui ]; then
        WEBBASEPATH=$(gen_random_string 15)
        USERNAME=$(gen_random_string 10)
        PASSWORD=$(gen_random_string 10)
        PORT=$(shuf -i 1024-62000 -n 1)

        while ! check_port_available "$PORT"; do
            PORT=$(shuf -i 1024-62000 -n 1)
        done

        /usr/local/x-ui/x-ui setting -username "$USERNAME" -password "$PASSWORD" -port "$PORT" -webBasePath "$WEBBASEPATH" >/dev/null 2>&1
        systemctl restart x-ui

        echo "3XUI_CREDENTIALS" > /root/.3xui_credentials
        echo "URL: http://$EXTERNAL_IP:$PORT/$WEBBASEPATH" >> /root/.3xui_credentials
        echo "Логин: $USERNAME" >> /root/.3xui_credentials
        echo "Пароль: $PASSWORD" >> /root/.3xui_credentials
        echo "Порт: $PORT" >> /root/.3xui_credentials
        echo "WebBasePath: $WEBBASEPATH" >> /root/.3xui_credentials
        chmod 600 /root/.3xui_credentials

        print_success "3x-ui установлен и настроен"
        print_info "Данные доступа сохранены в: /root/.3xui_credentials"
    else
        print_error "Установка 3x-ui не удалась"
        exit 1
    fi
else
    print_info "3x-ui уже установлен — пропускаем"
fi

# =============== НАСТРОЙКА Nginx РЕВЕРС ПРОКСИ ===============
print_step "Настройка Nginx реверс прокси"

NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_N8N_CONF="$NGINX_SITES_AVAILABLE/n8n.conf"
NGINX_CODE_CONF="$NGINX_SITES_AVAILABLE/code-server.conf"
NGINX_XUI_CONF="$NGINX_SITES_AVAILABLE/3x-ui.conf"

# Получаем порт 3x-ui из конфига
if [ -f /root/.3xui_credentials ]; then
    XUI_PORT=$(grep "Порт:" /root/.3xui_credentials | awk '{print $2}')
else
    XUI_PORT=8080
fi

# n8n
if [ ! -f "$NGINX_N8N_CONF" ]; then
    cat > "$NGINX_N8N_CONF" <<EOF
server {
    listen 80;
    server_name _;

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
fi

# code-server
if [ ! -f "$NGINX_CODE_CONF" ]; then
    cat > "$NGINX_CODE_CONF" <<EOF
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
fi

# 3x-ui
if [ ! -f "$NGINX_XUI_CONF" ]; then
    cat > "$NGINX_XUI_CONF" <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$XUI_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
    }
}
EOF
fi

# Активация
for site in n8n code-server 3x-ui; do
    if [ ! -L "/etc/nginx/sites-enabled/$site.conf" ]; then
        ln -sf "$NGINX_SITES_AVAILABLE/$site.conf" /etc/nginx/sites-enabled/
    fi
done
rm /etc/nginx/sites-enabled/default 2>/dev/null || true

if nginx -t; then
    systemctl restart nginx
    print_success "Nginx настроен как реверс прокси"
else
    print_error "Ошибка в конфигурации Nginx!"
    exit 1
fi

# =============== ЗАПУСК СЕРВИСОВ ===============
print_step "Запуск сервисов"

# n8n
N8N_SERVICE="/etc/systemd/system/n8n.service"
if [ ! -f "$N8N_SERVICE" ]; then
    cat > "$N8N_SERVICE" <<EOF
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
    print_success "n8n запущен"
else
    print_info "n8n уже настроен — пропускаем"
fi

# Проверка статуса всех сервисов
SERVICES=("nginx" "fail2ban" "code-server" "n8n" "x-ui")
for service in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$service"; then
        print_success "Сервис $service активен"
    else
        print_warning "Сервис $service неактивен"
    fi
done

# =============== ФИНАЛЬНАЯ СВОДКА ===============
print_step "ФИНАЛЬНАЯ СВОДКА УСТАНОВКИ"

print_success "Система:"
print_info "  • OS: Ubuntu 24.04 LTS"
print_info "  • Внешний IP: $EXTERNAL_IP"
print_info "  • BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'неактивен')"
print_info "  • Swap: $(free -h | grep Swap | awk '{print $2}')"

print_success "Установленные сервисы:"
print_info "  • Node.js: $(node -v)"
print_info "  • n8n: $(n8n --version) (порт 5678)"

# Информация о Context7 без раскрытия ключа
if [ -f /root/.context7_configured ]; then
    print_success "  • Qwen-code: настроен с MCP сервером Context7"
    print_info "    → Конфиг: ~/.qwen/settings.json (права 600)"
else
    print_warning "  • Qwen-code: MCP Context7 не настроен"
fi

print_info "  • 3x-ui: данные в /root/.3xui_credentials"
print_info "  • VS Code Server: http://$EXTERNAL_IP:8443 (пароль в /root/.vscode_password)"
print_info "  • Python uv: готов к использованию"

print_success "Безопасность:"
print_info "  • UFW: активен, SSH только с $CURRENT_IP"
print_info "  • fail2ban: защищает SSH"
print_info "  • SSH: пароли отключены"

print_success "Реверс прокси Nginx:"
print_info "  • n8n.yourdomain.afraid.org → localhost:5678"
print_info "  • vscode.yourdomain.afraid.org → localhost:8443"
print_info "  • xui.yourdomain.afraid.org → 3x-ui (порт $XUI_PORT)"

print_info "Доменные имена: настройте на https://freedns.afraid.org/"
print_info "   Создайте A-записи для ваших поддоменов → $EXTERNAL_IP"

print_info "Лог установки: $LOG_FILE"
print_info "Резервные копии: $BACKUP_DIR"

if [ -f /var/run/reboot-required ]; then
    print_warning "Требуется перезагрузка для завершения обновлений!"
    print_info "   Выполните: reboot"
fi

# Создаём метку завершённой установки
touch "$IDEMPOTENT_MARKER"
chmod 600 "$IDEMPOTENT_MARKER"
print_success "Установка завершена успешно! Метка создана: $IDEMPOTENT_MARKER"

print_info "💡 Совет: для проверки настроек Context7 выполните:"
print_info "   grep -A3 -B1 CONTEXT7_API_KEY ~/.qwen/settings.json"

# Очистка старых резервных копий
find /root -maxdepth 1 -name "backup_20*" -type d | sort -r | tail -n +2 | xargs rm -rf 2>/dev/null || true
print_info "Старые резервные копии удалены."
print_info "Скрипт завершён. Всё готово!"
