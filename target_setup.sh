#!/bin/bash
set -e

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo "错误: 请使用 root 权限运行此脚本 (sudo bash $0)"
    exit 1
fi

echo "========================================="
echo "开始执行 target_setup 初始化与系统优化..."
echo "========================================="

# ==========================================
# 阶段一：基础软件与安全初始化
# ==========================================
echo "--> 正在更新软件源并安装 curl, fail2ban..."
apt update
apt install -y curl fail2ban

# 修改 SSH 端口为 53152
if grep -q "^#\?Port " /etc/ssh/sshd_config; then
    sed -i 's/^#\?Port .*/Port 53152/' /etc/ssh/sshd_config
else
    echo "Port 53152" | tee -a /etc/ssh/sshd_config
fi

# 重启 SSH 服务使配置生效
systemctl restart ssh

# 配置并启动 Fail2Ban
systemctl enable fail2ban
systemctl start fail2ban
systemctl status fail2ban --no-pager

# ==========================================
# 阶段二：获取系统硬件配置
# ==========================================
echo -e "\n--> 正在检测系统硬件配置与资源限制..."

CPU_CORES=$(nproc)
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))
MEM_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_MB/1024}")

echo "检测到系统配置: ${CPU_CORES} 核心 CPU, 内存约为 ${MEM_GB} GB (${MEM_MB} MB)"

# ==========================================
# 阶段三：设置系统连接与进程限制 (确保服务零报错)
# ==========================================
# 软限制设为 65536 保证老旧程序兼容性，硬限制固定 1048576 确保任何高并发服务不会因权限不足启动失败
SOFT_NOFILE=65536
HARD_NOFILE=1048576
LIMIT_NPROC=65535

echo "正在配置 systemd 资源限制..."

SYSTEMD_CONF="[Manager]
DefaultLimitNOFILE=${SOFT_NOFILE}:${HARD_NOFILE}
DefaultLimitNPROC=${LIMIT_NPROC}:infinity
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=infinity"

mkdir -p /etc/systemd/system.conf.d
mkdir -p /etc/systemd/user.conf.d

echo "$SYSTEMD_CONF" > /etc/systemd/system.conf.d/99-custom-limits.conf
echo "$SYSTEMD_CONF" > /etc/systemd/user.conf.d/99-custom-limits.conf

# 补充 PAM limits (修复通配符 * 与变量换行错误)
mkdir -p /etc/security/limits.d

cat <<EOF > /etc/security/limits.d/99-conns.conf
* soft nofile ${HARD_NOFILE}
* hard nofile ${HARD_NOFILE}
* soft nproc ${LIMIT_NPROC}
* hard nproc infinity
root soft nofile ${HARD_NOFILE}
root hard nofile ${HARD_NOFILE}
root soft nproc ${LIMIT_NPROC}
root hard nproc infinity
EOF

# ==========================================
# 阶段四：动态计算与应用 sysctl 网络优化
# ==========================================
echo -e "\n--> 正在配置网络优化参数..."

modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

# (1) 系统级文件句柄总数与单进程上限
# 关键保证：fs.nr_open 绝不低于 1048576，防止 systemd 服务因 LimitNOFILE 过高而启动失败
FILE_MAX=$((MEM_MB * 512))
[[ $FILE_MAX -lt 1048576 ]] && FILE_MAX=1048576
NR_OPEN=1048576
[[ $FILE_MAX -gt $NR_OPEN ]] && NR_OPEN=2097152

# (2) Swap 倾向
if [ "$MEM_MB" -le 1024 ]; then
    SWAPPINESS=30
elif [ "$MEM_MB" -ge 4096 ]; then
    SWAPPINESS=1
else
    SWAPPINESS=10
fi

# (3) TCP 核心缓冲区 (最大值，单位：字节)
TCP_MEM_MAX=$((MEM_MB * 8192))
[[ $TCP_MEM_MAX -lt 8388608 ]] && TCP_MEM_MAX=8388608
[[ $TCP_MEM_MAX -gt 134217728 ]] && TCP_MEM_MAX=134217728

# (4) 队列连接并发与积压限制
SOMAXCONN=$((MEM_MB * 8))
MAX_PER_CORE=$((CPU_CORES * 16384))

[[ $SOMAXCONN -gt $MAX_PER_CORE ]] && SOMAXCONN=$MAX_PER_CORE
[[ $SOMAXCONN -lt 4096 ]] && SOMAXCONN=4096
[[ $SOMAXCONN -gt 65535 ]] && SOMAXCONN=65535

BACKLOG=$((SOMAXCONN / 2))

# (5) 路由与连接跟踪 (Conntrack)
CONNTRACK_MAX=$((MEM_MB * 256))
[[ $CONNTRACK_MAX -lt 131072 ]] && CONNTRACK_MAX=131072

mkdir -p /etc/sysctl.d
CONF_FILE="/etc/sysctl.d/99-dynamic-network.conf"

cat <<EOF > "$CONF_FILE"
########################################
# ${CPU_CORES}C${MEM_GB}G 自动适配网络优化配置
########################################

# 1. 基础文件句柄
fs.file-max = $FILE_MAX
fs.nr_open = $NR_OPEN
vm.swappiness = $SWAPPINESS

# 2. 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 3. 核心缓冲区
net.core.rmem_max = $TCP_MEM_MAX
net.core.wmem_max = $TCP_MEM_MAX
net.ipv4.tcp_rmem = 4096 87380 $TCP_MEM_MAX
net.ipv4.tcp_wmem = 4096 65536 $TCP_MEM_MAX
net.ipv4.udp_rmem_min = 4096
net.ipv4.udp_wmem_min = 4096
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2

# 4. 队列与端口
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SOMAXCONN
net.ipv4.ip_local_port_range = 1024 65535

# 5. TCP 高级特性
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_sack = 1

# 6. TCP 状态回收与保活
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# 7. Conntrack 连接跟踪
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60

# 8. 激进优化项
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_autocorking = 1
net.ipv4.route.flush = 1
net.ipv6.auto_flowlabels = 1
net.ipv4.tcp_synack_retries = 3

# 9. 内存与脏页回收
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
EOF

echo "应用 sysctl 配置..."
# 先应用 sysctl 提高内核 fs.nr_open 上限，再重载 systemd，顺序不可颠倒
sysctl -e -p "$CONF_FILE"

echo "重载 systemd 守护进程..."
systemctl daemon-reload
systemctl daemon-reexec

echo -e "\n========================================="
echo "初始化及优化已全部完成！"
echo "软/硬限制已设置为 ${SOFT_NOFILE}/${HARD_NOFILE}，网络已适配 ${CPU_CORES}C${MEM_GB}G。"
echo "========================================="