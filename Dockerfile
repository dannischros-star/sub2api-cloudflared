# syntax=docker/dockerfile:1.7
# ============================================================
# Sub2API + cloudflared 固定镜像（路径 A）
#   - 基础镜像固定 sub2api:0.2.7（保留应用原启动逻辑）
#   - cloudflared 固定版本打包进镜像，启动不再临时下载
#   - s6-overlay v3 做双进程管理（应用 + 隧道），各自独立启停/崩溃自动重启
#   - Tunnel Token 仍由运行时 Secret（TUNNEL_TOKEN）注入
# ============================================================
ARG BASE_IMAGE=weishaw/sub2api:0.2.7
FROM ${BASE_IMAGE}

ARG CLOUDFLARED_VERSION=2026.9.1
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG TARGETARCH=amd64

# 架构文件名映射：cloudflared 用 amd64/arm64；s6-overlay tarball 用 x86_64/aarch64
# （buildx 多平台构建时 TARGETARCH 为 amd64/arm64，无默认值分支照常工作）
USER root

# ---------- 1. cloudflared（固定版本，与基础镜像同架构） ----------
RUN apk add --no-cache wget ca-certificates \
 && wget -q -O /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${TARGETARCH}" \
 && chmod +x /usr/local/bin/cloudflared

# ---------- 2. s6-overlay v3（进程管理器：信号转发 / 崩溃重启 / 环境注入） ----------
RUN S6_ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo aarch64 || echo x86_64) && \
    wget -q -O /tmp/s6-noarch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
 && wget -q -O /tmp/s6-arch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
 && tar -C / -Jxpf /tmp/s6-noarch.tar.xz \
 && tar -C / -Jxpf /tmp/s6-arch.tar.xz \
 && rm -f /tmp/s6-noarch.tar.xz /tmp/s6-arch.tar.xz

# ---------- 3. s6 服务定义（应用 + 隧道） ----------
COPY rootfs/ /

# 运行脚本需要可执行权限
RUN chmod +x \
      /etc/s6-overlay/s6-rc.d/sub2api/run \
      /etc/s6-overlay/s6-rc.d/cloudflared/run 2>/dev/null || true

# /init 成为 PID 1，负责信号转发与子进程重启（原 ENTRYPOINT 由 sub2api 服务调用）
ENTRYPOINT ["/init"]

# 保留原 HEALTHCHECK（容器内自检，供参考；Northflank 侧另有健康检查配置）
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD wget -q -T 5 -O /dev/null http://localhost:${SERVER_PORT:-8080}/health || exit 1