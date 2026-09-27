#!/bin/bash
set -e

# 1. 检查 root 权限[cite: 2, 3]
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
apt update #[cite: 1]
apt install -y curl fail2ban #[cite: 1]

# 修改 SSH 端口为 53152[cite: 1]
if grep -q "^#\?Port " /etc/ssh/sshd_config; then
    sed -i 's/^#\?Port .*/Port 53152/' /etc/ssh/sshd_config #[cite: 1]
else
    echo "Port 53152" | tee -a /etc/ssh/sshd_config #[cite: 1]
fi

# 重启 SSH 服务使配置生效[cite: 1]
systemctl restart ssh #[cite: 1]

# 配置并启动 Fail2Ban[cite: 1]
systemctl enable fail2ban #[cite: 1]
systemctl start fail2ban #[cite: 1]
systemctl status fail2ban --no-pager #[cite: 1]

# ==========================================
# 阶段二：获取系统硬件配置
# ==========================================
echo -e "\n--> 正在检测系统硬件配置与资源限制..."
CPU_CORES=$(nproc) #[cite: 2, 3]
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo) #[cite: 3]
MEM_MB=$((MEM_KB / 1024)) #[cite: 3]
MEM_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_MB/1024}") #[cite: 3]

echo "检测到系统配置: $CPU_CORES 核心 CPU, 内存约为 ${MEM_GB} GB (${MEM_MB} MB)" #[cite: 3]

# ==========================================
# 阶段三：动态评估与设置系统连接限制
# ==========================================
# 按 50% 内存、单连接 4KB 估算理论最大连接数[cite: 2]
CALC_CONNS=$((MEM_MB * 128)) #[cite: 2]

# 设定安全边界：下限 65,536，上限 1,048,576[cite: 2]
if [ "$CALC_CONNS" -lt 65536 ]; then
    MAX_CONNS=65536 #[cite: 2]
elif [ "$CALC_CONNS" -gt 1048576 ]; then
    MAX_CONNS=1048576 #[cite: 2]
else
    MAX_CONNS=$CALC_CONNS #[cite: 2]
fi

# 赋值文件描述符与进程数上限[cite: 2]
LIMIT_NOFILE=$MAX_CONNS #[cite: 2]
LIMIT_NPROC=$MAX_CONNS #[cite: 2]

echo "正在配置 systemd 资源限制..."
SYSTEMD_CONF="[Manager]
DefaultLimitNOFILE=${LIMIT_NOFILE}:${LIMIT_NOFILE}
DefaultLimitNPROC=${LIMIT_NPROC}:${LIMIT_NPROC}
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=infinity" #[cite: 2]

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d #[cite: 2]
echo "$SYSTEMD_CONF" > /etc/systemd/system.conf.d/99-custom-limits.conf #[cite: 2]
echo "$SYSTEMD_CONF" > /etc/systemd/user.conf.d/99-custom-limits.conf #[cite: 2]

# 补充 PAM limits[cite: 2]
mkdir -p /etc/security/limits.d #[cite: 2]
cat << EOF > /etc/security/limits.d/99-conns.conf
* soft nofile ${LIMIT_NOFILE}
* hard nofile ${LIMIT_NOFILE}
* soft nproc ${LIMIT_NPROC}
* hard nproc ${LIMIT_NPROC}
root soft nofile ${LIMIT_NOFILE}
root hard nofile ${LIMIT_NOFILE}
root soft nproc ${LIMIT_NPROC}
root hard nproc ${LIMIT_NPROC}
EOF #[cite: 2]

# 重载生效[cite: 2]
systemctl daemon-reload #[cite: 2]
systemctl daemon-reexec #[cite: 2]

# ==========================================
# 阶段四：动态计算与应用 sysctl 网络优化
# ==========================================
echo -e "\n--> 正在配置网络优化参数..."
modprobe tcp_bbr 2>/dev/null || true #[cite: 3]
modprobe nf_conntrack 2>/dev/null || true #[cite: 3]

# (1) 文件句柄数[cite: 3]
FILE_MAX=$((MEM_MB * 512)) #[cite: 3]
[[ $FILE_MAX -lt 100000 ]] && FILE_MAX=100000 #[cite: 3]

# (2) Swap 倾向[cite: 3]
if [ "$MEM_MB" -le 1024 ]; then
    SWAPPINESS=30 #[cite: 3]
elif [ "$MEM_MB" -ge 4096 ]; then
    SWAPPINESS=1 #[cite: 3]
else
    SWAPPINESS=10 #[cite: 3]
fi

# (3) TCP 核心缓冲区 (最大值)[cite: 3]
TCP_MEM_MAX=$((MEM_MB * 8192)) #[cite: 3]
[[ $TCP_MEM_MAX -lt 8388608 ]] && TCP_MEM_MAX=8388608 #[cite: 3]
[[ $TCP_MEM_MAX -gt 134217728 ]] && TCP_MEM_MAX=134217728 #[cite: 3]

# (4) 队列连接并发与积压限制[cite: 3]
SOMAXCONN=$((MEM_MB * 8)) #[cite: 3]
MAX_PER_CORE=$((CPU_CORES * 16384)) #[cite: 3]
[[ $SOMAXCONN -gt $MAX_PER_CORE ]] && SOMAXCONN=$MAX_PER_CORE #[cite: 3]
[[ $SOMAXCONN -lt 4096 ]] && SOMAXCONN=4096 #[cite: 3]
[[ $SOMAXCONN -gt 65535 ]] && SOMAXCONN=65535 #[cite: 3]
BACKLOG=$((SOMAXCONN / 2)) #[cite: 3]

# (5) 路由与连接跟踪 (Conntrack)[cite: 3]
CONNTRACK_MAX=$((MEM_MB * 256)) #[cite: 3]
[[ $CONNTRACK_MAX -lt 131072 ]] && CONNTRACK_MAX=131072 #[cite: 3]

mkdir -p /etc/sysctl.d #[cite: 3]
CONF_FILE="/etc/sysctl.d/99-dynamic-network.conf" #[cite: 3]

cat <<EOF > $CONF_FILE
########################################
# ${CPU_CORES}C${MEM_GB}G 自动适配网络优化配置
########################################

# 1. 基础文件句柄
fs.file-max = $FILE_MAX
fs.nr_open = $FILE_MAX
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
net.ipv4.tcp_fastopen = 0
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
net.nf_conntrack_max = $CONNTRACK_MAX
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
EOF #[cite: 3]

echo "应用 sysctl 配置..." #[cite: 3]
sysctl -p $CONF_FILE #[cite: 3]

echo -e "\n========================================="
echo "初始化及优化已全部完成！"
echo "软/硬限制已设置为 ${LIMIT_NOFILE}，网络已适配 ${CPU_CORES}C${MEM_GB}G。"
echo "========================================="