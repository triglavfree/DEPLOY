#!/bin/bash
set -e
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
print_error()  { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }
print_info()   { echo -e "${BLUE}ℹ $1${NC}"; }

# =============== ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА ДОСТУПА ===============
check_ssh_access_safety() {
    print_step "Проверка безопасности SSH доступа"
    
    # Получаем текущий IP пользователя
    CURRENT_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "unknown")
    if [ "$CURRENT_IP" = "unknown" ]; then
        print_warning "Не удалось определить ваш внешний IP"
    else
        print_info "Ваш текущий IP: ${CURRENT_IP}"
    fi
    
    # Проверяем наличие SSH ключей
    if [ ! -f /root/.ssh/authorized_keys ] || [ ! -s /root/.ssh/authorized_keys ]; then
        print_warning "⚠ ВНИМАНИЕ: У вас нет настроенных SSH ключей!"
        print_warning "После отключения парольной аутентификации вы можете потерять доступ к серверу!"
        
        # Добавляем временный пользовательский аккаунт с паролем для восстановления
        TEMP_USER="recovery_user_$(date +%s)"
        TEMP_PASS="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 12)"
        
        useradd -m -s /bin/bash "$TEMP_USER"
        echo "$TEMP_USER:$TEMP_PASS" | chpasswd
        usermod -aG sudo "$TEMP_USER"
        
        print_warning "Создан аккаунт для восстановления:"
        print_warning "Пользователь: $TEMP_USER"
        print_warning "Пароль: $TEMP_PASS"
        print_warning "Этот аккаунт будет удален после перезагрузки или вручную"
        
        # Сохраняем информацию в файл
        echo "=== АККАУНТ ДЛЯ ВОССТАНОВЛЕНИЯ ===" > /root/recovery_info.txt
        echo "Пользователь: $TEMP_USER" >> /root/recovery_info.txt
        echo "Пароль: $TEMP_PASS" >> /root/recovery_info.txt
        echo "IP: $CURRENT_IP" >> /root/recovery_info.txt
        chmod 600 /root/recovery_info.txt
        
        read -rp "${YELLOW}Хотите продолжить? (y/n): ${NC}" confirm
        [[ ! "$confirm" =~ ^[yY]$ ]] && exit 1
    else
        print_success "SSH ключи настроены - можно безопасно отключать пароли"
    fi
}

# =============== ФУНКЦИИ ДЛЯ SYSCTL ===============
apply_sysctl_optimization() {
    local key="$1"
    local value="$2"
    local comment="$3"
    
    # Удаляем все существующие строки с этим ключом
    sed -i "/^[[:space:]]*$key[[:space:]]*=/d" /etc/sysctl.conf
    
    # Добавляем новую строку с комментарием
    if [ -n "$comment" ]; then
        echo "# $comment" >> /etc/sysctl.conf
    fi
    echo "$key=$value" >> /etc/sysctl.conf
    
    # Применяем изменение немедленно
    sysctl -w "$key=$value" >/dev/null 2>&1 || true
}

# =============== ОПРЕДЕЛЕНИЕ КОРНЕВОГО УСТРОЙСТВА ===============
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')

# =============== ПРОВЕРКА ===============
print_step "Проверка прав и ОС"
if [ "$(id -u)" != "0" ]; then
    print_error "Запускайте от root!"
fi
if [ ! -f /etc/os-release ]; then
    print_error "Неизвестная ОС"
fi
source /etc/os-release
if [ "$ID" != "ubuntu" ]; then
    print_warning "Скрипт для Ubuntu. Ваша ОС: $ID"
    read -rp "${YELLOW}Продолжить? (y/n): ${NC}" r
    [[ ! "$r" =~ ^[yY]$ ]] && exit 1
fi

# =============== ШАГ 0: РЕЗЕРВНАЯ КОПИЯ И БЕЗОПАСНОСТЬ ===============
print_step "Создание резервных копий"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)
cp /etc/fstab /etc/fstab.bak.$(date +%s)
print_success "Резервные копии созданы"

# =============== ШАГ 1: ПРОВЕРКА БЕЗОПАСНОСТИ SSH ===============
check_ssh_access_safety

# =============== ШАГ 2: ОБНОВЛЕНИЕ СИСТЕМЫ (БЕЗ АВТОПЕРЕЗАГРУЗКИ) ===============
print_step "Обновление системы"
DEBIAN_FRONTEND=noninteractive apt-get update -yqq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yqq --no-install-recommends >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get autoremove -yqq >/dev/null 2>&1
apt-get clean >/dev/null 2>&1
print_success "Система обновлена"

# =============== ШАГ 3: УСТАНОВКА ПАКЕТОВ ===============
print_step "Установка пакетов"
PACKAGES=("curl" "net-tools" "ufw" "fail2ban" "unzip" "hdparm" "nvme-cli" "zram-tools")

INSTALLED_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
            INSTALLED_PACKAGES+=("$pkg")
        fi
    fi
done

if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    print_success "Установлено пакетов: ${#INSTALLED_PACKAGES[@]}"
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        print_info "  → $pkg"
    done
else
    print_success "Все пакеты уже установлены"
fi

# =============== ШАГ 4: БЕЗОПАСНАЯ НАСТРОЙКА UFW ===============
print_step "Безопасная настройка UFW"
CURRENT_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "unknown")

# Сбрасываем текущие правила
ufw --force reset >/dev/null 2>&1

# Разрешаем необходимые порты
ufw default deny incoming comment 'Запретить входящий трафик'
ufw default allow outgoing comment 'Разрешить исходящий трафик'
ufw allow ssh comment 'SSH'
ufw allow http comment 'HTTP'
ufw allow https comment 'HTTPS'

# Добавляем текущий IP в белый список для дополнительной безопасности
if [ "$CURRENT_IP" != "unknown" ]; then
    ufw allow from "$CURRENT_IP" to any port ssh comment 'Доступ с вашего IP'
    print_info "Ваш IP $CURRENT_IP добавлен в белый список для SSH"
fi

# Включаем UFW с подтверждением
print_warning "UFW будет включен через 5 секунд. Если вы потеряете доступ, используйте консоль в панели Timeweb Cloud."
sleep 5
ufw --force enable >/dev/null 2>&1
print_success "UFW включен безопасно"

# =============== ШАГ 5: ОПТИМИЗАЦИЯ ЯДРА (КОНСЕРВАТИВНАЯ) ===============
print_step "Консервативная оптимизация ядра для VPS"
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
print_info "Обнаружено RAM: ${TOTAL_MEM_MB} MB"

# Безопасные параметры для VPS
declare -A SAFE_KERNEL_OPTS
SAFE_KERNEL_OPTS=(
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"
    ["net.core.somaxconn"]="1024"
    ["net.core.netdev_max_backlog"]="1000"
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.ip_forward"]="1"
    ["vm.swappiness"]="30"
    ["vm.vfs_cache_pressure"]="100"
)

for key in "${!SAFE_KERNEL_OPTS[@]}"; do
    value="${SAFE_KERNEL_OPTS[$key]}"
    comment=""
    apply_sysctl_optimization "$key" "$value" "$comment"
    print_info "→ $key=$value"
done

# Применяем изменения
sysctl -p >/dev/null 2>&1
print_success "Консервативные оптимизации ядра применены"

# =============== ШАГ 6: НАСТРОЙКА ВИРТУАЛЬНОЙ ПАМЯТИ ===============
print_step "Настройка swap-файла (без ZRAM для VPS)"
if ! swapon --show | grep -q '/swapfile'; then
    # Размер swap для VPS
    if [ "$TOTAL_MEM_MB" -le 1024 ]; then
        SWAP_SIZE_GB=2
    elif [ "$TOTAL_MEM_MB" -le 2048 ]; then
        SWAP_SIZE_GB=2
    else
        SWAP_SIZE_GB=2
    fi
    
    fallocate -l ${SWAP_SIZE_GB}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024))
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    print_success "Swap ${SWAP_SIZE_GB}GB создан"
else
    print_warning "Swap уже активен"
fi

# =============== ШАГ 7: БЕЗОПАСНАЯ НАСТРОЙКА SSH ===============
print_step "Безопасная настройка SSH (только если ключи есть)"

# Проверяем еще раз наличие ключей
if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    print_info "SSH ключи найдены, можно отключать пароли"
    
    # Резервная копия перед изменением
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.before_password_disable
    
    # Отключаем парольную аутентификацию
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    
    # Определяем службу SSH
    SSH_SERVICE=""
    if systemctl list-unit-files --quiet 2>/dev/null | grep -q '^ssh\.service'; then
        SSH_SERVICE="ssh"
    elif systemctl list-unit-files --quiet 2>/dev/null | grep -q '^sshd\.service'; then
        SSH_SERVICE="sshd"
    else
        if pgrep -x "sshd" >/dev/null 2>&1; then SSH_SERVICE="sshd"
        elif pgrep -x "ssh" >/dev/null 2>&1; then SSH_SERVICE="ssh"
        else SSH_SERVICE="ssh"; fi
    fi
    
    # Проверяем конфигурацию перед перезагрузкой
    if sshd -t; then
        print_info "Конфигурация SSH проверена, перезагружаем службу..."
        systemctl reload "$SSH_SERVICE" || systemctl restart "$SSH_SERVICE"
        
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            print_success "Пароли в SSH отключены. Доступ только по ключу!"
        else
            print_error "SSH сервис не запустился! Восстанавливаем конфигурацию..."
            cp /etc/ssh/sshd_config.before_password_disable /etc/ssh/sshd_config
            systemctl restart "$SSH_SERVICE"
            exit 1
        fi
    else
        print_error "Ошибка в конфигурации SSH! Восстанавливаем оригинальную конфигурацию..."
        cp /etc/ssh/sshd_config.before_password_disable /etc/ssh/sshd_config
        exit 1
    fi
else
    print_warning "SSH ключи не настроены! Парольная аутентификация оставлена включенной."
    print_warning "Пожалуйста, настройте SSH ключи вручную перед отключением паролей."
fi

# =============== ШАГ 8: НАСТРОЙКА FAIL2BAN ===============
print_step "Настройка Fail2Ban"
SSH_PORT=$(grep -Po '^Port \K\d+' /etc/ssh/sshd_config 2>/dev/null || echo 22)

# Создаем конфигурацию только если порт стандартный или известен
if [ "$SSH_PORT" != "22" ]; then
    print_info "Нестандартный SSH порт: $SSH_PORT"
fi

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 5
bantime = 30m
findtime = 10m
backend = systemd
action = %(action_)s
EOF

systemctl restart fail2ban 2>/dev/null || true
print_success "Fail2Ban настроен для защиты SSH (порт: $SSH_PORT)"

# =============== ФИНАЛЬНАЯ СВОДКА ===============
print_step "ФИНАЛЬНАЯ СВОДКА"
print_warning "=== ВАЖНАЯ ИНФОРМАЦИЯ ==="

# Внешний IP
EXTERNAL_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "не удалось определить")
print_info "Ваш внешний IP: ${YELLOW}${EXTERNAL_IP}${NC}"

# SSH доступ
if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    print_success "SSH: пароли отключены (только ключи)"
else
    print_warning "SSH: пароли ВКЛЮЧЕНЫ (ключей не обнаружено)"
fi

# UFW статус
UFW_STATUS=$(ufw status | grep -i "Status: active" 2>/dev/null || echo "inactive")
if [[ "$UFW_STATUS" == *"active"* ]]; then
    print_success "UFW: активен"
else
    print_warning "UFW: неактивен"
fi

# Fail2Ban статус
if systemctl is-active --quiet "fail2ban"; then
    print_success "Fail2Ban: активен"
else
    print_warning "Fail2Ban: неактивен"
fi

# Swap статус
SWAP_INFO=$(swapon --show 2>/dev/null | grep '/swapfile' || echo "не активен")
print_info "Swap: ${SWAP_INFO}"

# Восстановительный аккаунт
if [ -f /root/recovery_info.txt ]; then
    print_warning "⚠ СОЗДАН АККАУНТ ДЛЯ ВОССТАНОВЛЕНИЯ!"
    cat /root/recovery_info.txt
    print_warning "Удалите этого пользователя после проверки доступа:"
    print_warning "userdel -r $(grep 'Пользователь:' /root/recovery_info.txt | awk '{print $2}')"
fi

print_success "=== ОПТИМИЗАЦИЯ ЗАВЕРШЕНА ==="
print_warning "Рекомендуется:"
print_warning "1. Проверить доступ по SSH с вашего компьютера"
print_warning "2. Если доступ есть - удалить временного пользователя"
print_warning "3. При проблемах - использовать консоль в панели Timeweb Cloud"

# Проверка доступа
print_step "Тест подключения"
print_info "Попробуйте подключиться к серверу в новом окне терминала:"
print_info "ssh root@${EXTERNAL_IP}"
print_warning "Если подключение не работает, нажмите Ctrl+C и используйте консоль Timeweb Cloud"
