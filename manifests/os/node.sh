#!/bin/bash

set -e

if [[ -e /var/lib/.bootstrapped ]]; then
    echo "node bootstrapped; quitting"
    exit 0
fi

curl-metadata() {
    curl --fail --silent -H "Metadata-Flavor: Google" "http://metadata/computeMetadata/v1/instance/attributes/${1}"
}

K8S_VERSION="{{ cluster.config.release.kubernetes.version }}"
ETCD_INITIAL_ENDPOINTS="{{ cluster.resources.etcd.get_initial_endpoints()|join(",") }}"
MASTER_IP="{{ cluster.master_ip }}"
DNS_SERVICE_IP="{{ cluster.config["layer-0"]["dns-service-ip"] }}"
CA_CERT="{{ pem("ca") }}"
WORKER_KEY="{{ pem("worker-key") }}"
WORKER_CERT="{{ pem("worker") }}"
ADVERTISE_IP=$(curl -s -H Metadata-Flavor:Google http://metadata.google.internal./computeMetadata/v1/instance/network-interfaces/0/ip)
ETCD_ENDPOINTS="${ETCD_INITIAL_ENDPOINTS}"
NODE_KIND="{{ config["name"] }}"
MAX_PODS="{{ config["max-pods"] }}"

systemctl stop update-engine.service
systemctl mask update-engine.service

mkdir -p /etc/kubernetes/ssl
echo "${CA_CERT}" | base64 -d > /etc/kubernetes/ssl/ca.pem
echo "${WORKER_KEY}" | base64 -d > /etc/kubernetes/ssl/worker-key.pem
echo "${WORKER_CERT}" | base64 -d > /etc/kubernetes/ssl/worker.pem
chmod 0600 /etc/kubernetes/ssl/*

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/50-custom-opts.conf <<EOF
[Service]
Environment="DOCKER_OPTS=--log-level=warn --log-driver=journald --bridge=cbr0"
EOF

mkdir -p /opt/bin

curl -s https://storage.googleapis.com/release.kelproject.com/binaries/kubernetes/${K8S_VERSION}/kubelet > /opt/bin/kubelet
chmod +x /opt/bin/kubelet

curl -s https://storage.googleapis.com/release.kelproject.com/binaries/kubernetes/${K8S_VERSION}/kubectl > /opt/bin/kubectl
chmod +x /opt/bin/kubectl

cat > /etc/systemd/system/kubelet.service <<EOF
[Service]
ExecStartPre=/bin/bash -c 'hostnamectl set-hostname $(hostname | cut -f1 -d.)'
ExecStart=/opt/bin/kubelet \
  --api-servers=https://${MASTER_IP} \
  --register-node=true \
  --cloud-provider=gce \
  --allow-privileged=true \
  --config=/etc/kubernetes/manifests \
  --cluster-dns=${DNS_SERVICE_IP} \
  --cluster-domain=cluster.local \
  --kubeconfig=/etc/kubernetes/worker-kubeconfig.yml \
  --tls-cert-file=/etc/kubernetes/ssl/worker.pem \
  --tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem \
  --cadvisor-port=4194 \
  --max-pods=${MAX_PODS} \
  --configure-cbr0=true
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/kubernetes/manifests

cat > /etc/kubernetes/manifests/kube-proxy.yml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: quay.io/kelproject/hyperkube:${K8S_VERSION}
    command:
    - /hyperkube
    - proxy
    - --master=https://${MASTER_IP}
    - --kubeconfig=/etc/kubernetes/worker-kubeconfig.yml
    securityContext:
      privileged: true
    volumeMounts:
      - mountPath: /etc/ssl/certs
        name: "ssl-certs"
      - mountPath: /etc/kubernetes/worker-kubeconfig.yml
        name: "kubeconfig"
        readOnly: true
      - mountPath: /etc/kubernetes/ssl
        name: "etc-kube-ssl"
        readOnly: true
  volumes:
    - name: "ssl-certs"
      hostPath:
        path: "/usr/share/ca-certificates"
    - name: "kubeconfig"
      hostPath:
        path: "/etc/kubernetes/worker-kubeconfig.yml"
    - name: "etc-kube-ssl"
      hostPath:
        path: "/etc/kubernetes/ssl"
EOF

cat > /etc/kubernetes/worker-kubeconfig.yml <<EOF
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    certificate-authority: /etc/kubernetes/ssl/ca.pem
users:
- name: kubelet
  user:
    client-certificate: /etc/kubernetes/ssl/worker.pem
    client-key: /etc/kubernetes/ssl/worker-key.pem
contexts:
- context:
    cluster: local
    user: kubelet
  name: kubelet-context
current-context: kubelet-context
EOF

systemctl daemon-reload

systemctl start kubelet
systemctl enable kubelet

until /opt/bin/kubectl --server="https://${MASTER_IP}" --kubeconfig=/etc/kubernetes/worker-kubeconfig.yml label "node/$(hostname)" "{{ cluster.config["managed-by"] }}/node-kind=${NODE_KIND}"; do
    echo "Waiting for kube-apiserver to label this node..."
    sleep 3
done

touch /var/lib/.bootstrapped
