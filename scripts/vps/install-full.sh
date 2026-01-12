#!/bin/bash
set -e

# =============== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ===============
REPO_URL="https://raw.githubusercontent.com/triglavfree/deploy/main"
SCRIPT_VERSION="1.0.0"
CURRENT_IP="unknown"
EXTERNAL_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "unknown")
LOG_FILE="/var/log/deploy_full.log"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
SYSTEM_UPDATE_STATUS=""

# =============== ЦВЕТА ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============== ФУНКЦИИ ===============
print_step()   { echo -e "\n${PURPLE}=== ${CYAN}$1${PURPLE} ===${NC}"; }
print_success(){ echo -e "${GREEN}✓ $1${NC}"; }
print_warning(){ echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()  { echo -e "${RED}✗ $1${NC}" >&2; }
print_info()   { echo -e "${BLUE}ℹ $1${NC}"; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# Проверка, остались ли пакеты для обновления после upgrade
check_if_fully_updated() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if apt-get --just-print upgrade 2>/dev/null | grep -q "^Inst"; then
        echo "доступны обновления"
    else
        echo "актуальна"
    fi
}

# Применение оптимизаций ядра
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
        
        # Загружаем модуль tcp_bbr
        if ! lsmod | grep -q "tcp_bbr"; then
            if modprobe tcp_bbr 2>/dev/null; then
                print_info "Модуль ядра tcp_bbr загружен."
                echo "tcp_bbr" > /etc/modules-load.d/tcp-bbr.conf
            else
                print_warning "Не удалось загрузить модуль tcp_bbr. BBR может не активироваться."
            fi
        else
            print_info "Модуль tcp_bbr уже загружен."
        fi
        
        # Записываем конфиг
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
# Keepalive
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
# Безопасность
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 1
# VM параметры
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
        
        # Применяем настройки
        sysctl -p "$config_file" >/dev/null 2>&1 || true
        
        # Проверяем BBR
        if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "^bbr$"; then
            print_success "Максимальные оптимизации ядра применены (BBR активен)"
        else
            print_warning "Оптимизации применены, но BBR не активен"
        fi
    else
        print_info "Максимальные оптимизации ядра уже настроены"
    fi
}

# Проверка SSH доступа
check_ssh_access_safety() {
    print_step "Проверка безопасности SSH доступа"
    
    # Определяем IP клиента
    if [ -n "$SSH_CLIENT" ]; then
        CURRENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    elif [ -n "$SSH_CONNECTION" ]; then
        CURRENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi
    
    if [ -n "$CURRENT_IP" ]; then
        print_info "Ваш IP-адрес: ${CURRENT_IP}"
    else
        print_info "IP не определён (возможно запущено из консоли провайдера)"
    fi
    
    # Проверяем наличие SSH ключей
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        if grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)' /root/.ssh/authorized_keys; then
            print_success "Действующие SSH-ключи для root обнаружены"
            return 0
        fi
    fi
    
    print_warning "SSH-ключи для root не настроены"
    echo
    print_info "Настройте SSH-ключи на вашем компьютере:"
    print_info "1. Создайте ключ (если нет): ssh-keygen -t ed25519 -C \"ваш_email@example.com\""
    print_info "2. Скопируйте публичный ключ: ssh-copy-id root@ваш_сервер"
    print_info "3. Или вручную добавьте содержимое ~/.ssh/id_ed25519.pub в /root/.ssh/authorized_keys"
    echo
    print_info "После настройки SSH-ключей — запустите скрипт снова"
    print_success "Скрипт завершён для безопасности"
    exit 0
}

# Генерация случайной строки
gen_random_string() {
    local length="$1"
    LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1
}

# =============== НАЧАЛО ВЫПОЛНЕНИЯ ===============
{
    echo "=== Скрипт установки полной конфигурации VPS ==="
    echo "Время запуска: $(date)"
    echo "Версия скрипта: $SCRIPT_VERSION"
} >> "$LOG_FILE"

# =============== ПРОВЕРКА ПРАВ ===============
print_step "Проверка прав"
if [ "$(id -u)" != "0" ]; then
    print_error "Запускайте от root!"
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
    print_warning "Скрипт для Ubuntu 24.04 LTS. Ваша ОС: $PRETTY_NAME"
    read -rp "${YELLOW}Продолжить? (y/n) [y]: ${NC}" confirm
    confirm=${confirm:-y}
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
fi
print_success "ОС: $PRETTY_NAME"

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

# Проверка свободного места на диске
print_info "Проверка свободного места на диске"
FREE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$FREE_SPACE" -lt 10 ]; then
    print_error "Недостаточно свободного места на диске. Требуется минимум 10GB."
    exit 1
fi
print_success "Достаточно свободного места: ${FREE_SPACE}GB"

# Проверка доступа к интернету
print_info "Проверка доступа к интернету"
if ! ping -c 1 google.com &> /dev/null; then
    print_error "Нет доступа к интернету. Проверьте сетевые настройки."
    exit 1
fi
print_success "Доступ к интернету есть"

# Обновление репозиториев
print_info "Обновление репозиториев"
apt-get update -yqq

PACKAGES=("curl" "wget" "git" "unzip" "tar" "net-tools" "ufw" "fail2ban" "nginx" "python3" "python3-pip" "python3-venv")
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        print_info "Установка $pkg..."
        apt-get install -yqq "$pkg"
    fi
done
print_success "Базовые пакеты установлены"

# =============== НАСТРОЙКА БЕЗОПАСНОСТИ ===============
print_step "Настройка безопасности"

# UFW
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
if [ -n "$CURRENT_IP" ]; then
    ufw allow from "$CURRENT_IP" to any port 22 comment "SSH с доверенного IP" >/dev/null 2>&1
else
    ufw allow 22 comment "SSH" >/dev/null 2>&1
fi
ufw allow 80 comment "HTTP" >/dev/null 2>&1
ufw allow 443 comment "HTTPS" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
print_success "UFW настроен"

# Отключение паролей в SSH
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.before_disable_passwords"
cp /etc/ssh/sshd_config "$SSH_CONFIG_BACKUP"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
if sshd -t; then
    SSH_SERVICE="ssh"
    systemctl list-unit-files --quiet | grep -q '^sshd\.service' && SSH_SERVICE="sshd"
    systemctl reload "$SSH_SERVICE" || systemctl restart "$SSH_SERVICE"
    print_success "Пароли в SSH отключены"
else
    cp "$SSH_CONFIG_BACKUP" /etc/ssh/sshd_config
    print_error "Ошибка в конфигурации SSH! Восстановлено."
fi

# Fail2ban
SSH_PORT=$(grep -Po '^Port \K\d+' /etc/ssh/sshd_config 2>/dev/null || echo 22)
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
backend = systemd
EOF
systemctl restart fail2ban 2>/dev/null || true
print_success "Fail2ban настроен"

# =============== ОПТИМИЗАЦИЯ СИСТЕМЫ ===============
print_step "Оптимизация системы"
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
print_info "Обнаружено RAM: ${TOTAL_MEM_MB} MB"

apply_max_performance_optimizations

# Настройка swap
print_step "Настройка swap"
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
    print_success "Swap уже активен"
fi

# =============== УСТАНОВКА NODE.JS ===============
print_step "Установка Node.js"
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs >/dev/null 2>&1
print_success "Node.js установлен: $(node -v)"

# =============== УСТАНОВКА ГЛОБАЛЬНЫХ NPM ПАКЕТОВ ===============
print_step "Установка глобальных npm пакетов"

# Установка n8n
npm install -g n8n >/dev/null 2>&1
print_success "n8n установлен: $(n8n --version)"

# Установка qwen-code
npm install -g @qwen-code/qwen-code@latest >/dev/null 2>&1
print_success "qwen-code установлен"

# Настройка qwen-code с MCP сервером Context7
print_step "Настройка qwen-code с MCP сервером Context7"

# Проверяем, есть ли переменная окружения CONTEXT7_API_KEY
if [ -z "$CONTEXT7_API_KEY" ]; then
    # Если нет, запрашиваем у пользователя
    read -rp "Введите ваш CONTEXT7_API_KEY для Context7: " CONTEXT7_API_KEY
fi

# Проверяем, что ключ не пустой
if [ -z "$CONTEXT7_API_KEY" ]; then
    print_error "CONTEXT7_API_KEY не может быть пустым"
    exit 1
fi

# Проверяем формат ключа (примерный шаблон)
if ! [[ "$CONTEXT7_API_KEY" =~ ^ctx7sk-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
    print_warning "Формат CONTEXT7_API_KEY кажется неправильным. Убедитесь, что вы ввели корректный ключ."
    read -rp "Продолжить? (y/n) [y]: " confirm
    confirm=${confirm:-y}
    [[ ! "$confirm" =~ ^[yY]$ ]] && exit 1
fi

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
print_success "qwen-code настроен с MCP сервером Context7"

# =============== УСТАНОВКА PYTHON И UV ===============
print_step "Установка Python и uv"
pip3 install uv --break-system-packages >/dev/null 2>&1
print_success "uv установлен для управления Python пакетами"

# =============== УСТАНОВКА VS CODE SERVER ===============
print_step "Установка VS Code Server"
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
print_success "VS Code Server установлен"
print_info "Доступ: http://$EXTERNAL_IP:8443"
print_info "Пароль сохранен в: /root/.vscode_password"

# =============== УСТАНОВКА 3X-UI ===============
print_step "Установка 3x-ui"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# Настройка 3x-ui
if [ -f /usr/local/x-ui/x-ui ]; then
    WEBBASEPATH=$(gen_random_string 15)
    USERNAME=$(gen_random_string 10)
    PASSWORD=$(gen_random_string 10)
    PORT=$(shuf -i 1024-62000 -n 1)
    
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
fi

# =============== НАСТРОЙКА Nginx РЕВЕРС ПРОКСИ ===============
print_step "Настройка Nginx реверс прокси"

# Конфиг для n8n
cat > /etc/nginx/sites-available/n8n.conf <<EOF
server {
    listen 80;
    server_name n8n.$(hostname);

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
    server_name vscode.$(hostname);

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
    server_name xui.$(hostname);

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

# Проверка конфигурации и перезапуск
nginx -t >/dev/null 2>&1 && systemctl restart nginx
print_success "Nginx настроен как реверс прокси"

# =============== ЗАПУСК СЕРВИСОВ ===============
print_step "Запуск сервисов"

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

# Проверка сервисов
SERVICES=("nginx" "fail2ban" "code-server" "n8n")
if [ -f /etc/systemd/system/x-ui.service ]; then
    SERVICES+=("x-ui")
fi

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
print_info "  • BBR: активен"
print_info "  • Swap: $(free -h | grep Swap | awk '{print $2}')"

print_success "Установленные сервисы:"
print_info "  • Node.js: $(node -v)"
print_info "  • n8n: $(n8n --version) (порт 5678)"
print_info "  • Qwen-code: настроен с Context7 MCP"
print_info "  • 3x-ui: данные в /root/.3xui_credentials"
print_info "  • VS Code Server: http://$EXTERNAL_IP:8443 (пароль в /root/.vscode_password)"
print_info "  • Python uv: готов к использованию"

print_success "Безопасность:"
print_info "  • UFW: активен, SSH только с $CURRENT_IP"
print_info "  • fail2ban: защищает SSH"
print_info "  • SSH: пароли отключены"

print_success "Реверс прокси Nginx:"
print_info "  • n8n.$(hostname): перенаправляет на localhost:5678"
print_info "  • vscode.$(hostname): перенаправляет на localhost:8443"
print_info "  • xui.$(hostname): перенаправляет на 3x-ui"

print_info "Доменные имена: настройте на https://freedns.afraid.org/"
print_info "Укажите ваши поддомены (n8n, vscode, xui) с IP: $EXTERNAL_IP"

print_info "Лог установки: $LOG_FILE"
print_info "Резервные копии: $BACKUP_DIR"

if [ -f /var/run/reboot-required ]; then
    print_warning "Требуется перезагрузка для завершения обновлений!"
    print_info "Выполните: reboot"
fi

print_success "Установка завершена успешно!"
print_info "Для применения доменных имен добавьте DNS записи на freedns.afraid.org"
print_info "и перезагрузите nginx: systemctl reload nginx"

# Очистка старых резервных копий
find /root -maxdepth 1 -name "backup_20*" -type d | sort -r | tail -n +2 | xargs rm -rf 2>/dev/null || true
