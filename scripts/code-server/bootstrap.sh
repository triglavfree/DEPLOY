
---

## 📜 `bootstrap.sh` — первичная настройка (запустите вручную один раз)

```bash
#!/bin/bash
set -e

echo "🔧 Первичная настройка Ubuntu 24.04..."

# 1. Обновление системы
sudo apt update && sudo apt upgrade -y

# 2. Установка Python и Ansible через pipx + uv
sudo apt install -y python3-pip git curl
python3 -m pip install --user pipx
python3 -m pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
pipx install uv

# 3. Создание swap (2 ГБ)
if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# 4. Включение BBR (TCP BBR congestion control)
echo 'net.core.default_qdisc=fq' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 5. Оптимизация SSD
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
echo 'vm.vfs_cache_pressure=50' | sudo tee -a /etc/sysctl.conf
sudo systemctl restart systemd-sysctl

# 6. Отключение IPv6 (ускорение DNS и сетевых операций)
echo 'net.ipv6.conf.all.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.default.disable_ipv6 = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 7. Клонирование playbook'а
git clone https://github.com/you/ubuntu-bootstrap.git ~/ubuntu-bootstrap

echo "✅ Готово! Теперь запустите:"
echo "cd ~/ubuntu-bootstrap && ansible-playbook playbook.yml"