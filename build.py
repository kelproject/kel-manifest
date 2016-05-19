import base64
import json
import os

import requests


def load_manifest(path):
    here = os.path.abspath(os.path.dirname(__file__))
    with open(os.path.join(here, "manifests", path), "rb") as fp:
        return base64.b64encode(fp.read()).decode("utf-8")


def get_release():
    return {
        "os": {
            "type": "coreos",
            "channel": "stable",
            "version": "899.17.0",
            "manifests": {
                "etcd": load_manifest("os/etcd.sh"),
                "master": load_manifest("os/master.sh"),
                "node": load_manifest("os/node.sh"),
            },
        },
        "kubernetes": {
            "version": "v1.2.4_kel.1",
            "images": {
                "kube-dns": {
                    "etcd": "gcr.io/google_containers/etcd-amd64:2.2.1",
                    "kube2sky": "gcr.io/google_containers/kube2sky:1.14",
                    "skydns": "gcr.io/google_containers/skydns:2015-10-13-8c72f8c",
                }
            },
            "manifests": {
                "kube-dns": load_manifest("kubernetes/dns.yml"),
            },
        },
        "kel": {
            "bundles": {
                "api": "git-566d3e90",
            },
            "images": {
                "bundle-builder": "quay.io/kelproject/bundle-builder",
                "bundle-runner": "quay.io/kelproject/bundle-runner",
                "api-cache": "redis:3.0",
                "api-database": "postgres:9.5",
                "api-web": "quay.io/kelproject/bundle-runner",
            },
            "manifests": {
                "kel-system": load_manifest("kel/kel-system.yml"),
                "kel-builds": load_manifest("kel/kel-builds.yml"),
                "router": load_manifest("kel/router.yml"),
                "api-cache": load_manifest("kel/api-cache.yml"),
                "api-database": load_manifest("kel/api-database.yml"),
                "api-web": load_manifest("kel/api-web.yml"),
            },
        },
    }


def main():
    with open("manifest.json", "w") as fp:
        fp.write(json.dumps(get_release()))
    with open("channels.json", "w") as fp:
        r = requests.get("https://storage.googleapis.com/release.kelproject.com/distro/channels.json")
        if r.ok:
            channels = json.loads(r.content.decode("utf-8"))
        else:
            channels = {"stable": None, "beta": None, "dev": {}}
        git_tag = os.environ.get("TRAVIS_TAG", "")
        if git_tag:
            version, channel = git_tag.split("-")
            channels[channel] = version
        else:
            channels["dev"][os.environ["TRAVIS_BRANCH"]] = os.environ["BUILD_TAG"]
        fp.write(json.dumps(channels))


if __name__ == "__main__":
    main()
