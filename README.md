# GrafanaProxy — 菜单栏 SSH SOCKS5 隧道 + PAC 分流

一个自包含的 macOS 菜单栏小应用：内置 PAC 服务器 + SSH SOCKS5 隧道 + 系统 PAC 自动设置。
用于让浏览器访问「IP 白名单」限制的站点（流量经指定远程服务器出口），不影响其它代理软件
（如 TUN 模式的 fastup）和其余流量。

## 构建

```bash
cd ~/grafana-proxy
swiftc -O -o GrafanaProxy main.swift
cp GrafanaProxy /Applications/GrafanaProxy.app/Contents/MacOS/GrafanaProxy
codesign --force --deep --sign - /Applications/GrafanaProxy.app
```

## 配置文件

菜单栏 **「设置…」**（快捷键 ⌘,）提供图形化设置界面：改完点「保存并应用」立即生效，
底层会写入 `~/Library/Application Support/GrafanaProxy/config.json`（首次启动自动生成默认模板）。
也可以直接编辑该文件后点菜单栏「重新加载配置」。

### ssh — SSH 隧道

| 字段 | 默认值 | 说明 |
|---|---|---|
| `hostAlias` | `joe-aliyun-hk-dev` | `~/.ssh/config` 中的主机别名（隧道出口服务器） |
| `keyComment` | `joe_dev` | 1Password SSH agent 中要使用的公钥注释。私钥始终在 1Password 里，每次连接仍会弹出授权框；App 只请求这一把钥匙，避免多密钥触发服务器 MaxAuthTries |
| `tunnelPortStart` / `tunnelPortEnd` | `1080` / `1085` | 本地 SOCKS5 隧道端口范围（被占用自动顺延） |
| `serverAliveInterval` | `60` | 秒，保活探测间隔 |
| `connectTimeout` | `15` | 秒，SSH 连接超时 |
| `retryIntervalSeconds` | `10` | 秒，掉线后重试间隔 |
| `verbose` | `true` | ssh `-v` 调试日志写入 `~/Library/Logs/grafana-proxy-ssh.log` |

### pac — 内置 PAC 服务器

| 字段 | 默认值 | 说明 |
|---|---|---|
| `portStart` / `portEnd` | `9555` / `9560` | PAC 服务器监听端口范围，URL 形如 `http://127.0.0.1:9555/proxy.pac` |

### 其它

| 字段 | 默认值 | 说明 |
|---|---|---|
| `proxyDomains` | `["bsquared.network"]` | 走隧道的域名列表（后缀匹配，含所有子域）；其余流量一律 DIRECT。新增白名单站点直接加条目 |
| `grafanaCheckURL` | `https://grafana.bsquared.network/` | 菜单栏「目标站点」状态检测地址 |
| `autoStartServices` | `true` | 启动 App 时是否自动启动隧道 + PAC 服务 |
| `autoApplySystemPAC` | `true` | 启动/重启服务时是否自动把系统 PAC 挂到当前活动网络 |
| `menuBarTitle` | `🛰️` | 菜单栏图标（服务正常时显示） |

## 日志

- `~/Library/Logs/grafana-proxy-app.log` — App 运行日志
- `~/Library/Logs/grafana-proxy-ssh.log` — ssh 调试日志（`ssh.verbose=true` 时）

## 其它

- 退出 App 会关闭隧道、停掉 PAC 服务，并撤销本 App 设置的系统 PAC（不碰其它设置）。
- 隧道每次（重）连接时 1Password 会弹一次授权框，批准即连。
- 开机自启由 LaunchAgent `~/Library/LaunchAgents/com.joe.grafanaproxy-autostart.plist` 提供。
