#!/bin/bash

# ==========================================
# 0. 权限检查
# ==========================================
if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本"
   exit 1
fi

echo "========================================="
echo "开始执行综合系统初始化与网络优化部署..."
echo "========================================="

# ==========================================
# 1. 系统初始化与安全配置
# ==========================================
echo ">>> [1/4] 更新软件源并配置防火墙与 SSH..."
apt update
apt install -y curl ufw fail2ban

ufw allow 22/tcp
ufw allow 53152/tcp
ufw --force enable

mkdir -p /root/.ssh
cp /home/admin/.ssh/authorized_keys /root/.ssh/ 2>/dev/null || true
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
if grep -q "^#\?Port " /etc/ssh/sshd_config; then
    sed -i 's/^#\?Port .*/Port 53152/' /etc/ssh/sshd_config
else
    echo "Port 53152" >> /etc/ssh/sshd_config
fi
systemctl restart ssh

systemctl enable fail2ban
systemctl start fail2ban
systemctl status fail2ban --no-pager

# ==========================================
# 2. 安装与配置 Realm (x86_64)
# ==========================================
echo -e "\n>>> [2/4] 下载并配置 Realm 端口转发..."
mkdir -p /usr/src/realm && cd /usr/src/realm
wget https://github.com/zhboner/realm/releases/download/v2.9.3/realm-x86_64-unknown-linux-gnu.tar.gz
tar -zxvf realm-x86_64-unknown-linux-gnu.tar.gz
chmod +x realm
chown -R root:root realm
mv realm /usr/local/bin/
cd - > /dev/null
rm -rf /usr/src/realm
realm --version

mkdir -p /etc/realm
cat << 'REALM_EOF' > /etc/realm/config.toml
[log]
level = "info"
output = "/var/log/realm.log"

[network]
use_udp = true

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

# 动态获取系统最大文件描述符数 (兜底默认值为 65535)
MAX_FD=$(sysctl -n fs.nr_open 2>/dev/null || echo 65535)

cat << SERVICE_EOF > /etc/systemd/system/realm.service
[Unit]
Description=Realm Port Forwarding
After=network.target

[Service]
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=always
User=root
Group=root
LimitNOFILE=${MAX_FD}

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable realm --now
systemctl status realm --no-pager

# ==========================================
# 3. 动态系统资源限制解除
# ==========================================
echo -e "\n>>> [3/4] 检测系统硬件配置并调整连接限制..."
CPU_CORES=$(nproc)
MEM_TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
MEM_TOTAL_MB=${MEM_TOTAL_MB:-1024}

CALC_CONNS=$((MEM_TOTAL_MB * 128))
if [ "$CALC_CONNS" -lt 65536 ]; then
    MAX_CONNS=65536
elif [ "$CALC_CONNS" -gt 1048576 ]; then
    MAX_CONNS=1048576
else
    MAX_CONNS=$CALC_CONNS
fi

SYSTEMD_CONF="[Manager]
DefaultLimitNOFILE=${MAX_CONNS}:${MAX_CONNS}
DefaultLimitNPROC=${MAX_CONNS}:${MAX_CONNS}
DefaultLimitMEMLOCK=infinity
DefaultTasksMax=infinity"

mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
echo "$SYSTEMD_CONF" > /etc/systemd/system.conf.d/99-custom-limits.conf
echo "$SYSTEMD_CONF" > /etc/systemd/user.conf.d/99-custom-limits.conf

mkdir -p /etc/security/limits.d
cat << LIMITS_EOF > /etc/security/limits.d/99-conns.conf
* soft nofile ${MAX_CONNS}
* hard nofile ${MAX_CONNS}
* soft nproc ${MAX_CONNS}
* hard nproc ${MAX_CONNS}
root soft nofile ${MAX_CONNS}
root hard nofile ${MAX_CONNS}
root soft nproc ${MAX_CONNS}
root hard nproc ${MAX_CONNS}
LIMITS_EOF

systemctl daemon-reload
systemctl daemon-reexec

# ==========================================
# 4. 动态 sysctl 网络参数优化
# ==========================================
echo -e "\n>>> [4/4] 动态计算并应用 sysctl 网络优化参数..."
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$((MEM_KB / 1024))
MEM_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_MB/1024}")

FILE_MAX=$((MEM_MB * 512))
[[ $FILE_MAX -lt 100000 ]] && FILE_MAX=100000

if [ "$MEM_MB" -le 1024 ]; then
    SWAPPINESS=30
elif [ "$MEM_MB" -ge 4096 ]; then
    SWAPPINESS=1
else
    SWAPPINESS=10
fi

TCP_MEM_MAX=$((MEM_MB * 8192))
[[ $TCP_MEM_MAX -lt 8388608 ]] && TCP_MEM_MAX=8388608
[[ $TCP_MEM_MAX -gt 134217728 ]] && TCP_MEM_MAX=134217728

SOMAXCONN=$((MEM_MB * 8))
MAX_PER_CORE=$((CPU_CORES * 16384))
[[ $SOMAXCONN -gt $MAX_PER_CORE ]] && SOMAXCONN=$MAX_PER_CORE
[[ $SOMAXCONN -lt 4096 ]] && SOMAXCONN=4096
[[ $SOMAXCONN -gt 65535 ]] && SOMAXCONN=65535
BACKLOG=$((SOMAXCONN / 2))

CONNTRACK_MAX=$((MEM_MB * 256))
[[ $CONNTRACK_MAX -lt 131072 ]] && CONNTRACK_MAX=131072

mkdir -p /etc/sysctl.d
CONF_FILE="/etc/sysctl.d/99-dynamic-network.conf"

cat << SYSCTL_EOF > $CONF_FILE
fs.file-max = $FILE_MAX
fs.nr_open = $FILE_MAX
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
net.ipv4.tcp_fastopen = 0
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
net.nf_conntrack_max = $CONNTRACK_MAX
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

sysctl -p $CONF_FILE

echo -e "\n========================================="
echo "所有初始化、Realm 部署、资源解锁与网络参数优化已全部自动完成！"
echo "========================================="
MASTER_EOF