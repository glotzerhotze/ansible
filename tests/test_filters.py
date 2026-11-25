"""Unit tests for plugins/filter/*.py. Run: python -m pytest tests/"""

import hashlib
import os
import sys

import pytest
import yaml

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "plugins", "filter"))

import ipam  # noqa: E402
import quadlets as q  # noqa: E402
from ansible.errors import AnsibleFilterError  # noqa: E402

DEFAULTS = yaml.safe_load(open(os.path.join(HERE, "..", "roles", "quadlets", "defaults", "main.yml")))
QD = DEFAULTS["quadlets_defaults"]
IPAM = yaml.safe_load(open(os.path.join(HERE, "..", "pillar", "ipam.yaml")))


# ------------------------------------------------------------------- ipam

def test_ipam_lookups():
    assert ipam.ipam_ip(IPAM, "hosts:rpi-01:apps:pihole:ipv4") == "192.168.23.3"
    assert ipam.ipam_ip(IPAM, "networks:mgmt:ipv4:subnet") == "192.168.23.0/24"
    assert ipam.ipam_cidr(IPAM, "rpi-01", "mgmt") == "192.168.23.65/24"
    assert ipam.ipam_cidr(IPAM, "rpi-01", "iot", "ipv6") == "fd42:ac1d:feed:30::65/64"
    assert ipam.ipam_ips(IPAM, "dns") == ["192.168.23.3", "192.168.23.33"]
    assert ipam.ipam_mac(IPAM, "hosts:rpi-01:apps:pihole:mac") == "02:ac:1d:fe:ed:03"


@pytest.mark.parametrize("call", [
    lambda: ipam.ipam_ip(IPAM, "hosts:rpi-01:apps:nope:ipv4"),
    lambda: ipam.ipam_ip(IPAM, "hosts:rpi-01:apps:pihole:mac"),
    lambda: ipam.ipam_mac(IPAM, "hosts:rpi-01:apps:pihole:ipv4"),
    lambda: ipam.ipam_ips(IPAM, "networks"),
    lambda: ipam.ipam_cidr(IPAM, "rpi-01", "surfer", "ipv6"),
])
def test_ipam_misses_fail(call):
    with pytest.raises(AnsibleFilterError):
        call()


# --------------------------------------------------------------- quadlets

def cfg(apps, **extra):
    return dict({"network": {"parent": "eth0", "subnet": "192.168.23.0/24", "gateway": "192.168.23.254"},
                 "apps": apps}, **extra)


def norm(c, scan=None):
    return q.quadlets_normalize(c, QD, scan or {})


def test_single_container_unit():
    r = norm(cfg({"web": {"ip": "192.168.23.50", "mac": "auto",
                          "containers": {"web": {"image": "nginx", "environment": {"A": "x$y%z", "B": True}}}}}))
    assert r["errors"] == []
    unit = next(f["content"] for f in r["files"] if f["path"].endswith("web/web.container"))
    assert "Network=macvlan.network:ip=192.168.23.50,mac=02:42:c0:a8:17:32\n" in unit
    assert 'Environment="A=x$$y%%z"\nEnvironment="B=true"\n' in unit
    assert unit.endswith("[Install]\nWantedBy=multi-user.target\n")


@pytest.mark.parametrize("apps,needle", [
    ({"a": {"ip": "192.168.24.1", "containers": {"a": {"image": "x"}}}}, "is not inside network subnet"),
    ({"a": {"ip": "192.168.23.254", "containers": {"a": {"image": "x"}}}}, "is the network gateway"),
    ({"a": {"ip": "192.168.23.5", "containers": {"a": {"image": "x"}}},
      "b": {"ip": "192.168.23.5", "containers": {"b": {"image": "x"}}}}, "is already used by a"),
    ({"a": {"mac": "03:00:00:00:00:01", "containers": {"a": {"image": "x"}}}}, "multicast"),
    ({"a": {"secrets": {"s": ""}, "containers": {"a": {"image": "x"}}}}, "refusing to replace"),
    ({"a": {"containers": {"x": {"image": "x", "Container": {"PublishPort": "80"}},
                           "y": {"image": "y"}}}}, "not allowed in a pod"),
    ({"a": {"image": "x", "containers": {"a": {"image": "x"}}}}, "is set per container"),
    ({"a": {"containers": {"a": {}}}}, "image is required"),
])
def test_validation(apps, needle):
    errors = norm(cfg(apps))["errors"]
    assert any(needle in e for e in errors), errors


def test_secret_values_only_in_top_level_list():
    r = norm(cfg({"a": {"secrets": {"pw": "hunter2"},
                        "containers": {"a": {"image": "x", "Container": {"Secret": "pw,type=env,target=PW"}}}}}))
    assert r["secrets"] == [{"name": "pw", "value": "hunter2", "app": "a"}]
    assert "hunter2" not in repr({k: v for k, v in r.items() if k != "secrets"})
    assert r["apps"][0]["containers"][0]["secrets"] == ["pw"]


def test_header_only_change_from_salt_marker():
    c = cfg({"a": {"containers": {"a": {"image": "x"}}}})
    path = QD["config_dir"] + "/a/a.container"
    ours = next(f for f in norm(c)["files"] if f["path"] == path)["content"]
    salt = DEFAULTS["quadlets_adopt_markers"][0] + ours[len(QD["marker"]):]
    scan = {"checksums": {path: hashlib.sha1(salt.encode()).hexdigest()},
            "adopt_markers": DEFAULTS["quadlets_adopt_markers"]}
    assert next(f for f in norm(c, scan)["files"] if f["path"] == path)["header_only"] is True
    scan["checksums"][path] = hashlib.sha1(b"something else").hexdigest()
    assert next(f for f in norm(c, scan)["files"] if f["path"] == path)["header_only"] is False


def test_clean_and_services():
    d = QD["config_dir"]
    c = cfg({"a": {"containers": {"x": {"image": "x"}, "y": {"image": "y"}}, "secrets": {"s": "v"}},
             "gone": {"absent": True, "secrets": {"t": "v"}, "containers": {"gone": {"image": "g"}}}})
    scan = {
        "config_entries": [
            {"path": f"{d}/old", "isdir": True},
            {"path": f"{d}/old/old.container", "isreg": True},
            {"path": f"{d}/manual", "isdir": True},
            {"path": f"{d}/manual/manual.container", "isreg": True},
        ],
        "config_marked": [f"{d}/old/old.container"],
    }
    r = norm(c, scan)
    assert r["errors"] == []
    clean = q.quadlets_clean(r, scan, {})
    assert [o["service"] for o in clean["orphans"]] == ["old.service"]
    assert clean["orphan_dirs"] == [f"{d}/old"]
    assert clean["secrets_rm"] == ["t"]

    pod = f"{d}/a/a.pod"
    actions = q.quadlets_services(r, changed_files=[pod])
    assert [(x["name"], x["state"]) for x in actions] == [
        ("macvlan-network.service", "started"),
        ("a-pod.service", "restarted"),
        ("a-x.service", "restarted"),
        ("a-y.service", "restarted"),
    ]
    c["apps"]["a"]["running"] = False
    actions = q.quadlets_services(norm(c, scan))
    assert [x["name"] for x in actions][1:] == ["a-x.service", "a-y.service", "a-pod.service"]
