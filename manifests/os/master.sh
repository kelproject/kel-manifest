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
POD_NETWORK="{{ cluster.config["layer-0"]["pod-network"] }}"
SERVICE_IP_RANGE="{{ cluster.config["layer-0"]["service-network"] }}"
DNS_SERVICE_IP="{{ cluster.config["layer-0"]["dns-service-ip"] }}"
CA_KEY="{{ pem("ca-key") }}"
CA_CERT="{{ pem("ca") }}"
APISERVER_KEY="{{ pem("apiserver-key") }}"
ADVERTISE_IP=$(curl -s -H Metadata-Flavor:Google http://metadata.google.internal./computeMetadata/v1/instance/network-interfaces/0/ip)
ETCD_ENDPOINTS="${ETCD_INITIAL_ENDPOINTS}"

systemctl stop update-engine.service
systemctl mask update-engine.service

mkdir -p /etc/kubernetes/ssl
echo "${CA_KEY}" | base64 -d > /etc/kubernetes/ssl/ca-key.pem
echo "${CA_CERT}" | base64 -d > /etc/kubernetes/ssl/ca.pem
echo "${APISERVER_KEY}" | base64 -d > /etc/kubernetes/ssl/apiserver-key.pem
cat > /tmp/openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = $(curl -s -H Metadata-Flavor:Google http://metadata.google.internal./computeMetadata/v1/instance/hostname | cut -f1 -d.)
IP.1 = 10.3.0.1
IP.2 = {{ cluster.master_ip }}
EOF
openssl req -new -key /etc/kubernetes/ssl/apiserver-key.pem -out /tmp/apiserver.csr -subj "/CN=kube-apiserver" -config /tmp/openssl.cnf
openssl x509 -req -in /tmp/apiserver.csr -CA /etc/kubernetes/ssl/ca.pem -CAkey /etc/kubernetes/ssl/ca-key.pem -CAcreateserial -out /etc/kubernetes/ssl/apiserver.pem -days 365 -extensions v3_req -extfile /tmp/openssl.cnf
rm /tmp/openssl.cnf /tmp/apiserver.csr
chmod 0600 /etc/kubernetes/ssl/*

mkdir -p /etc/flannel
cat > /etc/flannel/options.env <<EOF
FLANNELD_IFACE=${ADVERTISE_IP}
FLANNELD_ETCD_ENDPOINTS=${ETCD_ENDPOINTS}
EOF
mkdir -p /etc/systemd/system/flanneld.service.d
cat > /etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf <<EOF
[Service]
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/40-flannel.conf <<EOF
[Unit]
Requires=flanneld.service
After=flanneld.service
EOF
cat > /etc/systemd/system/docker.service.d/50-custom-opts.conf <<EOF
[Service]
Environment=DOCKER_OPTS='--log-level=warn --log-driver=journald'
EOF

mkdir -p /opt/bin
curl -s https://storage.googleapis.com/release.kelproject.com/binaries/kubernetes/${K8S_VERSION}/kubelet > /opt/bin/kubelet
chmod +x /opt/bin/kubelet

cat > /etc/systemd/system/kubelet.service <<EOF
[Service]
ExecStartPre=/bin/bash -c 'hostnamectl set-hostname $(hostname | cut -f1 -d.)'
ExecStart=/opt/bin/kubelet \
  --api-servers=http://127.0.0.1:8080 \
  --register-schedulable=false \
  --cloud-provider=gce \
  --allow-privileged=true \
  --config=/etc/kubernetes/manifests \
  --cluster-dns=${DNS_SERVICE_IP} \
  --cluster-domain=cluster.local \
  --cadvisor-port=4194
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/kubernetes/manifests

cat > /etc/kubernetes/manifests/kube-apiserver.yml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-apiserver
    image: quay.io/kelproject/hyperkube:${K8S_VERSION}
    command:
    - /hyperkube
    - apiserver
    - --bind-address=0.0.0.0
    - --etcd-servers=${ETCD_ENDPOINTS}
    - --allow-privileged=true
    - --service-cluster-ip-range=${SERVICE_IP_RANGE}
    - --secure-port=443
    - --insecure-bind-address=0.0.0.0
    - --insecure-port=8080
    - --advertise-address=${ADVERTISE_IP}
    - --admission-control=NamespaceLifecycle,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota
    - --tls-cert-file=/etc/kubernetes/ssl/apiserver.pem
    - --tls-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --client-ca-file=/etc/kubernetes/ssl/ca.pem
    - --service-account-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --cloud-provider=gce
    - --runtime-config=extensions/v1beta1/deployments=true,extensions/v1beta1/daemonsets=true,extensions/v1beta1/ingress=true
    ports:
    - containerPort: 443
      hostPort: 443
      name: https
    - containerPort: 8080
      hostPort: 8080
      name: local
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF

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
    - --master=http://127.0.0.1:8080
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  volumes:
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF

cat > /etc/kubernetes/manifests/kube-controller-manager.yml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - name: kube-controller-manager
    image: quay.io/kelproject/hyperkube:${K8S_VERSION}
    command:
    - /hyperkube
    - controller-manager
    - --master=http://127.0.0.1:8080
    - --service-account-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --root-ca-file=/etc/kubernetes/ssl/ca.pem
    - --leader-elect=true
    - --cloud-provider=gce
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10252
      initialDelaySeconds: 15
      timeoutSeconds: 1
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF

cat > /etc/kubernetes/manifests/kube-scheduler.yml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-scheduler
    image: quay.io/kelproject/hyperkube:${K8S_VERSION}
    command:
    - /hyperkube
    - scheduler
    - --master=http://127.0.0.1:8080
    - --leader-elect=true
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10251
      initialDelaySeconds: 15
      timeoutSeconds: 1
EOF

systemctl daemon-reload

# randomly select an etcd url from the comma-separated list
{% raw %}ETCD_URL_ARRAY=(${ETCD_ENDPOINTS//,/ })
ETCD_URL=${ETCD_URL_ARRAY[$RANDOM % ${#ETCD_URL_ARRAY[@]}]}
until curl -X PUT -d "value={\"Network\":\"${POD_NETWORK}\", \"Backend\": {\"Type\": \"gce\"}}" "${ETCD_URL}/v2/keys/coreos.com/network/config"; do
    echo "Waiting for etcd to set flannel config..."
    sleep 3
    ETCD_URL=${ETCD_URL_ARRAY[$RANDOM % ${#ETCD_URL_ARRAY[@]}]}
done{% endraw %}

systemctl start kubelet
systemctl enable kubelet

touch /var/lib/.bootstrapped

{% raw %}until curl -XPOST -H "Content-Type: application/json" -d'{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"kube-system"}}' "http://127.0.0.1:8080/api/v1/namespaces"; do
    echo "Waiting for kube-apiserver to create kube-system namespace..."
    sleep 3
done{% endraw %}
