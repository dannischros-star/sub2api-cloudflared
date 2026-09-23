#!/bin/sh
# ============================================================
# Sub2API + cloudflared 双进程启动脚本（路径 A）
#
# 设计（对应当前已知约束）：
#   - Northflank env-injector 是 PID 1，本脚本由其 exec；因此本脚本
#     内两个子进程做显式信号转发（不能依赖 s6-overlay /init）。
#   - cloudflared：后台运行；退出后循环自动重启（退避 5s），避免
#     整容器重启导致“应用健康但外部不可达”。
#   - sub2api：前台运行（exec 语义由原入口脚本保证）；崩溃退出则
#     本脚本退出 -> 容器按 Northflank 重启策略恢复（应用级恢复）。
#   - SIGTERM/SIGINT 透传给两个子进程，等待优雅退出。
#   - TUNNEL_TOKEN 缺失时：拒绝启动 cloudflared 并写日志（外部不可达
#     应由监控发现），应用照常运行。
# ============================================================

CF_BIN=/usr/local/bin/cloudflared
CF_LOG=/tmp/cloudflared.log
CF_METRICS=127.0.0.1:49873
RESTART_DELAY=5

run_cloudflared() {
  while :; do
    if [ -z "${TUNNEL_TOKEN}" ]; then
      echo "[start.sh] TUNNEL_TOKEN missing; cloudflared NOT started" >&2
      # 继续循环等待（token 注入后无需整容器重启即可生效）
      sleep 30
      continue
    fi
    echo "[start.sh] starting cloudflared (pid=$$ child)" >>"$CF_LOG"
    "$CF_BIN" tunnel --no-autoupdate --metrics "$CF_METRICS" \
      run --token "${TUNNEL_TOKEN}" >>"$CF_LOG" 2>&1
    rc=$?
    echo "[start.sh] cloudflared exited rc=$rc; restart in ${RESTART_DELAY}s" >>"$CF_LOG"
    sleep "$RESTART_DELAY"
  done
}

stop_children() {
  local sig=$1
  # 向前台应用与后台 cloudflared 循环都发送信号
  if [ -n "${APP_PID:-}" ]; then kill -s "$sig" "$APP_PID" 2>/dev/null; fi
  if [ -n "${CF_WRAP_PID:-}" ]; then kill -s "$sig" "$CF_WRAP_PID" 2>/dev/null; fi
}

# 信号处理：把 TERM/INT 转发给子进程
trap 'stop_children TERM' TERM
trap 'stop_children INT' INT

# 启动 cloudflared 后台循环
run_cloudflared &
CF_WRAP_PID=$!

# 前台运行应用（原入口脚本会 fix 权限并降权到 sub2api，最终 exec 应用）
/app/docker-entrypoint.sh /app/sub2api &
APP_PID=$!

# 等待应用退出：应用崩溃 -> 本脚本退出 -> 容器重启
wait "$APP_PID"
app_rc=$?

# 清理：发 TERM 给 cloudflared 循环与残余子进程，等待其退出
if [ -n "$CF_WRAP_PID" ]; then
  kill -TERM "$CF_WRAP_PID" 2>/dev/null
  wait "$CF_WRAP_PID" 2>/dev/null
fi

exit "$app_rc"