# syntax=docker/dockerfile:1.7
# ============================================================
# Sub2API + cloudflared 固定镜像（路径 A）
#   - 基础镜像固定 sub2api:0.2.7（保留应用原启动逻辑）
#   - cloudflared 固定版本打包进镜像，启动不再临时下载
#   - 启动脚本 /app/start.sh 负责双进程管理：
#       * cloudflared 后台运行，崩溃由循环自动重启（不整容器重启）
#       * sub2api 前台运行，崩溃则脚本退出 -> 容器重启（应用级恢复）
#       * SIGTERM 透传给两个子进程，优雅停机
#   - Tunnel Token 仍由运行时 Secret（TUNNEL_TOKEN）注入
#   - cloudflared 监听 127.0.0.1:49873 暴露 /ready（200=已连边缘）
#
#   NOTE: 不用 s6-overlay —— Northflank env-injector 占据 PID 1，
#   s6-overlay /init 硬性要求 PID 1（实测 s6-overlay-suexec: can only
#   run as pid 1），故采用启动脚本 + 信号转发（Docker 官方认可的
#   "verified startup script" 多进程方式）。
# ============================================================
ARG BASE_IMAGE=weishaw/sub2api:0.2.7
FROM ${BASE_IMAGE}

ARG CLOUDFLARED_VERSION=2026.9.1
ARG TARGETARCH=amd64

# ---------- cloudflared（固定版本，与基础镜像同架构） ----------
RUN apk add --no-cache wget ca-certificates \
 && wget -q -O /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${TARGETARCH}" \
 && chmod +x /usr/local/bin/cloudflared

# ---------- 双进程启动脚本 ----------
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh \
 && chown sub2api:sub2api /app/start.sh

# 覆盖默认 CMD 为启动脚本（保留原 ENTRYPOINT，由脚本 exec 应用）
# 原 ENTRYPOINT /app/docker-entrypoint.sh 会先修 /app/data 权限并以 sub2api 运行
CMD ["/app/start.sh"]