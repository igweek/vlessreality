
## 在 VPS 上一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/igweek/vlessreality/refs/heads/main/reality.sh)
```

带参数的写法：

```bash
# 自定义端口和伪装域名
PORT=8443 DEST=www.apple.com bash <(curl -fsSL https://raw.githubusercontent.com/igweek/vlessreality/refs/heads/main/reality.sh)

# 查看节点信息 / 卸载
bash <(curl -fsSL https://raw.githubusercontent.com/igweek/vlessreality/refs/heads/main/reality.sh) info
bash <(curl -fsSL https://raw.githubusercontent.com/igweek/vlessreality/refs/heads/main/reality.sh) uninstall
```
