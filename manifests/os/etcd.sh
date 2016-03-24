#!/bin/bash

set -e

if [[ -e /var/lib/.bootstrapped ]]; then
    echo "node bootstrapped; quitting"
    exit 0
fi

function curl-metadata() {
    curl --fail --silent -H "Metadata-Flavor: Google" "http://metadata/computeMetadata/v1/instance/attributes/${1}"
}

ETCD_NODE_NAME="{{ etcd.get_node_name(i) }}"
ETCD_NODE_DNS="{{ etcd.get_node_fqdn(i) }}"
ETCD_INITIAL_NODES="{{ etcd.get_initial_nodes()|join(",") }}"
ADVERTISE_IP=$(curl -s -H Metadata-Flavor:Google http://metadata.google.internal./computeMetadata/v1/instance/network-interfaces/0/ip)

# format persistence disk
mkdir -p /mnt/etcd-pd
/usr/share/oem/google-startup-scripts/safe_format_and_mount -m "mkfs.ext4 -F" /dev/disk/by-id/google-etcd-pd /mnt/etcd-pd

mkdir -m 700 -p /mnt/etcd-pd/var/etcd/data.etcd
chown -R etcd:etcd /mnt/etcd-pd/var/etcd

mkdir -p /etc/systemd/system/etcd2.service.d
cat > /etc/systemd/system/etcd2.service.d/40-listen-address.conf <<EOF
[Service]
Environment=ETCD_NAME=${ETCD_NODE_NAME}
Environment=ETCD_DATA_DIR=/mnt/etcd-pd/var/etcd/data.etcd
Environment=ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379
Environment=ETCD_ADVERTISE_CLIENT_URLS=http://${ETCD_NODE_DNS}:2379
Environment=ETCD_INITIAL_CLUSTER=${ETCD_INITIAL_NODES}
Environment=ETCD_INITIAL_CLUSTER_STATE=new
Environment=ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380,http://localhost:7001
Environment=ETCD_INITIAL_ADVERTISE_PEER_URLS=http://${ETCD_NODE_DNS}:2380
EOF
systemctl start etcd2
systemctl enable etcd2

touch /var/lib/.bootstrapped
