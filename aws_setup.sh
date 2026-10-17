#!/bin/bash
set -e

# ==========================================
# 0. 权限与系统架构检查
# ==========================================
if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本 (sudo bash $0)"
   exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        REALM_ARCH="x86_64"
        ;;
    aarch64|arm64)
        REALM_ARCH="aarch64"
        ;;
    *)
        echo "错误: 当前系统架构 (${ARCH}) 不受支持，仅支持 x86_64 与 aarch64"
        exit 1
        ;;
esac

SSH_PORT=53152
REALM_VERSION="v2.9.3"
REALM_PKG="realm-${REALM_ARCH}-unknown-linux-gnu.tar.gz"

echo "========================================="
echo "开始执行综合系统初始化与网络优化部署 (检测到架构: ${REALM_ARCH})..."
echo "========================================="

# ==========================================
# 1. 系统初始化与安全配置
# ==========================================
echo ">>> [1/4] 更新软件源并配置防火墙与 SSH..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget tar ca-certificates ufw fail2ban python3-systemd

# 放行 SSH 端口与 Realm 转发端口 (TCP + UDP)
ufw allow 22/tcp
ufw allow ${SSH_PORT}/tcp
ufw allow 10001:10003/tcp
ufw allow 10001:10003/udp
ufw --force enable

# 兼容 AWS Debian (admin) 与 Ubuntu (ubuntu) 默认用户的公钥复制
mkdir -p /root/.ssh
if [[ -f /home/admin/.ssh/authorized_keys ]]; then
    cp /home/admin/.ssh/authorized_keys /root/.ssh/authorized_keys
elif [[ -f /home/ubuntu/.ssh/authorized_keys ]]; then
    cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
fi
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
if grep -q "^#\?Port " /etc/ssh/sshd_config; then
    sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
else
    echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
fi

mkdir -p /etc/ssh/sshd_config.d
echo "Port ${SSH_PORT}" > /etc/ssh/sshd_config.d/99-custom-port.conf

sshd -t
systemctl daemon-reload
if systemctl is-active --quiet ssh.socket; then
    systemctl stop ssh.socket
    systemctl disable ssh.socket
fi
systemctl restart ssh || systemctl restart sshd

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
# 2. 动态 sysctl 网络参数优化 (优先提权内核上限)
# ==========================================
echo -e "\n>>> [2/4] 动态计算并应用 sysctl 网络优化参数..."
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

CPU_CORES=$(nproc)
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))
MEM_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_MB/1024}")

echo "检测到系统配置: ${CPU_CORES} 核心 CPU, 内存约为 ${MEM_GB} GB (${MEM_MB} MB), 架构: ${REALM_ARCH}"

# 确保 fs.nr_open 绝不低于 1048576，防止任何 systemd 服务因 LimitNOFILE 过高而启动失败
FILE_MAX=$((MEM_MB * 512))
if [[ $FILE_MAX -lt 1048576 ]]; then
    FILE_MAX=1048576
fi

NR_OPEN=1048576
if [[ $FILE_MAX -gt $NR_OPEN ]]; then
    NR_OPEN=2097152
fi

if [[ $MEM_MB -le 1024 ]]; then
    SWAPPINESS=30
elif [[ $MEM_MB -ge 4096 ]]; then
    SWAPPINESS=1
else
    SWAPPINESS=10
fi

TCP_MEM_MAX=$((MEM_MB * 8192))
if [[ $TCP_MEM_MAX -lt 8388608 ]]; then
    TCP_MEM_MAX=8388608
elif [[ $TCP_MEM_MAX -gt 134217728 ]]; then
    TCP_MEM_MAX=134217728
fi

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

CONNTRACK_MAX=$((MEM_MB * 256))
if [[ $CONNTRACK_MAX -lt 131072 ]]; then
    CONNTRACK_MAX=131072
fi

mkdir -p /etc/sysctl.d
CONF_FILE="/etc/sysctl.d/99-dynamic-network.conf"

cat << SYSCTL_EOF > "$CONF_FILE"
fs.file-max = $FILE_MAX
fs.nr_open = $NR_OPEN
vm.swappiness = $SWAPPINESS
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $TCP_MEM_MAX
net.core.wmem_max = $TCP_MEM_MAX
net.ipv4.tcp_rmem = 4096 87380 $TCP_MEM_MAX
net.ipv4.tcp_wmem = 4096 65536 $TCP_MEM_MAX
net.ipv4.udp_rmem_min = 4096
net.ipv4.udp_wmem_min = 4096
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SOMAXCONN
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_autocorking = 1
net.ipv4.route.flush = 1
net.ipv6.auto_flowlabels = 1
net.ipv4.tcp_synack_retries = 3
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
SYSCTL_EOF

sysctl -e -p "$CONF_FILE"

# ==========================================
# 3. 系统资源限制解除 (systemd & PAM)
# ==========================================
echo -e "\n>>> [3/4] 调整 systemd 与 PAM 资源限制..."
SOFT_NOFILE=65536
HARD_NOFILE=1048576
LIMIT_NPROC=65535

SYSTEMD_CONF="[Manager]
DefaultLimitNOFILE=${SOFT_NOFILE}:${HARD_NOFILE}
DefaultLimitNPROC=${LIMIT_NPROC}:infinity
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=infinity"

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
echo "$SYSTEMD_CONF" > /etc/systemd/system.conf.d/99-custom-limits.conf
echo "$SYSTEMD_CONF" > /etc/systemd/user.conf.d/99-custom-limits.conf

mkdir -p /etc/security/limits.d
cat << LIMITS_EOF > /etc/security/limits.d/99-conns.conf
* soft nofile ${HARD_NOFILE}
* hard nofile ${HARD_NOFILE}
* soft nproc ${LIMIT_NPROC}
* hard nproc infinity
root soft nofile ${HARD_NOFILE}
root hard nofile ${HARD_NOFILE}
root soft nproc ${LIMIT_NPROC}
root hard nproc infinity
LIMITS_EOF

systemctl daemon-reload
systemctl daemon-reexec

# ==========================================
# 4. 自动按架构安装与配置 Realm
# ==========================================
echo -e "\n>>> [4/4] 下载并配置 Realm 端口转发 (${REALM_ARCH})..."
mkdir -p /usr/src/realm && cd /usr/src/realm
wget -q --show-progress "https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/${REALM_PKG}"
tar -zxvf "${REALM_PKG}"
chmod +x realm
chown root:root realm
mv realm /usr/local/bin/
cd - > /dev/null
rm -rf /usr/src/realm
/usr/local/bin/realm --version

mkdir -p /etc/realm
cat << 'REALM_EOF' > /etc/realm/config.toml
[log]
level = "info"
output = "/var/log/realm.log"

[network]
no_tcp = false
use_udp = true
fast_open = true

[[endpoints]]
listen = "[::]:10001"
remote = "bl.xzcloudnode.sbs:50309"
tcpFastOpen = true
udp = true

[[endpoints]]
listen = "[::]:10002"
remote = "158.21.17.235:35003"
tcpFastOpen = true
udp = true

[[endpoints]]
listen = "[::]:10003"
remote = "[2404:7a80:ff20:6900:be24:11ff:fe6c:e661]:30123"
tcpFastOpen = true
udp = true
REALM_EOF

cat << SERVICE_EOF > /etc/systemd/system/realm.service
[Unit]
Description=Realm Port Forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=always
RestartSec=3
User=root
Group=root
LimitNOFILE=${HARD_NOFILE}
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable realm
systemctl restart realm
systemctl status realm --no-pager || true

echo -e "\n========================================="
echo "所有初始化、Realm (${REALM_ARCH}) 部署、资源解锁与网络参数优化已全部自动完成！"
echo "SSH 端口: ${SSH_PORT} | 转发端口: 10001-10003 | LimitNOFILE: ${SOFT_NOFILE}/${HARD_NOFILE}"
echo "========================================="