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

cat > /tmp/20-cl-etcd-member.conf <<EOF
[Service]
Environment="ETCD_DATA_DIR=/mnt/etcd-pd/var/etcd/data.etcd"
Environment="ETCD_SSL_DIR=/etc/ssl/certs"
Environment="ETCD_OPTS=--name ${ETCD_NODE_NAME} \
  --listen-client-urls http://0.0.0.0:2379 \
  --advertise-client-urls http://${ETCD_NODE_DNS}:2379 \
  --listen-peer-urls http://0.0.0.0:2380 \
  --initial-advertise-peer-urls http://${ETCD_NODE_DNS}:2380 \
  --initial-cluster s1=${ETCD_INITIAL_NODES} \
  --initial-cluster-token mytoken \
  --initial-cluster-state new \
  --client-cert-auth \
  --trusted-ca-file /etc/ssl/certs/etcd-root-ca.pem \
  --cert-file /etc/ssl/certs/s1.pem \
  --key-file /etc/ssl/certs/s1-key.pem \
  --peer-client-cert-auth \
  --peer-trusted-ca-file /etc/ssl/certs/etcd-root-ca.pem \
  --peer-cert-file /etc/ssl/certs/s1.pem \
  --peer-key-file /etc/ssl/certs/s1-key.pem \
  --auto-compaction-retention 1"
EOF
mv /tmp/20-cl-etcd-member.conf /etc/systemd/system/etcd-member.service.d/20-cl-etcd-member.conf

systemctl daemon-reload
systemctl enable --now etcd-member.service

touch /var/lib/.bootstrapped
