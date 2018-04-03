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
ETCD_DISK="/dev/disk/by-id/google-etcd-pd"

# format persistence disk
mkdir -p /mnt/etcd-pd
mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "${ETCD_DISK}"
mount -o discard,defaults "${ETCD_DISK}" /mnt/etcd-pd
chmod a+w /mnt/etcd-pd
echo UUID=$(blkid -s UUID -o value "${ETCD_DISK}") /mnt/etcd-pd ext4 discard,defaults,nofail 0 2 | tee -a /etc/fstab

mkdir -m 700 -p /mnt/etcd-pd/var/etcd/data.etcd
chown -R etcd:etcd /mnt/etcd-pd/var/etcd

mkdir -p /etc/systemd/system/etcd-member.service.d
cat > /tmp/20-cl-etcd-member.conf <<EOF
[Service]
Environment="ETCD_DATA_DIR=/mnt/etcd-pd/var/etcd/data.etcd"
Environment="ETCD_SSL_DIR=/etc/ssl/certs"
Environment="ETCD_OPTS=--name ${ETCD_NODE_NAME} \
  --listen-client-urls http://0.0.0.0:2379 \
  --advertise-client-urls http://${ETCD_NODE_DNS}:2379 \
  --listen-peer-urls http://0.0.0.0:2380 \
  --initial-advertise-peer-urls http://${ETCD_NODE_DNS}:2380 \
  --initial-cluster ${ETCD_INITIAL_NODES} \
  --initial-cluster-token mytoken \
  --initial-cluster-state new \
  --auto-compaction-retention 1"
EOF
mv /tmp/20-cl-etcd-member.conf /etc/systemd/system/etcd-member.service.d/20-cl-etcd-member.conf

systemctl daemon-reload
systemctl enable --now etcd-member.service

touch /var/lib/.bootstrapped
