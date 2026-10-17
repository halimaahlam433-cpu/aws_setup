#!/bin/bash
set -e

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo "错误: 请使用 root 权限运行此脚本 (sudo bash $0)"
    exit 1
fi

SSH_PORT=53152

echo "========================================="
echo "开始执行 target_setup 初始化与系统优化..."
echo "========================================="

# ==========================================
# 阶段一：基础软件与安全初始化
# ==========================================
echo "--> 正在更新软件源并安装基础组件..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl fail2ban python3-systemd

echo "--> 正在修改 SSH 端口为 ${SSH_PORT}..."
if grep -q "^#\?Port " /etc/ssh/sshd_config; then
    sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
else
    echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
fi

# 兼容通过 sshd_config.d 覆盖配置的系统
mkdir -p /etc/ssh/sshd_config.d
echo "Port ${SSH_PORT}" > /etc/ssh/sshd_config.d/99-custom-port.conf

# 校验 SSH 配置无误后再重启服务
sshd -t
systemctl daemon-reload
if systemctl is-active --quiet ssh.socket; then
    systemctl stop ssh.socket
    systemctl disable ssh.socket
fi
systemctl restart ssh || systemctl restart sshd

echo "--> 正在配置并启动 Fail2Ban (监听端口 ${SSH_PORT})..."
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
EOF

systemctl enable fail2ban
systemctl restart fail2ban
systemctl status fail2ban --no-pager || true

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
SOFT_NOFILE=65536
HARD_NOFILE=1048576
LIMIT_NPROC=65535

echo "--> 正在配置 systemd 资源限制..."

SYSTEMD_CONF="[Manager]
DefaultLimitNOFILE=${SOFT_NOFILE}:${HARD_NOFILE}
DefaultLimitNPROC=${LIMIT_NPROC}:infinity
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=infinity"

mkdir -p /etc/systemd/system.conf.d
mkdir -p /etc/systemd/user.conf.d

echo "$SYSTEMD_CONF" > /etc/systemd/system.conf.d/99-custom-limits.conf
echo "$SYSTEMD_CONF" > /etc/systemd/user.conf.d/99-custom-limits.conf

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

# (1) 系统级文件句柄总数与单进程上限 (使用 if 避免触发 set -e 退出)
FILE_MAX=$((MEM_MB * 512))
if [[ $FILE_MAX -lt 1048576 ]]; then
    FILE_MAX=1048576
fi

NR_OPEN=1048576
if [[ $FILE_MAX -gt $NR_OPEN ]]; then
    NR_OPEN=2097152
fi

# (2) Swap 倾向
if [[ $MEM_MB -le 1024 ]]; then
    SWAPPINESS=30
elif [[ $MEM_MB -ge 4096 ]]; then
    SWAPPINESS=1
else
    SWAPPINESS=10
fi

# (3) TCP 核心缓冲区 (最大值，单位：字节)
TCP_MEM_MAX=$((MEM_MB * 8192))
if [[ $TCP_MEM_MAX -lt 8388608 ]]; then
    TCP_MEM_MAX=8388608
elif [[ $TCP_MEM_MAX -gt 134217728 ]]; then
    TCP_MEM_MAX=134217728
fi

# (4) 队列连接并发与积压限制
SOMAXCONN=$((MEM_MB * 8))
MAX_PER_CORE=$((CPU_CORES * 16384))

if [[ $SOMAXCONN -gt $MAX_PER_CORE ]]; then
    SOMAXCONN=$MAX_PER_CORE
fi
if [[ $SOMAXCONN -lt 4096 ]]; then
    SOMAXCONN=4096
elif [[ $SOMAXCONN -gt 65535 ]]; then
    SOMAXCONN=65535
fi

BACKLOG=$((SOMAXCONN / 2))

# (5) 路由与连接跟踪 (Conntrack)
CONNTRACK_MAX=$((MEM_MB * 256))
if [[ $CONNTRACK_MAX -lt 131072 ]]; then
    CONNTRACK_MAX=131072
fi

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

echo "--> 应用 sysctl 配置..."
sysctl -e -p "$CONF_FILE"

echo "--> 重载 systemd 守护进程..."
systemctl daemon-reload
systemctl daemon-reexec

echo -e "\n========================================="
echo "初始化及优化已全部完成！"
echo "SSH 端口已改为 ${SSH_PORT}，软/硬限制已设置为 ${SOFT_NOFILE}/${HARD_NOFILE}，网络已适配 ${CPU_CORES}C${MEM_GB}G。"
echo "========================================="