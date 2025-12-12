[![WireGuard](https://img.shields.io/badge/WireGuard-FFFFFF?logo=wireguard&logoColor=88171a&style=for-the-badge)](https://github.com/WireGuard)
[![Caddy](https://img.shields.io/badge/Caddy-FFFFFF?logo=caddy&logoColor=1abc9c&style=for-the-badge)](https://github.com/caddyserver/caddy)
[![WireGuard Easy](https://img.shields.io/badge/WireGuard_Easy-FFFFFF?logo=github&logoColor=181717&style=for-the-badge)](https://github.com/wg-easy/wg-easy)

# WireGuard + Caddy + WireGuard Easy panel


### Как использовать скрипт:
- Для домена `vpn.duckdns.com`: [Duck DNS](https://www.duckdns.org/)
```bash
curl -s https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/wireguard/wg-easy.sh | sudo bash -s vpn.duckdns.com
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

---
Этот скрипт представляет собой production-ready решение для развертывания wg-easy на минимальном VPS с максимальной безопасностью и производительностью.
