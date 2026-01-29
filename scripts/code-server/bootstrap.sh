#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Self-Hosted Dev Platform — Ubuntu 24.04 Server             ║"
echo "║  Forgejo + code-server + TorrServer (LAN only)              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# Проверка прав
if [ "$EUID" -ne 0 ]; then
  echo "❌ Запускайте скрипт с sudo: sudo -E bash bootstrap.sh"
  exit 1
fi

# Проверка ОС
if ! grep -q "Ubuntu 24.04" /etc/os-release 2>/dev/null; then
  echo "⚠️  Внимание: скрипт тестировался на Ubuntu 24.04 LTS"
  echo "    Продолжить? (y/n)"
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# 1. Обновление системы
echo "🔄 Обновление системы..."
apt update -qq && apt upgrade -qq -y

# 2. Оптимизация производительности
echo "⚡ Настройка производительности..."

cat > /etc/sysctl.d/99-tuned.conf <<EOF
# TCP BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# SSD optimization
vm.swappiness=10
vm.vfs_cache_pressure=50

# IPv4-only
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-tuned.conf >/dev/null 2>&1

# Swap 2 ГБ
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 3. Установка пакетов
echo "📦 Установка зависимостей..."
apt install -qq -y \
  curl wget git python3-pip python3-venv \
  ufw net-tools fail2ban \
  sqlite3 ca-certificates xz-utils

# 4. pipx + uv
echo "🐍 Установка pipx и uv..."

# Определяем исходного пользователя
if [ -n "$S sudo_user" ]; then
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER="$(logname 2>/dev/null || whoami)"
fi

# Устанавливаем pipx через системный пакетный менеджер
apt install -qq -y pipx

# Устанавливаем uv через pipx от имени пользователя
sudo -u "$TARGET_USER" pipx install --quiet uv

# Добавляем в PATH
export PATH="/home/$TARGET_USER/.local/bin:$PATH"

# 5. Ansible через uv
echo "⚙️  Установка Ansible..."
if [ ! -d /opt/ansible ]; then
  uv venv /opt/ansible --python 3.12
fi
/opt/ansible/bin/uv pip install --quiet "ansible-core>=2.16"

# 6. Скачивание плейбука
echo "📥 Скачивание конфигурации..."
DEPLOY_DIR="/opt/deploy-code-server"
mkdir -p "$DEPLOY_DIR/templates"

curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/code-server/setup.yml \
  -o "$DEPLOY_DIR/setup.yml"

curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/code-server/templates/code-server.service.j2 \
  -o "$DEPLOY_DIR/templates/code-server.service.j2"

# 7. Запуск Ansible
echo "🚀 Запуск развёртывания через Ansible..."
/opt/ansible/bin/ansible-playbook \
  --connection=local \
  --inventory 127.0.0.1, \
  "$DEPLOY_DIR/setup.yml"

# 8. Определение IP-адреса
LOCAL_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP="IP_НЕ_ОПРЕДЕЛЁН"
fi

# 9. Финальная инструкция с IP
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ УСТАНОВКА ЗАВЕРШЕНА                                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Сервисы доступны из локальной сети (192.168.0.0/16):"
echo ""
echo "  🖥️  code-server (VSCodium в браузере):"
echo "     http://$LOCAL_IP:8080"
echo "     Пароль: $(grep password /home/dev/.config/code-server/config.yaml | cut -d' ' -f3)"
echo ""
echo "  💾 Forgejo (Git-сервер):"
echo "     http://$LOCAL_IP:3000"
echo "     → Пройдите установку при первом запуске"
echo ""
echo "  📡 TorrServer (торрент-стриминг):"
echo "     http://$LOCAL_IP:8081"
echo ""
echo "🔒 Безопасность:"
echo "  • SSH: только по ключу (пароли отключены)"
echo "  • Доступ к сервисам: только из локальной сети"
echo "  • Fail2ban: активен"
echo ""
echo "💡 Совет: откройте http://$LOCAL_IP:8080 на любом устройстве в вашей сети!"
echo ""
