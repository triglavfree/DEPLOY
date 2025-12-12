[![WireGuard](https://img.shields.io/badge/WireGuard-FFFFFF?logo=wireguard&logoColor=88171a&style=for-the-badge)](https://github.com/WireGuard)
[![Caddy](https://img.shields.io/badge/Caddy-FFFFFF?logo=caddy&logoColor=1abc9c&style=for-the-badge)](https://github.com/caddyserver/caddy)
[![WireGuard Easy](https://img.shields.io/badge/WireGuard_Easy-FFFFFF?logo=wireguard&logoColor=88171a&style=for-the-badge)](https://github.com/wg-easy/wg-easy)

# WireGuard Easy (Podman + nftables) + Caddy Setup
Скрипт для установки WireGuard Easy с Caddy в качестве reverse proxy...


### Как использовать скрипт:
- Для домена `vpn.duckdns.com`: [Duck DNS](https://www.duckdns.org/)
```bash
curl -s https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/wireguard/wg-easy.sh | sudo bash -s vpn.duckdns.com
```
- Для вставки домена из буфера обмена в процессе выполнения скрипта:
```bash
curl -s https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/wireguard/wg-easy.sh | sudo bash
```
### Ключевые преимущества гибридного подхода:

✅ Официальный метод установки wg-easy:

   - Клонирование production ветки для стабильности
   - `npm ci --omit=dev` для оптимизации зависимостей
   - Официальный `systemd` сервис с правильными настройками

✅ Максимальная безопасность:

   - Отдельный пользователь wg-easy вместо root
   - Caddy с автоматическими SSL-сертификатами (никакого `INSECURE=true`)
   - UFW + Fail2Ban для защиты от атак
   - `nftables` вместо `iptables` для лучшей производительности

✅ Оптимизации для слабого VPS (1CPU, 1GB RAM):

   - BBR для улучшения сетевой производительности
   - Swap 2GB для предотвращения OOM
   - Оптимизация NVMe/SSD для I/O операций
   - Сетевые параметры ядра для максимальной пропускной способности

✅ Современные технологии:

   - Ubuntu 24.04 LTS
   - Node.js 20.x LTS
   - Caddy 2.x с автоматическим HTTPS
   - nftables для NAT и firewall

✅ Удобство управления:

   - Цветной вывод для лучшей читаемости
   - DOMAIN из командной строки
   - Детальные инструкции по обновлению и управлению
   - Автоматическая проверка сервисов после установки

### 🔧 Что делать после установки:

   - Подождите 2-3 минуты для получения SSL сертификата
   - Откройте `https://your-domain.com` в браузере
   - Введите сгенерированный пароль из вывода скрипта
   - Перейдите в раздел "Hooks" и добавьте nftables правила:
>PostUp:
 ```
nft add table inet wg_table; nft add chain inet wg_table prerouting { type nat hook prerouting priority 100 \; }; nft add chain inet wg_table postrouting { type nat hook postrouting priority 100 \; }; nft add rule inet wg_table postrouting ip saddr 10.8.0.0/24 oifname eth0 masquerade; nft add chain inet wg_table input { type filter hook input priority 0 \; policy accept \; }; nft add rule inet wg_table input udp dport 51820 accept; nft add rule inet wg_table input tcp dport 51821 accept; nft add chain inet wg_table forward { type filter hook forward priority 0 \; policy accept \; }; nft add rule inet wg_table forward iifname "wg0" accept; nft add rule inet wg_table forward oifname "wg0" accept;
```
>PostDown:
```
nft delete table inet wg_table
```
- Создайте первого клиента в админ-панели
---
Этот скрипт полностью автоматизирует развертывание wg-easy в production-среде с максимальной производительностью и безопасностью!
