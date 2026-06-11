#!/bin/bash
# install-urhox-runtime.sh
# =============================================================================
# 安装 / 自动更新 UrhoXRuntime (Linux, tool_mode-ready) 到 /workspace/.cli/。
#
# 由 ai-dev-kit 的 run-lua-headless skill 调用；agent 不直接写 curl/wget。
# 把 CDN URL 等部署细节封装在本脚本里，换 CDN 源时只动这一个文件 + 重跑
# sandbox 供应即可，skill 文档保持稳定。
#
# 设计要点：
#   - 幂等：可任意次重复调用。
#   - 自动更新：If-Modified-Since 检查，远端未更新 304 不下载、~50ms/file。
#   - Atomic：每个文件先下到 .tmp，校验非空后 mv 替换；中途失败或断网不会
#     污染已有好文件，也不会留半成品被下次调用误认为已就绪。
#   - 重入安全：失败后**直接再跑一次即可**，无需手动清理（残留 .tmp 会被
#     下次覆盖，已就绪文件不动）。
#   - 共享目录隔离：只读写本脚本管理的 5 个路径，**绝不**触碰
#     /workspace/.cli/ 下别的 CLI（UrhoXCLI 等）。
# =============================================================================

set -e

# CDN 源（换源时只改这一行）
BASE=https://urhox-demo-platform.spark.xd.com/runtime/linux/latest

DEST=/workspace/.cli

# 本脚本管理的文件清单（其他 .cli/ 下的文件不归本脚本管）
FILES=(
    UrhoXRuntime
    Autoload/Data.pak
    Autoload/CoreData.pak
    Autoload/Res.pak
)

mkdir -p "$DEST/Autoload"

for f in "${FILES[@]}"; do
    dst="$DEST/$f"
    tmp="$dst.download.tmp"

    # 清掉上次可能残留的 .tmp（不影响 $dst）
    rm -f "$tmp"

    if [ -f "$dst" ]; then
        # 已有本地副本：发 If-Modified-Since，远端未更新 → 304 → curl 不写
        # tmp，结束后 tmp 不存在（或 0 字节），$dst 完全不动。
        # 远端有新版 → 2xx（通常 200，CDN 也可能 206 等）→ 下到 tmp。
        http_code=$(curl -sSf -z "$dst" -o "$tmp" -w '%{http_code}' "$BASE/$f")
        # 注意：curl -f 只对 ≥400 退出非零，所以 2xx/3xx 都走到这里。
        # 用 2xx 范围判断而不是 == "200"，避免 CDN 返回 206 时静默丢内容。
        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] && [ -s "$tmp" ]; then
            mv "$tmp" "$dst"
        elif [ "$http_code" = "304" ]; then
            rm -f "$tmp"   # 远端未更新：保持 $dst 原样
        else
            # 非 2xx/304（可能 3xx 重定向、1xx informational 等异常情况）：
            # 报警告 + 清掉 .tmp 不污染、保持 $dst 不变。
            echo "warning: unexpected HTTP $http_code for $f, keeping local copy" >&2
            rm -f "$tmp"
        fi
    else
        # 首次：直接下到 tmp，成功后 mv
        curl -sSf -o "$tmp" "$BASE/$f"
        [ -s "$tmp" ] || { rm -f "$tmp"; echo "Empty download: $f" >&2; exit 1; }
        mv "$tmp" "$dst"
    fi
done

chmod +x "$DEST/UrhoXRuntime"
