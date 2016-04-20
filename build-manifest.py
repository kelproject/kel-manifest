import base64
import json
import os


def load_manifest(path):
    here = os.path.abspath(os.path.dirname(__file__))
    with open(os.path.join(here, "manifests", path), "rb") as fp:
        return base64.b64encode(fp.read()).decode("utf-8")


def get_layers():
    return {
        "os": {
            "type": "coreos",
            "channel": "stable",
            "version": "899.15.0",
            "manifests": {
                "etcd": load_manifest("os/etcd.sh"),
                "master": load_manifest("os/master.sh"),
                "node": load_manifest("os/node.sh"),
            },
        },
        "kubernetes": {
            "version": "v1.2.2_kel.0",
            "images": {
                "kube-dns": {
                    "etcd": "gcr.io/google_containers/etcd:2.0.9",
                    "kube2sky": "gcr.io/google_containers/kube2sky:1.11",
                    "skydns": "gcr.io/google_containers/skydns:2015-10-13-8c72f8c",
                }
            },
            "manifests": {
                "kube-dns": load_manifest("kubernetes/dns.yml"),
            },
        },
        "kel": {
            "bundles": {
                "api": "git-ce6fa670",
                "blobstore": "git-dec5e2b1",
                "router": "git-717bba4c",
            },
            "images": {
                "bundle-builder": "quay.io/kelproject/bundle-builder",
                "bundle-runner": "quay.io/kelproject/bundle-runner",
                "api-cache": "quay.io/kelproject/services:redis-3.0",
                "api-database": "quay.io/kelproject/services:postgresql-9.4",
                "api-web": "quay.io/kelproject/bundle-runner",
                "api-worker": "quay.io/kelproject/bundle-runner",
                "blobstore-data": "quay.io/kelproject/services:data-1.0",
                "blobstore": "quay.io/kelproject/bundle-runner",
                "log-agent": "quay.io/kelproject/log-agent",
                "logstash": "quay.io/kelproject/logstash",
                "log-store": "quay.io/pires/docker-elasticsearch-kubernetes:2.2.0",
                "router": "quay.io/kelproject/bundle-runner",
            },
            "manifests": {
                "kel-system": load_manifest("kel/kel-system.yml"),
                "kel-builds": load_manifest("kel/kel-builds.yml"),
                "router": load_manifest("kel/router.yml"),
                "blobstore-data": load_manifest("kel/blobstore-data.yml"),
                "blobstore": load_manifest("kel/blobstore.yml"),
                "api-cache": load_manifest("kel/api-cache.yml"),
                "api-database": load_manifest("kel/api-database.yml"),
                "api-web": load_manifest("kel/api-web.yml"),
                "api-worker": load_manifest("kel/api-worker.yml"),
                "log-agent": load_manifest("kel/log-agent.yml"),
                "logstash": load_manifest("kel/logstash.yml"),
                "log-store": load_manifest("kel/log-store.yml"),
            },
        },
    }


def main():
    print(json.dumps({"layers": get_layers()}))


if __name__ == "__main__":
    main()
