#!/system/bin/sh
# post-fs-data.sh - /data 挂载完成后的早期初始化入口
# 由 Magisk / KernelSU / APatch 在 fs 挂载完成后调用。
# 此阶段网络尚未就绪，只做轻量准备：目录与配置兜底。
#
# 关于 sepolicy.rule：
#   Magisk 在 pre-init 阶段自行读取模块目录下的 sepolicy.rule；
#   KernelSU / APatch 同样自动处理该文件。
#   旧版本在这里调用 `ksud sepolicy load <file>`，但 ksud 并没有这个子命令，
#   每次开机都会失败并往日志写一条「失败（可忽略）」，属于纯噪声且会误导排查。
#   因此本脚本不再尝试手工加载策略。
MODDIR=${0%/*}
RTDIR=/data/adb/agh
PSLOG="$RTDIR/logs/post-fs-data.log"

mkdir -p "$RTDIR/logs" "$RTDIR/run" 2>/dev/null || true
chmod 755 "$RTDIR" 2>/dev/null || true

# 配置兜底：首次安装（customize.sh 未跑或复制失败）时从模块模板初始化
if [ ! -f "$RTDIR/AdGuardHome.yaml" ]; then
    cp "$MODDIR/bin/AdGuardHome.yaml" "$RTDIR/AdGuardHome.yaml" 2>/dev/null || true
fi

# 清理看门狗残留锁：异常关机时 trap 不会执行，锁文件会留下来，
# 而下次启动时 pid 早已不存在，若不清理会白等一轮判断。
LOCK="$RTDIR/run/watchdog.lock"
if [ -f "$LOCK" ]; then
    OLD_PID=$(cat "$LOCK" 2>/dev/null || echo "")
    if [ -z "$OLD_PID" ] || ! kill -0 "$OLD_PID" 2>/dev/null; then
        rm -f "$LOCK" 2>/dev/null || true
    fi
fi

echo "[AGHFREE] post-fs-data.sh 完成 $(date '+%F %T')" >> "$PSLOG" 2>/dev/null
