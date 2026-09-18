#!/bin/zsh
# =============================================================================
# zcode-watchdog.sh — 监控 ZCode 是否在本机打包敏感信息并上传到外部服务器
#
# 背景：博客 https://blog.ferstar.org/posts/zcode-silent-workspace-snapshot-upload/
#       称 ZCode 登录后会在后台打包工作区（含完整 .git 历史、LFS 缓存、配置），
#       加密后直传阿里云 OSS，解密私钥仅服务端持有。
#
# 五路检测信号（任一命中即告警）：
#   1. 出站流量突增   —— ZCode 进程组每分钟出站字节数超阈值（整库上传的特征）
#   2. 端点白名单     —— ZCode 建立的 TCP 连接目标不在 z.ai/bigmodel.cn 白名单内；
#                        反查命中 aliyuncs.com（阿里云 OSS）直接 ALERT
#   3. 暂存大文件     —— ~/.zcode、Application Support/zcode、$TMPDIR 下
#                        3 分钟内新建的 >5MB 文件（排除浏览器缓存/日志等已知噪声）
#   4. 开关值守       —— setting.json 中隐私开关被翻回（repoSnapshotIndexingEnabled 等）
#   5. 强制更新侦测   —— 版本号漂移 + 后台更新包下载（上次开关被翻回就发生在强制更新后）
#
# 用法：
#   zcode-watchdog.sh --once     单次巡检（launchd 每 60s 调用）
#   zcode-watchdog.sh --report   打印当前状态报告到终端
#   zcode-watchdog.sh --learn    把当前已连接的未知端点加入用户白名单（review 后用）
#
# 安装（launchd 常驻）：
#   launchctl bootstrap gui/$UID ~/Library/LaunchAgents/local.zcode-watchdog.plist
# 卸载：
#   launchctl bootout gui/$UID/local.zcode-watchdog
# =============================================================================

set -u
umask 077

# ----------------------------- 可调参数 --------------------------------------
typeset -i ALERT_OUT_PER_MIN=25000000      # 出站 >25MB/min → ALERT（疑似整库上传）
typeset -i WARN_OUT_PER_MIN=8000000        # 出站 >8MB/min  → WARN
typeset -i ALERT_IN_PER_MIN=150000000      # 入站 >150MB/min → WARN（疑似后台下载更新）
typeset -i STAGING_MIN_BYTES=5000000       # 暂存文件 >5MB 且 3 分钟内新建 → ALERT
typeset -i STAGING_WINDOW_MIN=3
typeset -i DEDUP_SEC=900                   # 同类告警 15 分钟内不重复推送
typeset -i DNS_CACHE_TTL=3600              # 白名单域名解析缓存 1 小时

# 已知正常业务域名（会解析成 IP 做白名单；CDN 共享 IP 是已知妥协点）
ALLOWED_DOMAINS=(
  z.ai www.z.ai api.z.ai zcode.z.ai cdn-zcode.z.ai
  bigmodel.cn www.bigmodel.cn open.bigmodel.cn static.bigmodel.cn
)
# 硬告警域名（反查命中即 ALERT，即使它有"业务"理由连接）
HARD_ALERT_PATTERN='aliyuncs\.com|aliyun\.com|oss-'

# ZCode 进程匹配（桌面端 + CLI + Computer Use 助手）
PROC_PATTERN='ZCode\.app|zcode\.cjs|ZCode Computer Use|ZCode Helper'

# 隐私开关：期望 false；被翻成 true 即 ALERT
SETTING_KEYS_EXPECT_FALSE=(
  repoSnapshotIndexingEnabled   # 仓库快照索引（博客对应的关键开关）
  instantGrepIndexingEnabled    # 即时 grep 索引
  modelIoFullRetentionEnabled   # 模型 IO 全量留存
)
# 仅跟踪变化的开关（true/false 都可能是用户选择，变了就 WARN）
SETTING_KEYS_WATCH_CHANGE=( nativeSearchEnhancementsEnabled )

# ----------------------------- 路径与状态 ------------------------------------
HOME_DIR="$HOME"
SETTING_JSON="$HOME_DIR/.zcode/v2/setting.json"
APP_PLIST="/Applications/ZCode.app/Contents/Info.plist"
UPDATER_CACHE="$HOME_DIR/Library/Caches/@zcodedesktop-updater"
APP_SUPPORT_ZCODE="$HOME_DIR/Library/Application Support/zcode"
STATE_DIR="$HOME_DIR/Library/Application Support/zcode-watchdog"
LOG_FILE="$HOME_DIR/Library/Logs/zcode-watchdog.log"
USER_TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo '')"

mkdir -p "$STATE_DIR" "${LOG_FILE:h}" 2>/dev/null

MODE="${1:---once}"

# ----------------------------- 工具函数 --------------------------------------
log() {  # 永远落日志
  print -r -- "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

notify() { # 通知中心弹窗（launchd 用户态代理可用）
  local title="$1" msg="$2"
  msg="${msg//\"/\'}"  # AppleScript 字符串内不能含未转义双引号
  /usr/bin/osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Basso\"" \
    >/dev/null 2>&1
}

alert() {  # alert LEVEL KEY MESSAGE —— 带去重
  local level="$1" key="$2" msg="$3"
  local now=$(date +%s)
  local alerts_db="$STATE_DIR/alerts.tsv"
  local last=0
  [[ -f "$alerts_db" ]] && last=$(awk -F '\t' -v k="$key" '$1==k{v=$2} END{print v+0}' "$alerts_db")
  if (( now - last > DEDUP_SEC )); then
    log "$level [$key] $msg"
    notify "ZCode Watchdog: $level" "$msg"
    # 更新去重表
    grep -v -F "$key	" "$alerts_db" 2>/dev/null > "$alerts_db.tmp" || true
    print -r -- "$key	$now" >> "$alerts_db.tmp"
    mv "$alerts_db.tmp" "$alerts_db"
  else
    log "($level, deduped) [$key] $msg"
  fi
}

rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local sz=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  if (( sz > 2097152 )); then
    tail -2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

# 单实例锁（目录当锁，300s 过期）
if ! mkdir "$STATE_DIR/lock" 2>/dev/null; then
  local_lock_age=$(( $(date +%s) - $(stat -f%m "$STATE_DIR/lock" 2>/dev/null || echo 0) ))
  if (( local_lock_age > 300 )); then
    rm -rf "$STATE_DIR/lock" 2>/dev/null
    mkdir "$STATE_DIR/lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rm -rf "$STATE_DIR/lock" 2>/dev/null' EXIT

# ----------------------------- 进程发现 --------------------------------------
typeset -a ZCODE_PIDS
ZCODE_PIDS=( ${(f)"$(/usr/bin/pgrep -f "$PROC_PATTERN" 2>/dev/null)"} )

# ----------------------------- 信号 1+2：流量与端点 --------------------------
check_network() {
  (( ${#ZCODE_PIDS[@]} > 0 )) || { log "INFO [net] ZCode 未运行，跳过网络检查"; return 0; }

  local pid_csv="${(j:,:)ZCODE_PIDS}"
  typeset -A pid_set
  local p; for p in "${ZCODE_PIDS[@]}"; do pid_set[$p]=1; done

  # --- 1. nettop 采样（每进程累计字节，跨采样做差） ---
  local now=$(date +%s)
  local prev_file="$STATE_DIR/netprev.tsv"
  typeset -A prev_out prev_in
  local prev_epoch=0 had_prev=0
  if [[ -f "$prev_file" ]] && (( $(/usr/bin/wc -l < "$prev_file") > 1 )); then
    had_prev=1
    prev_epoch=$(head -1 "$prev_file" | awk '{print $1}')
    while read -r pp po pi; do
      [[ "$pp" == \#* || -z "$pp" ]] && continue
      prev_out[$pp]=$po; prev_in[$pp]=$pi
    done < <(tail -n +2 "$prev_file")
  fi
  (( prev_epoch > 0 )) || prev_epoch=$now
  local elapsed=$(( now - prev_epoch )); (( elapsed < 1 )) && elapsed=1

  local sample
  sample=$(/usr/bin/nettop -x -n -P -L 1 -J bytes_in,bytes_out 2>/dev/null)
  if [[ -n "$sample" ]]; then
    typeset -A cur_out cur_in
    local line pid b_in b_out
    # 本机实测：nettop -x -J bytes_in,bytes_out 输出为 CSV——
    #   name.pid,bytes_in,bytes_out,   （首行表头 ",bytes_in,bytes_out,"）
    # 进程名可能含空格/点（"ZCode Helper (GPU).123"），pid 取名字段末点之后。
    while read -r line; do
      [[ "$line" == *,*,* ]] || continue
      local namepart="${line%%,*}"
      local rest="${line#*,}"
      b_in="${rest%%,*}"
      local rest2="${rest#*,}"
      b_out="${rest2%%,*}"
      pid="${namepart##*.}"
      [[ -n "${pid_set[$pid]:-}" ]] || continue
      [[ "$b_in" == <-> && "$b_out" == <-> ]] || continue
      cur_out[$pid]=$b_out; cur_in[$pid]=$b_in
    done <<< "$sample"

    if (( ${#cur_out} == 0 )); then
      # 解析与这台机器的 nettop 格式不符时的自救：把样本原样落日志，便于一次修准
      log "WARN [net] nettop 输出未匹配到 ZCode 进程（pgrep 可见 ${#ZCODE_PIDS[@]} 个），样本前 3 行："
      print -r -- "$sample" | head -3 | while read -r dbg; do log "  | $dbg"; done
    fi

    # 汇总本分钟增量并保存状态（0 匹配时保留旧基线，避免污染）
    local total_out_delta=0 total_in_delta=0
    if (( ${#cur_out} > 0 )); then
    {
      print -r -- "$now"
      for pid in ${(k)cur_out}; do
        print -r -- "$pid ${cur_out[$pid]} ${cur_in[$pid]:-0}"
        local po pi
        if (( ${+prev_out[$pid]} )); then
          po=${prev_out[$pid]}; pi=${prev_in[$pid]:-0}
        else
          # 首次见到该进程：只建档不计增量（避免把"启动至今"的累计值算成当分钟速率）
          po=${cur_out[$pid]}; pi=${cur_in[$pid]:-0}
        fi
        local do=$(( cur_out[$pid] - po )); (( do < 0 )) && do=0
        local di=$(( ${cur_in[$pid]:-0} - pi )); (( di < 0 )) && di=0
        (( total_out_delta += do )); (( total_in_delta += di ))
      done
      true   # 关键：(( += )) 结果为 0 时退出码为 1，会阻断后面的 && mv
    } > "$prev_file.tmp" && mv "$prev_file.tmp" "$prev_file"
    fi

    local out_per_min=$(( total_out_delta * 60 / elapsed ))
    local in_per_min=$(( total_in_delta * 60 / elapsed ))
    if (( ! had_prev )); then
      # 首轮无基线：进程计数器是"启动至今"的累计值，直接告警必然误报，只建档
      log "INFO [net] 首轮采样，建立流量基线（${#cur_out} 个进程），本轮不做阈值判断"
    else
    log "INFO [net] 出站 ${out_per_min} B/min，入站 ${in_per_min} B/min（${#cur_out} 个进程，采样窗口 ${elapsed}s）"
    if (( out_per_min > ALERT_OUT_PER_MIN )); then
      alert ALERT traffic-out "ZCode 出站流量异常：约 $(( out_per_min / 1048576 )) MB/min，疑似正在打包上传工作区"
    elif (( out_per_min > WARN_OUT_PER_MIN )); then
      alert WARN traffic-out "ZCode 出站流量偏高：约 $(( out_per_min / 1048576 )) MB/min"
    fi
    if (( in_per_min > ALERT_IN_PER_MIN )); then
      alert WARN traffic-in "ZCode 入站流量异常：约 $(( in_per_min / 1048576 )) MB/min，可能是强制更新在后台下载"
    fi
    fi
  else
    log "WARN [net] nettop 采样失败，本轮跳过流量检查"
  fi

  # --- 2. lsof 端点白名单 ---
  local conns
  conns=$(/usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED -a -p "$pid_csv" 2>/dev/null)
  [[ -n "$conns" ]] || return 0

  # 解析白名单域名（带缓存）
  local ipcache="$STATE_DIR/allow-ips.txt"
  local need_refresh=1
  if [[ -f "$ipcache" ]]; then
    local cache_age=$(( now - $(stat -f%m "$ipcache") ))
    (( cache_age < DNS_CACHE_TTL )) && need_refresh=0
  fi
  if (( need_refresh )); then
    : > "$ipcache.tmp"
    local d ip
    for d in "${ALLOWED_DOMAINS[@]}"; do
      for ip in ${(f)"$(/usr/bin/dig +short +time=1 +tries=1 A "$d" 2>/dev/null)"} \
                ${(f)"$(/usr/bin/dig +short +time=1 +tries=1 AAAA "$d" 2>/dev/null)"}; do
        [[ "$ip" =~ '^[0-9a-fA-F.:]+$' ]] && print -r -- "$ip" >> "$ipcache.tmp"
      done
    done
    sort -u "$ipcache.tmp" > "$ipcache" 2>/dev/null; rm -f "$ipcache.tmp"
  fi
  # 用户自学习白名单
  typeset -A allow
  while read -r ip; do [[ -n "$ip" ]] && allow[$ip]=1; done < "$ipcache" 2>/dev/null
  if [[ -f "$STATE_DIR/allowlist-extra.txt" ]]; then
    while read -r ip; do [[ -n "$ip" && "$ip" != \#* ]] && allow[$ip]=1; done < "$STATE_DIR/allowlist-extra.txt"
  fi

  local remote_ip port
  while read -r line; do
    # NAME 列形如 "1.2.3.4:443->5.6.7.8:443"（IPv6 可能带方括号）
    if [[ "$line" =~ '->\[?([0-9a-fA-F.:]+)\]?:([0-9]+)' ]]; then
      remote_ip="${match[1]}"; port="${match[2]}"
    else
      continue
    fi
    # 跳过内网/回环
    case "$remote_ip" in
      127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|::1|fe80::*|169.254.*) continue ;;
    esac
    [[ -n "${allow[$remote_ip]:-}" ]] && continue

    # 未知端点：反查 DNS
    local rdns
    rdns=$(/usr/bin/dig -x "$remote_ip" +short +time=1 +tries=1 2>/dev/null | tr '\n' ' ')
    if [[ "$rdns" =~ "$HARD_ALERT_PATTERN" ]]; then
      alert ALERT "endpoint-$remote_ip" "ZCode 已连接阿里云 OSS/硬告警端点 $remote_ip:$port（$rdns）——与博客所述上传链路一致"
    elif [[ -n "$rdns" ]]; then
      local ok=0 ad
      for ad in "${ALLOWED_DOMAINS[@]}"; do [[ "$rdns" == *"$ad"* ]] && { ok=1; break; }; done
      if (( ok )); then
        print -r -- "$remote_ip" >> "$ipcache"   # 白名单域名的 CDN 新 IP，并入缓存
      else
        alert WARN "endpoint-$remote_ip" "ZCode 连接未知端点 $remote_ip:$port（反查: ${rdns:-无}）。确认无害可执行: $0 --learn"
      fi
    else
      alert WARN "endpoint-$remote_ip" "ZCode 连接未知端点 $remote_ip:$port（无反查记录）。确认无害可执行: $0 --learn"
    fi
  done <<< "$conns"
}

# 排除说明：cli/db/ 是 CLI 的本地会话数据库（WAL sqlite，曾致 00:04 误报）
check_staging() {
  local -a targets
  targets=( "$HOME_DIR/.zcode" "$APP_SUPPORT_ZCODE" )
  [[ -n "$USER_TMPDIR" && -d "$USER_TMPDIR" ]] && targets+=( "$USER_TMPDIR" )
  local hits
  hits=$(/usr/bin/find "${targets[@]}" -type f -size +${STAGING_MIN_BYTES}c -mmin -${STAGING_WINDOW_MIN} 2>/dev/null \
    | grep -v -E '(logs/|cli/log/|cli/rollout/|cli/artifacts/|cli/exec/|cli/db/|Cache_Data|GPUCache|Code Cache|DawnWebGPUCache|DawnGraphiteCache|Session Storage|Local Storage|IndexedDB|@zcodedesktop-updater|/Shared Dictionary|crash/)' \
    | head -20)
  if [[ -n "$hits" ]]; then
    local f sz detail=""
    while read -r f; do
      sz=$(stat -f%z "$f" 2>/dev/null || echo '?')
      detail+=" [${f} $(( sz / 1048576 ))MB]"
    done <<< "$hits"
    alert ALERT staging "检测到 ZCode 数据目录 ${STAGING_WINDOW_MIN} 分钟内新建的大文件（疑似打包暂存）:$detail"
  fi
}

# ----------------------------- 信号 4：隐私开关值守 --------------------------
check_settings() {
  [[ -f "$SETTING_JSON" ]] || return 0
  local state_file="$STATE_DIR/settings.tsv"
  typeset -A prev
  if [[ -f "$state_file" ]]; then
    while read -r k v; do [[ -n "$k" ]] && prev[$k]=$v; done < "$state_file"
  fi
  local key val
  : > "$state_file.tmp"
  for key in "${SETTING_KEYS_EXPECT_FALSE[@]}"; do
    val=$(/usr/bin/plutil -extract "$key" raw -o - "$SETTING_JSON" 2>/dev/null || echo 'missing')
    print -r -- "$key	$val" >> "$state_file.tmp"
    if [[ "$val" == "true" ]]; then
      alert ALERT "setting-$key" "隐私开关 $key 已被翻回 true！请立即检查（该开关曾被版本更新静默翻回）"
    elif [[ "$val" == "missing" && "${prev[$key]:-missing}" != "missing" ]]; then
      alert WARN "setting-$key" "隐私开关 $key 从配置中消失（原值 ${prev[$key]}），可能是版本迁移"
    fi
  done
  for key in "${SETTING_KEYS_WATCH_CHANGE[@]}"; do
    val=$(/usr/bin/plutil -extract "$key" raw -o - "$SETTING_JSON" 2>/dev/null || echo 'missing')
    print -r -- "$key	$val" >> "$state_file.tmp"
    if [[ -n "${prev[$key]:-}" && "${prev[$key]}" != "$val" ]]; then
      alert WARN "setting-$key" "设置项 $key 发生变化：${prev[$key]} → $val"
    fi
  done
  mv "$state_file.tmp" "$state_file"
}

# ----------------------------- 信号 5：强制更新侦测 --------------------------
check_update() {
  local ver
  ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo unknown)
  local vf="$STATE_DIR/app-version.txt"
  local prev_ver=""
  [[ -f "$vf" ]] && prev_ver=$(cat "$vf")
  if [[ -n "$prev_ver" && "$prev_ver" != "$ver" ]]; then
    alert ALERT app-updated "ZCode 版本变化：$prev_ver → $ver。请立即复查隐私开关（版本更新可能重置开关状态）"
  fi
  print -r -- "$ver" > "$vf"

  if [[ -d "$UPDATER_CACHE" ]]; then
    local dl
    dl=$(/usr/bin/find "$UPDATER_CACHE" -type f -mmin -${STAGING_WINDOW_MIN} -size +20M 2>/dev/null | head -5)
    [[ -n "$dl" ]] && alert WARN updater-download "检测到 ZCode 后台下载更新包（$dl）。即使关闭了自动更新，force-update 通道仍会下载"
  fi
}

# ----------------------------- --learn / --report ----------------------------
do_learn() {
  local pid_csv="${(j:,:)ZCODE_PIDS}"
  [[ -n "$pid_csv" ]] || { print "ZCode 未运行"; exit 0; }
  /usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED -a -p "$pid_csv" 2>/dev/null \
    | grep -oE '\->\[?[0-9a-fA-F.:]+\]?:[0-9]+' | sed 's/->//; s/\[|\]//g; s/:[0-9]*$//' | sort -u \
    | while read -r ip; do
        [[ "$ip" == *:* ]] && continue   # IPv6 端口剥离不可靠，跳过
        case "$ip" in 127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|::1|fe80::*|169.254.*) continue;; esac
        print -r -- "$ip"
      done >> "$STATE_DIR/allowlist-extra.txt"
  sort -u "$STATE_DIR/allowlist-extra.txt" -o "$STATE_DIR/allowlist-extra.txt"
  print "已把当前连接端点并入 $STATE_DIR/allowlist-extra.txt"
}

do_report() {
  print -r -- "===== ZCode Watchdog 状态报告 $(date '+%F %T') ====="
  print -r -- "-- 进程: ${(j:, :)ZCODE_PIDS:-未运行}"
  if [[ -f "$SETTING_JSON" ]]; then
    local key val
    for key in "${SETTING_KEYS_EXPECT_FALSE[@]}" "${SETTING_KEYS_WATCH_CHANGE[@]}"; do
      val=$(/usr/bin/plutil -extract "$key" raw -o - "$SETTING_JSON" 2>/dev/null || echo 'missing')
      print -r -- "-- 设置 $key = $val"
    done
  fi
  print -r -- "-- 版本: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null)"
  print -r -- "-- 最近 10 条告警日志:"
  tail -10 "$LOG_FILE" 2>/dev/null || print -r -- "   (无)"
}

# ----------------------------- 主流程 ----------------------------------------
rotate_log
case "$MODE" in
  --learn)  do_learn ;;
  --report) do_report ;;
  *)
    check_network
    check_staging
    check_settings
    check_update
    ;;
esac
exit 0
