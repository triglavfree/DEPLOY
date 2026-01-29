# Среда разработчика для Debian/Ubuntu
---

# 📁 Структура
```txt
scripts/code-server/
├── bootstrap.sh                  # Единый скрипт развёртывания
├── setup.yml                     # Ansible playbook
└── templates/
    └── code-server.service.j2    # Systemd-юнит
```

# 🚀 Установка
```bash
curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/code-server/bootstrap.sh | sudo -E bash
```

# 🪬 Результат
- Идемпотентность — можно запускать сколько угодно раз
- Настоящий VSCodium в браузере (без телеметрии Microsoft)
- Forgejo с SQLite
- TorrServer для стриминга торрентов
- Полная безопасность и оптимизация
