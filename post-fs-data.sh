#!/system/bin/sh
# post-fs-data.sh - /data 挂载完成后的早期初始化入口
# 由 Magisk / KernelSU / APatch 在 fs 挂载完成后调用。
# 此阶段网络尚未就绪，仅做轻量准备：目录、配置兜底、SELinux 放行。
MODDIR=${0%/*}

# 创建运行时数据目录
mkdir -p /data/adb/agh/logs /data/adb/agh/run 2>/dev/null || true
chmod 755 /data/adb/agh 2>/dev/null || true

# 若配置缺失（极少发生），回退到模块内置模板
if [ ! -f /data/adb/agh/AdGuardHome.yaml ]; then
    cp "$MODDIR/bin/AdGuardHome.yaml" /data/adb/agh/AdGuardHome.yaml 2>/dev/null || true
fi

# 尝试应用 sepolicy.rule（KernelSU/APatch 原生支持；Magisk 走 magiskpolicy）
# 失败不阻断，仅记录日志。
if command -v ksud >/dev/null 2>&1; then
    ksud sepolicy load "$MODDIR/sepolicy.rule" 2>/dev/null || \
        echo "[AGHFREE] ksud sepolicy load 失败（可忽略）" >> /data/adb/agh/logs/post-fs-data.log 2>/dev/null
fi

echo "[AGHFREE] post-fs-data.sh 完成"