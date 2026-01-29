#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Self-Hosted Dev Platform — Ubuntu 24.04 Server             ║"
echo "║  Forgejo + code-server + TorrServer (LAN only)              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# === Проверка прав ===
if [ "$EUID" -ne 0 ]; then
  echo "❌ Запускайте с sudo: sudo -E bash bootstrap.sh"
  exit 1
fi

# === Определяем исходного пользователя ===
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo 'ubuntu')}"

# === Функция: выполнить от имени пользователя ===
run_as_user() {
  sudo -u "$TARGET_USER" HOME="/home/$TARGET_USER" "$@"
}

# === 1. Обновление системы (включая phased updates) ===
echo "🔄 Обновление системы (с phased updates)..."
apt -o APT::Get::Always-Include-Phased-Updates=true update -qq
apt -o APT::Get::Always-Include-Phased-Updates=true upgrade -qq -y

# === 2. Производительность ===
echo "⚡ Настройка производительности..."

cat > /etc/sysctl.d/99-tuned.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
vm.swappiness=10
vm.vfs_cache_pressure=50
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-tuned.conf >/dev/null 2>&1

# Swap (идемпотентно)
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# === 3. Установка пакетов (идемпотентно) ===
echo "📦 Установка зависимостей..."
apt install -qq -y \
  curl wget git python3-pip python3-venv pipx \
  ufw net-tools fail2ban \
  sqlite3 ca-certificates xz-utils

# === 4. Установка uv через pipx (от пользователя) ===
echo "🐍 Установка uv через pipx..."

# Убедимся, что PATH включает ~/.local/bin
run_as_user sh -c 'echo ''export PATH="$HOME/.local/bin:$PATH"'' >> ~/.profile 2>/dev/null || true'

# Устанавливаем uv, если ещё не установлен
if ! run_as_user command -v uv &> /dev/null; then
  run_as_user pipx install --quiet uv
else
  echo "   → uv уже установлен"
fi

# Обновляем PATH для текущей сессии
export PATH="/home/$TARGET_USER/.local/bin:$PATH"

# === 5. Ansible через uv (в изолированном venv) ===
ANSIBLE_VENV="/opt/ansible"
if [ ! -d "$ANSIBLE_VENV" ]; then
  echo "⚙️  Создание изолированного окружения для Ansible..."
  # Используем ГЛОБАЛЬНЫЙ uv (установленный через pipx)
  /home/"$TARGET_USER"/.local/bin/uv venv "$ANSIBLE_VENV" --python 3.12
fi

# Устанавливаем Ansible через ГЛОБАЛЬНЫЙ uv
if ! "$ANSIBLE_VENV/bin/ansible" --version &> /dev/null; then
  /home/"$TARGET_USER"/.local/bin/uv pip install --quiet "ansible-core>=2.16" -p "$ANSIBLE_VENV"
fi

# === 6. Скачивание конфигурации (если ещё не скачана) ===
DEPLOY_DIR="/opt/deploy-code-server"
if [ ! -f "$DEPLOY_DIR/setup.yml" ]; then
  echo "📥 Скачивание плейбука и шаблонов..."
  mkdir -p "$DEPLOY_DIR/templates"
  curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/code-server/setup.yml \
    -o "$DEPLOY_DIR/setup.yml"
  curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/code-server/templates/code-server.service.j2 \
    -o "$DEPLOY_DIR/templates/code-server.service.j2"
fi

# === 7. Запуск Ansible (идемпотентен по умолчанию) ===
echo "🚀 Запуск развёртывания через Ansible..."
"$ANSIBLE_VENV/bin/ansible-playbook" \
  --connection=local \
  --inventory 127.0.0.1, \
  "$DEPLOY_DIR/setup.yml"

# === 8. Определение IP ===
LOCAL_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
[ -z "$LOCAL_IP" ] && LOCAL_IP="IP_НЕ_ОПРЕДЕЛЁН"

# === 9. Финальная инструкция ===
PASSWORD=$(grep -m1 password /home/dev/.config/code-server/config.yaml 2>/dev/null | cut -d' ' -f3 || echo "пароль в файле")

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ УСТАНОВКА ЗАВЕРШЕНА                                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "🌐 Сервисы доступны из локальной сети (192.168.0.0/16):"
echo "  • code-server: http://$LOCAL_IP:8080 (пароль: $PASSWORD)"
echo "  • Forgejo:     http://$LOCAL_IP:3000"
echo "  • TorrServer:  http://$LOCAL_IP:8081"
echo ""
echo "🔒 Безопасность: SSH по ключу, UFW, Fail2ban — всё активно."
echo "💡 Совет: откройте http://$LOCAL_IP:8080 на любом устройстве в сети!"
