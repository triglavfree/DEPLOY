[![wg-easy](https://img.shields.io/github/v/release/wg-easy/wg-easy?logo=wireguard&logoColor=e74c3c&label=wg-easy&labelColor=white&color=f8f9fa&style=for-the-badge)](https://github.com/wg-easy/wg-easy)
[![Qwen Code](https://img.shields.io/github/v/release/QwenLM/qwen-code?logo=github-copilot&logoColor=007ACC&label=Qwen_Code&labelColor=white&color=f8f9fa&style=for-the-badge)](https://github.com/QwenLM/qwen-code)
[![Blitz Panel](https://img.shields.io/github/v/release/ReturnFI/Blitz?label=%E2%9A%A1%20Blitz%20Panel&labelColor=white&color=f8f9fa&style=for-the-badge)](https://github.com/ReturnFI/Blitz)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04_LTS-f8f9fa?logo=ubuntu&logoColor=E95420&labelColor=white&style=for-the-badge)](https://releases.ubuntu.com/24.04/)
[![n8n](https://img.shields.io/github/v/release/n8n-io/n8n?logo=n8n&logoColor=000000&label=n8n&labelColor=white&color=f8f9fa&style=for-the-badge)](https://github.com/n8n-io/n8n)
[![3x-ui](https://img.shields.io/github/v/release/MHSanaei/3x-ui?logo=xray&logoColor=000000&label=3x-ui&labelColor=white&color=f8f9fa&style=for-the-badge)](https://github.com/MHSanaei/3x-ui)


Субдомены [DUCK DNS](https://duckdns.org)  [FreeDNS](https://freedns.afraid.org/) [NO-IP](https://www.noip.com/)
### Оптимизатор VPS
```bash
curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/vps/run.sh | sudo -E bash
```
---
### QWEN-CODE

Убедитесь, что у вас установлена ​​версия [Node.js](https://nodejs.org/en/download) или выше
```bash
curl -qL https://www.npmjs.com/install.sh | sh
```
Установите из npm
```bash
npm install -g @qwen-code/qwen-code@latest
```
<details>
<summary> добавить MCP сервер Context7</summary>
  
Откройте файл настроек Qwen Coder. Он находится в `~/.qwen/settings.json`
```bash
nano ~/.qwen/settings.json
```
Добавьте в него конфигурацию для Context7:
```json
{
  "mcpServers": {
    "context7": {
      "httpUrl": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "YOUR_API_KEY",
        "Accept": "application/json, text/event-stream"
      }
    }
  }
}
```
В консоли QWEN-CODE выполните
```bash
 /mcp list
```

</details>

---
### n8n
Попробуйте n8n мгновенно с помощью [npx](https://docs.n8n.io/hosting/installation/npm/#try-n8n-with-npx) (требуется [Node.js](https://nodejs.org/en/download) ):
```bash
npx n8n
```
---
### WireGuard Easy + Caddy
```bash
curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/wireguard/install.sh | sudo -E bash
```
---
### Blitz Panel - Hysteria2
```bash
bash <(curl https://raw.githubusercontent.com/ReturnFI/Blitz/main/install.sh)
```
### 3X-UI
```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```
### eGamesAPI Remnawave Revers-Proxy
```bash
bash <(curl -Ls https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh)
```

---
