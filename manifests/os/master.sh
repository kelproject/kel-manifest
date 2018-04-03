#!/bin/bash

set -e

if [[ -e /var/lib/.bootstrapped ]]; then
    echo "master bootstrapped; quitting"
    exit 0
fi

K8S_VERSION="{{ cluster.config.release.kubernetes.version }}"
POD_NETWORK="{{ cluster.config["layer-0"]["pod-network"] }}"
SERVICE_IP_RANGE="{{ cluster.config["layer-0"]["service-network"] }}"
DNS_SERVICE_IP="{{ cluster.config["layer-0"]["dns-service-ip"] }}"
NODE_TOKEN="{{ cluster.config["layer-0"]["node-token"] }}"

systemctl stop update-engine.service
systemctl mask update-engine.service

# install CNI
CNI_VERSION="v0.6.0"
mkdir -p /opt/cni/bin
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-amd64-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

# install Kubernetes binaries
mkdir -p /opt/bin
cd /opt/bin
curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/{kubeadm,kubelet,kubectl}
chmod +x {kubeadm,kubelet,kubectl}

# configure kubelet
cat > /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=http://kubernetes.io/docs/

[Service]
ExecStart=/opt/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<EOF
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_SYSTEM_PODS_ARGS=--pod-manifest-path=/etc/kubernetes/manifests --allow-privileged=true"
Environment="KUBELET_NETWORK_ARGS=--network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin"
Environment="KUBELET_DNS_ARGS=--cluster-dns=${DNS_SERVICE_IP} --cluster-domain=cluster.local"
Environment="KUBELET_AUTHZ_ARGS=--authorization-mode=Webhook --client-ca-file=/etc/kubernetes/pki/ca.crt"
Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=cgroupfs"
Environment="KUBELET_CADVISOR_ARGS=--cadvisor-port=0"
Environment="KUBELET_CERTIFICATE_ARGS=--rotate-certificates=true"
ExecStart=
ExecStart=/opt/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_SYSTEM_PODS_ARGS \$KUBELET_NETWORK_ARGS \$KUBELET_DNS_ARGS \$KUBELET_AUTHZ_ARGS \$KUBELET_CGROUP_ARGS \$KUBELET_CADVISOR_ARGS \$KUBELET_CERTIFICATE_ARGS \$KUBELET_EXTRA_ARGS
EOF
systemctl enable kubelet
systemctl start kubelet

systemctl enable docker.service
systemctl start docker.service

cat > /etc/kubernetes/kubeadm-config.yml <<EOF
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
etcd:
  endpoints:
  {% for endpoint in cluster.resources.etcd.get_initial_endpoints() %}  - {{ endpoint }}
{% endfor %}
token: ${NODE_TOKEN}
nodeName: $(hostname | cut -f1 -d.)
networking:
  serviceSubnet: ${SERVICE_IP_RANGE}
  podSubnet: ${POD_NETWORK}
EOF
kubeadm init --config /etc/kubernetes/kubeadm-config.yml

# install Calico
kubectl apply -f https://docs.projectcalico.org/v3.0/getting-started/kubernetes/installation/hosted/kubeadm/1.7/calico.yaml

touch /var/lib/.bootstrapped
