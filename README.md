# zcode-watchdog

> 一个常驻 macOS 的轻量看门狗：监控 ZCode 是否在后台打包本机工作区并上传到外部服务器。
> A lightweight resident watchdog for macOS that detects whether ZCode silently packages your workspace and uploads it to external servers.

---

## 背景 / Background

2026 年 9 月，有开发者[发文披露](https://blog.ferstar.org/posts/zcode-silent-workspace-snapshot-upload/)（[V2EX 讨论](https://www.v2ex.com/t/1242957)）：ZCode 在登录后疑似于后台打包整个工作区——包含完整 `.git` 历史、Git LFS 缓存与配置——加密后直传阿里云 OSS，且解密私钥仅由服务端持有，用户本地无法自查内容。

**声明**：上述内容属于第三方指控，本仓库不证明该行为存在或不存在。本项目提供的是**检测与取证能力**：一旦发生"打包 + 外传"特征的行为，你能在第一时间拿到本地证据。

实测中还发现两个相关事实（本工具一并盯防）：

- ZCode 的 **force-update 通道会在关闭"自动下载更新"的情况下仍然后台下载并提示安装新版本**；
- 一次强制更新（3.11.2 → 3.12.3）后，用户此前显式关闭的 **`repoSnapshotIndexingEnabled`（仓库快照索引）开关被静默翻回 `true`**。

## 检测原理（五路信号）

纯 zsh + macOS 自带命令（`nettop` / `lsof` / `dig` / `find` / `plutil` / `osascript`），零第三方依赖，无需 root。

| # | 信号 | 机制 | 告警级别 |
|---|------|------|---------|
| 1 | 出站流量突增 | `nettop` 按进程差分采样，ZCode 进程组出站 > 25 MB/min | ALERT |
| 2 | 端点白名单 | `lsof` 抓 ESTABLISHED 连接，目标不在 z.ai / bigmodel.cn 白名单 → WARN；反查命中 `*.aliyuncs.com`（阿里云 OSS） | ALERT |
| 3 | 暂存大文件 | `~/.zcode` / `Application Support/zcode` / `$TMPDIR` 下 3 分钟内新建的 > 5MB 文件 | ALERT |
| 4 | 隐私开关值守 | 每轮校验 `setting.json`：仓库快照索引 / 即时 grep 索引 / 模型 IO 留存应为 `false` | ALERT |
| 5 | 强制更新侦测 | App 版本漂移 → ALERT；更新缓存目录出现新大包 → WARN | ALERT / WARN |

告警经 macOS **通知中心**弹窗（15 分钟同类去重），并落盘到 `~/Library/Logs/zcode-watchdog.log`。

## 安装

```bash
git clone https://github.com/nanami-0713/zcode-watchdog.git
cd zcode-watchdog
zsh install.sh
```

`install.sh` 会：复制脚本到 `~/bin/` → 由模板生成 plist 到 `~/Library/LaunchAgents/` → `launchctl bootstrap` 常驻 → 立即执行一次巡检并打印状态报告。

卸载：

```bash
zsh uninstall.sh
```

## 日常使用

```bash
zsh ~/bin/zcode-watchdog.sh --report   # 查看全景：进程 / 开关状态 / 版本 / 最近告警
zsh ~/bin/zcode-watchdog.sh --learn    # 把当前已连接的未知端点并入白名单（人工确认无害后）
tail -f ~/Library/Logs/zcode-watchdog.log
```

### 端到端自测（造一个 6MB 假暂存文件，应立刻收到 ALERT 弹窗）

```bash
dd if=/dev/zero of=~/.zcode/watchdog-test.bin bs=1m count=6 2>/dev/null
zsh ~/bin/zcode-watchdog.sh --once
rm ~/.zcode/watchdog-test.bin
```

## 告警文案一览

| 场景 | 文案 |
|------|------|
| 整库上传 | `ALERT [traffic-out] ZCode 出站流量异常：约 N MB/min，疑似正在打包上传工作区` |
| 连接阿里云 OSS | `ALERT [endpoint-*] ZCode 已连接阿里云 OSS/硬告警端点 …（*.aliyuncs.com）` |
| 本地打包暂存 | `ALERT [staging] 检测到 ZCode 数据目录 3 分钟内新建的大文件（疑似打包暂存）: …` |
| 开关被翻回 | `ALERT [setting-repoSnapshotIndexingEnabled] 隐私开关 … 已被翻回 true！` |
| 版本被强升 | `ALERT [app-updated] ZCode 版本变化：X → Y。请立即复查隐私开关` |

## 配置

阈值都在 `zcode-watchdog.sh` 顶部的"可调参数"区：

| 变量 | 默认 | 含义 |
|------|------|------|
| `ALERT_OUT_PER_MIN` | 25 MB/min | 出站 ALERT 阈值 |
| `WARN_OUT_PER_MIN` | 8 MB/min | 出站 WARN 阈值 |
| `ALERT_IN_PER_MIN` | 150 MB/min | 入站 WARN 阈值（更新包下载） |
| `STAGING_MIN_BYTES` | 5 MB | 暂存文件大小阈值 |
| `DEDUP_SEC` | 900 | 同类告警去重窗口 |
| `ALLOWED_DOMAINS` | z.ai / bigmodel.cn 系 | 端点白名单域名 |
| `HARD_ALERT_PATTERN` | `aliyuncs.com…` | 硬告警反查模式 |

## 已知局限

- **无法做内容级校验**：上传是加密的、密钥在服务端，本工具走"体积 + 端点 + 暂存文件"三角定位，在传输完成前发现异常，但不解析载荷。
- **CDN 共享 IP 是白名单的固有妥协**：白名单域名解析出的 CDN IP 会被并入缓存；`aliyuncs.com` 等硬告警域名独立兜底。
- nettop 只统计有活跃连接的进程；空闲 helper 不计入是预期行为。
- 仅支持 macOS（依赖 launchd / nettop / plutil / osascript）。

## English Summary

`zcode-watchdog` is a zero-dependency zsh + launchd watchdog for macOS. After a third-party disclosure alleged that ZCode (Z.ai's agentic coding client) silently packages the whole workspace — full `.git` history, LFS cache and config — encrypts it and uploads it to Aliyun OSS with a server-held key, this tool gives you **local detection and forensic evidence**: per-process egress-rate anomaly detection (`nettop`), an endpoint allowlist with a hard alert on `*.aliyuncs.com` (`lsof` + `dig`), staging-file detection in ZCode data dirs, a watch on privacy toggles being silently flipped back (observed in practice after a forced update), and forced-update/download detection. Alerts arrive via macOS Notification Center (deduplicated) and `~/Library/Logs/zcode-watchdog.log`. This project makes no claim about whether the alleged behavior exists; it exists so that if it happens, you know immediately.

## License

[MIT](LICENSE) © 2026 nanami-0713
