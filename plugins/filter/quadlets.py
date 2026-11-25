# -*- coding: utf-8 -*-
"""
Filters for the quadlets role (roles/quadlets).

This is the Ansible port of salt/quadlets/map.jinja and clean.sls: it merges
the role defaults with the host's `quadlets` variable, validates everything,
renders the unit files and works out which services to start, restart or
stop. The tasks in roles/quadlets only execute the plan these filters return.

    quadlets_bind_sources(cfg)                  bind-mount sources to stat
    quadlets_normalize(cfg, defaults, scan)     unit files, secrets, pulls, errors
    quadlets_orphans(q, scan)                   unit files that left the config
    quadlets_clean(q, scan, orphan_services)    what to stop and remove
    quadlets_services(q, changed_files, changed_secrets)
                                                start/restart/stop actions

`scan` is what the role found on the host before (see tasks/scan.yml):

    config_entries   find result for config_dir (files and dirs, recursive)
    config_marked    paths of unit files in config_dir carrying a marker
    unit_marked      paths of .service/.timer files in systemd_dir with a marker
    unit_files       paths of .service/.timer files in systemd_dir
    unit_present     expected plain unit paths that exist as regular files
    regular_files    bind sources that exist as regular files

Errors never include secret values.
"""

from __future__ import annotations

import hashlib
import ipaddress
import json
import re
from collections.abc import Mapping
from numbers import Number

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
PLAIN_UNIT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]*\.(service|timer)$")
UNIT_FILE_RE = re.compile(r".*\.(container|volume|network|pod)$")
MAC_RE = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$", re.IGNORECASE)
SERVICE_NAME_RE = re.compile(r"(?m)^ServiceName=(\S+)")

APP_KEYS = [
    "description", "pod", "hostname", "ip", "ip6", "mac", "dns",
    "volumes", "secrets", "units", "containers", "running", "enabled",
    "absent", "purge_volumes", "restart_on_change",
]
CONTAINER_KEYS = [
    "image", "description", "container_name",
    "environment", "environment_files", "labels",
    "command", "entrypoint", "user", "group", "auto_update",
    "volumes", "pull",
]
# [Container] keys that belong to the pod once the containers share one
POD_OWNED_KEYS = ["Network", "IP", "IP6", "HostName", "DNS", "PublishPort", "Pod"]


# --------------------------------------------------------------------- helpers

def _s(value):
    """Jinja's `| string` / `~`: plain str() (None -> 'None')."""
    return str(value)


def _is_upper_key(key):
    return _s(key)[:1].isupper()


def _listify(value):
    """`[v] if v is string else (v or [])`"""
    if isinstance(value, str):
        return [value]
    return list(value or [])


def _plain(value):
    """A plain copy of dicts and lists. Ansible hands filters lazy containers
    that hold the templar; copying them with deepcopy drags that along."""
    if isinstance(value, Mapping):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    return value


def _merge(base, upd):
    """salt slsutil.merge(base, upd, merge_lists=False): deep-merge mappings,
    replace everything else, keep the key order of `base` and append new keys."""
    return _update(_plain(base or {}), upd or {})


def _update(dest, upd):
    for key, val in upd.items():
        sub = dest.get(key)
        if isinstance(sub, Mapping) and isinstance(val, Mapping):
            dest[key] = _update(sub, val)
        else:
            dest[key] = _plain(val)
    return dest


def _is_ipv(value, version):
    """salt's is_ipv4 / is_ipv6 tests: an address or address/prefix."""
    try:
        obj = ipaddress.ip_address(value)
    except ValueError:
        try:
            obj = ipaddress.ip_interface(value)
        except ValueError:
            return False
    return obj.version == version


def _in_subnet(addr, cidr):
    try:
        net = ipaddress.ip_network(cidr)
        return ipaddress.ip_address(addr) in net
    except ValueError:
        return False


def _add_pairs(pairs, data, errors, where):
    """Append `Key=value` pairs from a mapping; list values repeat the key."""
    if data is None:
        return
    if not isinstance(data, Mapping):
        errors.append(f"{where}: must be a mapping of unit keys to values")
        return
    for key, value in data.items():
        if isinstance(value, (str, Number, Mapping)):
            items = [value]
        elif value is None:
            items = []
        else:
            items = list(value)
        for item in items:
            if item is True:
                pairs.append([_s(key), "true"])
            elif item is False:
                pairs.append([_s(key), "false"])
            elif item is not None:
                pairs.append([_s(key), _s(item)])


def _merge_sections(sections, cfg, errors, where):
    """Capitalized keys of a config mapping are raw unit sections."""
    for key, value in cfg.items():
        if not _is_upper_key(key):
            continue
        sections.setdefault(key, [])
        _add_pairs(sections[key], value, errors, f"{where}:{key}")


def _kv_quote(key, value):
    """"KEY=value" quoted for Environment=/Label=; % and $ stay literal."""
    if value is True:
        value = "true"
    elif value is False:
        value = "false"
    text = (
        (_s(key) + "=" + _s(value))
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("%", "%%")
        .replace("$", "$$")
    )
    return f'"{text}"'


def render_unit(marker, sections):
    """The unit file text: marker line, then every non-empty section."""
    out = [marker]
    for name, pairs in sections:
        if not pairs:
            continue
        out.append("")
        out.append(f"[{name}]")
        out.extend(f"{k}={v}" for k, v in pairs)
    return "\n".join(out) + "\n"


def _json(value):
    try:
        return json.dumps(value)
    except TypeError:
        return _s(value)


# ------------------------------------------------------------------- normalize

def quadlets_bind_sources(cfg):
    """Absolute bind-mount sources of all containers (to stat them first)."""
    found = []
    apps = (cfg or {}).get("apps") or {}
    if not isinstance(apps, Mapping):
        return found
    for app in apps.values():
        if not isinstance(app, Mapping):
            continue
        containers = app.get("containers") or {}
        if not isinstance(containers, Mapping):
            continue
        for c in containers.values():
            mounts = c.get("volumes") if isinstance(c, Mapping) else None
            for m in mounts or []:
                if isinstance(m, Mapping) and m.get("source") and not m.get("volume"):
                    src = _s(m["source"])
                    if src.startswith("/") and src not in found:
                        found.append(src)
    return found


def quadlets_unit_paths(cfg, defaults):
    """Paths of the plain systemd units the apps declare (to stat them first)."""
    q = _merge(defaults, cfg or {})
    apps = q.get("apps") or {}
    if not isinstance(apps, Mapping):
        return []
    return [
        _s(q["systemd_dir"]) + "/" + _s(name)
        for app in apps.values() if isinstance(app, Mapping) and not app.get("absent")
        for name in (app.get("units") or {} if isinstance(app.get("units"), Mapping) else {})
    ]


def quadlets_normalize(cfg, defaults, scan=None):
    scan = scan or {}
    q = _merge(defaults, cfg or {})
    marker = _s(q.get("marker"))
    config_dir = _s(q["config_dir"])
    systemd_dir = _s(q["systemd_dir"])
    errors = []
    seen = {"ip": {}, "ip6": {}, "mac": {}, "service": {}, "secret": {}}

    def claim_service(service, owner):
        if service in seen["service"]:
            errors.append(f"{owner}: service {service} is already generated by {seen['service'][service]}")
        seen["service"][service] = owner

    regular_files = set(scan.get("regular_files") or [])
    unit_present = set(scan.get("unit_present") or [])
    unit_marked = set(scan.get("unit_marked") or [])
    config_marked = set(scan.get("config_marked") or [])

    # ------------------------------------------------------------- network
    net = q.get("network") or {}
    net_name = _s(net.get("name"))
    subnets = _listify(net.get("subnet"))
    gateways = _listify(net.get("gateway"))
    ip_ranges = _listify(net.get("ip_range"))

    if not NAME_RE.match(net_name):
        errors.append(f'network:name "{net_name}" is not a valid unit/network name')
    if not net.get("parent"):
        errors.append("network:parent is required (host interface the macvlan sits on, e.g. eth0)")
    if not subnets:
        errors.append("network:subnet is required (static IPs need a subnet)")

    net_pairs = [["NetworkName", net_name], ["Driver", _s(net.get("driver"))]]
    if net.get("parent"):
        net_pairs.append(["Options", "parent=" + _s(net["parent"])])
    if net.get("mode"):
        net_pairs.append(["Options", "mode=" + _s(net["mode"])])
    for key, value in (net.get("options") or {}).items():
        net_pairs.append(["Options", _s(key) + "=" + _s(value)])
    for s in subnets:
        net_pairs.append(["Subnet", _s(s)])
    for g in gateways:
        net_pairs.append(["Gateway", _s(g)])
    for r in ip_ranges:
        net_pairs.append(["IPRange", _s(r)])
    if net.get("ipv6"):
        net_pairs.append(["IPv6", "true"])

    net_sections = {"Unit": [], "Network": net_pairs}
    if "Description" not in (net.get("Unit") or {}):
        net_sections["Unit"].append(
            ["Description", _s(net.get("driver")) + " network " + net_name + " on " + _s(net.get("parent"))]
        )
    _merge_sections(net_sections, net, errors, "network")
    network = {
        "name": net_name,
        "rel": net_name + ".network",
        "file": config_dir + "/" + net_name + ".network",
        "service": _s((net.get("Network") or {}).get("ServiceName") or (net_name + "-network")) + ".service",
        "sections": list(net_sections.items()),
        "recreate_on_change": bool(net.get("recreate_on_change")),
    }
    expected = [network["rel"]]
    app_dirs = []
    expected_units = []
    seen["service"][network["service"]] = "network"

    # ---------------------------------------------------------------- apps
    apps_out = []
    absent_out = []
    secret_values = []
    raw_apps = q.get("apps") or {}
    if not isinstance(raw_apps, Mapping):
        errors.append("apps must be a mapping of app name to settings")
        raw_apps = {}

    for aname, raw_app in raw_apps.items():
        app_name = _s(aname)
        where = "apps:" + app_name
        a = raw_app or {}
        if not isinstance(a, Mapping):
            errors.append(f"{where}: settings must be a mapping")
            a = {}
        is_absent = bool(a.get("absent", False))
        app_dir = config_dir + "/" + app_name

        if not NAME_RE.match(app_name):
            errors.append(f'{where}: name may only contain letters, digits, ".", "_" and "-"')
        for key in a:
            if _is_upper_key(key) or key in APP_KEYS:
                continue
            if key in CONTAINER_KEYS:
                errors.append(f'{where}: "{key}" is set per container (apps:{app_name}:containers:<name>:{key})')
            else:
                errors.append(f'{where}: unknown option "{key}"')

        containers_raw = a.get("containers") or {}
        if not isinstance(containers_raw, Mapping):
            errors.append(f"{where}: containers must be a mapping of container name to settings")
            containers_raw = {}
        if not is_absent and not containers_raw:
            errors.append(f"{where}: at least one container is required")

        pod_opt = a.get("pod", "auto")
        if not (pod_opt is True or pod_opt is False or pod_opt == "auto"):
            errors.append(f"{where}: pod must be auto, true or false")
        use_pod = pod_opt is True or (pod_opt == "auto" and len(containers_raw) > 1)
        if not use_pod and len(containers_raw) > 1:
            errors.append(f"{where}: pod: false needs exactly one container (all containers of an app share its ip/mac)")
        if not use_pod:
            for key in a:
                if _is_upper_key(key):
                    errors.append(f'{where}: raw section "{key}" on the app only applies to a pod; put it under the container instead')

        # --- network attachment of the pod (or the single container)
        netopts = []
        ip = a.get("ip")
        if ip is not None:
            ip = _s(ip)
            if not _is_ipv(ip, 4):
                errors.append(f'{where}: ip "{ip}" is not a valid IPv4 address')
            else:
                hits = [s for s in subnets if _in_subnet(ip, _s(s))]
                if subnets and not hits:
                    errors.append(f"{where}: ip {ip} is not inside network subnet(s) " + ", ".join(_s(s) for s in subnets))
                if ip in [_s(g) for g in gateways]:
                    errors.append(f"{where}: ip {ip} is the network gateway")
                if not is_absent:
                    if ip in seen["ip"]:
                        errors.append(f"{where}: ip {ip} is already used by {seen['ip'][ip]}")
                    seen["ip"][ip] = app_name
            netopts.append("ip=" + ip)

        ip6 = a.get("ip6")
        if ip6 is not None:
            ip6 = _s(ip6)
            if not _is_ipv(ip6, 6):
                errors.append(f'{where}: ip6 "{ip6}" is not a valid IPv6 address')
            elif not is_absent:
                if ip6 in seen["ip6"]:
                    errors.append(f"{where}: ip6 {ip6} is already used by {seen['ip6'][ip6]}")
                seen["ip6"][ip6] = app_name
            netopts.append("ip6=" + ip6)

        mac = a.get("mac")
        if mac == "auto":
            if ip is not None and _is_ipv(ip, 4):
                o = [int(x) for x in ip.split("/")[0].split(".")]
                mac = "02:42:%02x:%02x:%02x:%02x" % tuple(o)
            else:
                errors.append(f'{where}: mac "auto" needs a valid ip to derive the address from')
                mac = None
        if mac is not None:
            if not isinstance(mac, str):
                errors.append(f"{where}: mac must be a quoted string (unquoted YAML may turn e.g. 12:34:56:00:11:22 into a number)")
            elif not MAC_RE.match(mac):
                errors.append(f'{where}: mac "{mac}" is not of the form 02:00:00:00:00:01')
            else:
                mac = mac.lower()
                if int(mac[:2], 16) % 2 == 1:
                    errors.append(f"{where}: mac {mac} is a multicast address (first octet must be even; use a locally administered x2/x6/xA/xE prefix)")
                if not is_absent:
                    if mac in seen["mac"]:
                        errors.append(f"{where}: mac {mac} is already used by {seen['mac'][mac]}")
                    seen["mac"][mac] = app_name
                netopts.append("mac=" + mac)

        network_spec = net_name + ".network" + ((":" + ",".join(netopts)) if netopts else "")
        hostname = a.get("hostname", app_name)
        dns = _listify(a.get("dns"))

        # --- named volumes, shared by every container of the app
        vols = {}
        vdefs = a.get("volumes") or {}
        if not isinstance(vdefs, Mapping):
            errors.append(f"{where}: volumes must be a mapping of volume name to settings (mounts go under containers:<name>:volumes)")
            vdefs = {}
        for vkey, vraw in vdefs.items():
            vname = _s(vkey)
            v = vraw or {}
            vwhere = where + ":volumes:" + vname
            if not NAME_RE.match(vname):
                errors.append(f"{vwhere}: volume name is invalid")
            if not isinstance(v, Mapping):
                errors.append(f"{vwhere}: settings must be a mapping")
                v = {}
            for key in v:
                if not _is_upper_key(key) and key != "volume_name":
                    errors.append(f'{vwhere}: unknown option "{key}" (raw keys go under Volume:/Unit:)')
            vunit = app_name + "-" + vname
            vol_name = _s(v.get("volume_name") or vunit)
            if not is_absent:
                claim_service(_s((v.get("Volume") or {}).get("ServiceName") or (vunit + "-volume")) + ".service", vwhere)
            vsections = {"Unit": [], "Volume": [["VolumeName", vol_name]]}
            if "Description" not in (v.get("Unit") or {}):
                vsections["Unit"].append(["Description", "Podman volume " + vol_name + " for " + app_name])
            _merge_sections(vsections, v, errors, vwhere)
            vols[vname] = {
                "name": vname,
                "unit": vunit,
                "rel": app_name + "/" + vunit + ".volume",
                "file": app_dir + "/" + vunit + ".volume",
                "volume_name": vol_name,
                "sections": list(vsections.items()),
            }

        # --- podman secrets (global names); values never go into an error
        secrets = []
        sdefs = a.get("secrets") or {}
        if not isinstance(sdefs, Mapping):
            errors.append(f"{where}: secrets must be a mapping of podman secret name to value")
            sdefs = {}
        for skey, sval in sdefs.items():
            sname = _s(skey)
            swhere = where + ":secrets:" + sname
            if not NAME_RE.match(sname):
                errors.append(f"{swhere}: secret name is invalid")
            if not is_absent:
                if not isinstance(sval, (str, Number)) or isinstance(sval, bool):
                    errors.append(f"{swhere}: value must be a string")
                elif _s(sval) == "":
                    errors.append(f"{swhere}: value is empty; refusing to replace the secret with an empty one")
                if sname in seen["secret"]:
                    errors.append(f"{swhere}: secret {sname} is already defined by {seen['secret'][sname]}")
                seen["secret"][sname] = where
            secrets.append({"name": sname, "value": _s(sval) if sval is not None else None})

        # --- plain systemd units (.service/.timer) that belong to the app
        units = []
        udefs = a.get("units") or {}
        if not isinstance(udefs, Mapping):
            errors.append(f"{where}: units must be a mapping of unit file name to sections")
            udefs = {}
        for ukey, uraw in udefs.items():
            uname = _s(ukey)
            u = uraw or {}
            uwhere = where + ":units:" + uname
            upath = systemd_dir + "/" + uname
            if not PLAIN_UNIT_RE.match(uname):
                errors.append(f"{uwhere}: unit name must end in .service or .timer")
            if not isinstance(u, Mapping):
                errors.append(f"{uwhere}: must be a mapping of sections (Unit:, Service:, Timer:, Install:)")
                u = {}
            for key in u:
                if not _is_upper_key(key):
                    errors.append(f'{uwhere}: unknown option "{key}" (only raw sections like Unit:/Service:/Timer:/Install: are allowed)')
            if not is_absent:
                claim_service(uname, uwhere)
                if upath in unit_present and upath not in unit_marked:
                    errors.append(f"{uwhere}: a hand-written {upath} already exists; remove it first")
            usections = {}
            _merge_sections(usections, u, errors, uwhere)
            units.append({
                "name": uname,
                "kind": uname.rsplit(".", 1)[-1],
                "file": upath,
                "has_install": "Install" in usections,
                "sections": list(usections.items()),
            })

        # --- pod
        pod = None
        if use_pod:
            pod_cfg = _merge(q.get("pod_defaults") or {}, a)
            ppairs = [["PodName", app_name], ["Network", network_spec]]
            # PodmanArgs instead of HostName=/DNS=, which older .pod units lack
            if hostname:
                ppairs.append(["PodmanArgs", "--hostname=" + _s(hostname)])
            for d in dns:
                ppairs.append(["PodmanArgs", "--dns=" + _s(d)])
            psections = {"Unit": [], "Pod": ppairs}
            if "Description" not in (pod_cfg.get("Unit") or {}):
                psections["Unit"].append(["Description", _s(a.get("description") or ("Podman pod " + app_name))])
            _merge_sections(psections, pod_cfg, errors, where)
            install = psections.pop("Install", None)
            if install and a.get("enabled", True):
                psections["Install"] = install
            pod = {
                "unit": app_name,
                "rel": app_name + "/" + app_name + ".pod",
                "file": app_dir + "/" + app_name + ".pod",
                "service": _s((pod_cfg.get("Pod") or {}).get("ServiceName") or (app_name + "-pod")) + ".service",
                "sections": list(psections.items()),
            }
            if not is_absent:
                claim_service(pod["service"], where)

        # --- containers
        containers = []
        for ckey, craw in containers_raw.items():
            cname = _s(ckey)
            cwhere = where + ":containers:" + cname
            if craw is not None and not isinstance(craw, Mapping):
                errors.append(f"{cwhere}: settings must be a mapping")
                craw = {}
            c = _merge(q.get("container_defaults") or {}, craw or {})
            stem = app_name if cname == app_name else app_name + "-" + cname

            if not NAME_RE.match(cname):
                errors.append(f'{cwhere}: name may only contain letters, digits, ".", "_" and "-"')
            for key in c:
                if _is_upper_key(key) or key in CONTAINER_KEYS:
                    continue
                if key in APP_KEYS:
                    errors.append(f'{cwhere}: "{key}" is set on the app (apps:{app_name}:{key}), not on a container')
                else:
                    errors.append(f'{cwhere}: unknown option "{key}" (raw unit keys go under Container:/Unit:/Service:/Install:)')
            if not is_absent and not c.get("image"):
                errors.append(f"{cwhere}: image is required")
            if use_pod:
                for key in (c.get("Container") or {}):
                    if key in POD_OWNED_KEYS:
                        errors.append(
                            f"{cwhere}: Container:{key} is not allowed in a pod; the pod owns network, hostname, "
                            f"DNS and ports (set them on the app or under apps:{app_name}:Pod:)"
                        )

            cpairs = [
                ["ContainerName", _s(c.get("container_name") or stem)],
                ["Image", _s(c.get("image") or "")],
            ]
            if use_pod:
                cpairs.append(["Pod", app_name + ".pod"])
            else:
                if hostname:
                    cpairs.append(["HostName", _s(hostname)])
                cpairs.append(["Network", network_spec])
                for d in dns:
                    cpairs.append(["DNS", _s(d)])
            for key, value in (c.get("environment") or {}).items():
                cpairs.append(["Environment", _kv_quote(key, value)])
            for f in _listify(c.get("environment_files")):
                cpairs.append(["EnvironmentFile", _s(f)])
            for key, value in (c.get("labels") or {}).items():
                cpairs.append(["Label", _kv_quote(key, value)])

            # --- mounts: app volume, host path (bind) or raw string
            uses = []
            bind_dirs = []
            for m in c.get("volumes") or []:
                if isinstance(m, str):
                    cpairs.append(["Volume", m])
                elif isinstance(m, Mapping):
                    target = m.get("target")
                    opts = m.get("options")
                    optstr = opts if isinstance(opts, str) else ",".join(_s(o) for o in (opts or []))
                    spec = None
                    if not target or not _s(target).startswith("/"):
                        errors.append(f"{cwhere}: every volume needs an absolute target (got {_json(m)})")
                    if m.get("name"):
                        errors.append(f'{cwhere}: volume {_json(m)} uses "name"; define it under apps:{app_name}:volumes and mount it with "volume:"')
                    elif m.get("volume") and m.get("source"):
                        errors.append(f"{cwhere}: volume {_json(m)} has both volume and source; use one")
                    elif m.get("volume"):
                        vref = _s(m["volume"])
                        if vref not in vols:
                            errors.append(f'{cwhere}: volume "{vref}" is not defined under apps:{app_name}:volumes')
                        else:
                            if all(x["name"] != vref for x in uses):
                                uses.append(vols[vref])
                            spec = vols[vref]["unit"] + ".volume:" + _s(target)
                    elif m.get("source"):
                        source = _s(m["source"])
                        if not source.startswith("/"):
                            errors.append(f'{cwhere}: bind source "{source}" must be an absolute path')
                        # Like salt's file.file_exists: only an existing
                        # regular file (a single bind-mounted file) is left
                        # alone; directories are ensured on every run.
                        if m.get("create", True) and source not in regular_files:
                            bind_dirs.append({
                                "path": source,
                                "user": m.get("user"),
                                "group": m.get("group"),
                                "mode": m.get("mode"),
                            })
                        spec = source + ":" + _s(target)
                    else:
                        errors.append(f"{cwhere}: volume {_json(m)} needs either volume (app volume) or source (host path)")
                    if spec:
                        cpairs.append(["Volume", spec + ((":" + optstr) if optstr else "")])
                else:
                    errors.append(f"{cwhere}: volumes entries must be strings or mappings")

            # --- app secrets this container references through Container:Secret
            suses = []
            for s in _listify((c.get("Container") or {}).get("Secret")):
                sref = _s(s).split(",")[0]
                if sref not in suses and any(sec["name"] == sref for sec in secrets):
                    suses.append(sref)

            if c.get("entrypoint"):
                cpairs.append(["Entrypoint", _s(c["entrypoint"])])
            if c.get("command"):
                cpairs.append(["Exec", _s(c["command"])])
            if c.get("user") is not None:
                cpairs.append(["User", _s(c["user"])])
            if c.get("group") is not None:
                cpairs.append(["Group", _s(c["group"])])
            if c.get("auto_update"):
                cpairs.append(["AutoUpdate", _s(c["auto_update"])])

            # --- sections: Unit, Container, raw sections..., Install last
            sections = {"Unit": [], "Container": cpairs}
            if "Description" not in (c.get("Unit") or {}):
                default_desc = a.get("description") if not use_pod else None
                sections["Unit"].append(["Description", _s(c.get("description") or default_desc or ("Podman container " + stem))])
            _merge_sections(sections, c, errors, cwhere)
            install = sections.pop("Install", None)
            if install and a.get("enabled", True):
                sections["Install"] = install

            image = _s(c.get("image") or "")
            container = {
                "name": cname,
                "unit": stem,
                "rel": app_name + "/" + stem + ".container",
                "file": app_dir + "/" + stem + ".container",
                "service": _s((c.get("Container") or {}).get("ServiceName") or stem) + ".service",
                "image": image,
                "pull": bool(
                    q.get("pull_images")
                    and c.get("pull", True)
                    and image
                    and not (image.endswith(".image") or image.endswith(".build"))
                ),
                "sections": list(sections.items()),
                "volumes": [x["name"] for x in uses],
                "secrets": suses,
                "bind_dirs": bind_dirs,
            }
            if not is_absent:
                claim_service(container["service"], cwhere)
            containers.append(container)

        app = {
            "name": app_name,
            "dir": app_dir,
            "pod": pod,
            "containers": containers,
            "volumes": list(vols.values()),
            # names only: secret values live in the top-level "secrets" list
            # alone, which only no_log tasks loop over
            "secrets": [s["name"] for s in secrets],
            "units": units,
            "running": bool(a.get("running", True)),
            "enabled": bool(a.get("enabled", True)),
            "purge_volumes": bool(a.get("purge_volumes", False)),
            "restart_on_change": bool(a.get("restart_on_change", True)),
        }
        if is_absent:
            absent_out.append(app)
        else:
            apps_out.append(app)
            secret_values.extend(dict(s, app=app_name) for s in secrets)
            app_dirs.append(app_name)
            if pod:
                expected.append(pod["rel"])
            for x in containers + app["volumes"]:
                expected.append(x["rel"])
            for u in units:
                expected_units.append(u["name"])

    # A hand-written unit with the same file name anywhere under config_dir
    # would collide with ours (quadlet unit names are global).
    expected_by_base = {rel.split("/")[-1]: rel for rel in expected}
    for path in sorted(_config_unit_files(scan, config_dir)):
        rel = path[len(config_dir) + 1:]
        base = rel.split("/")[-1]
        if base in expected_by_base and rel != expected_by_base[base] and path not in config_marked:
            errors.append(
                f"unit {base} would be written to {config_dir}/{expected_by_base[base]}, "
                f"but a hand-written {path} already exists; remove it first"
            )

    # ------------------------------------------------------- files to write
    # A file that differs from ours only in an adopted marker line (written
    # by the Salt formula) gets the new header, but that alone restarts
    # nothing and does not re-create the network.
    checksums = scan.get("checksums") or {}
    adopt_markers = [m for m in (scan.get("adopt_markers") or []) if m != marker]

    def unit_file(path, sections):
        content = render_unit(marker, sections)
        old = checksums.get(path)
        header_only = bool(old) and any(
            hashlib.sha1((m + content[len(marker):]).encode("utf-8")).hexdigest() == old
            for m in adopt_markers
        )
        return {"path": path, "content": content, "header_only": header_only}

    files = [unit_file(network["file"], network["sections"])]
    for app in apps_out:
        for v in app["volumes"]:
            files.append(unit_file(v["file"], v["sections"]))
        if app["pod"]:
            files.append(unit_file(app["pod"]["file"], app["pod"]["sections"]))
        for c in app["containers"]:
            files.append(unit_file(c["file"], c["sections"]))
        for u in app["units"]:
            files.append(unit_file(u["file"], u["sections"]))

    return {
        "settings": {k: v for k, v in q.items() if k not in ("apps",)},
        "marker": marker,
        "config_dir": config_dir,
        "systemd_dir": systemd_dir,
        "network": network,
        "apps": apps_out,
        "absent": absent_out,
        "expected": expected,
        "app_dirs": app_dirs,
        "expected_units": expected_units,
        "files": files,
        "bind_dirs": [d for app in apps_out for c in app["containers"] for d in c["bind_dirs"]],
        "secrets": secret_values,
        "pulls": [c["image"] for app in apps_out for c in app["containers"] if c["pull"]],
        "errors": errors,
    }


def _config_unit_files(scan, config_dir):
    """Regular unit files at most two levels below config_dir."""
    out = []
    for e in scan.get("config_entries") or []:
        path = e.get("path", "")
        if not e.get("isreg") or not path.startswith(config_dir + "/"):
            continue
        rel = path[len(config_dir) + 1:]
        if rel.count("/") <= 1 and UNIT_FILE_RE.match(rel.split("/")[-1]):
            out.append(path)
    return out


# ----------------------------------------------------------------------- clean

def quadlets_orphans(q, scan):
    """Unit files with one of our markers that are no longer expected."""
    config_dir = q["config_dir"]
    marked = set(scan.get("config_marked") or [])
    return [
        path for path in sorted(_config_unit_files(scan, config_dir))
        if path in marked and path[len(config_dir) + 1:] not in q["expected"]
    ]


def quadlets_clean(q, scan, service_names=None):
    """What clean.sls did: services to stop, files and dirs to remove,
    podman networks/secrets/volumes to drop. `service_names` maps orphan
    paths to the ServiceName= they declare (from grep)."""
    config_dir = q["config_dir"]
    service_names = service_names or {}
    orphans = []
    for path in quadlets_orphans(q, scan):
        rel = path[len(config_dir) + 1:]
        stem, kind = rel.split("/")[-1].rsplit(".", 1)
        svc = service_names.get(path)
        if svc:
            service = svc + ".service"
        elif kind == "container":
            service = stem + ".service"
        else:
            service = stem + "-" + kind + ".service"
        orphans.append({"path": path, "rel": rel, "stem": stem, "kind": kind, "service": service})
    orphan_paths = {o["path"] for o in orphans}

    entries = scan.get("config_entries") or []
    subdirs = sorted(
        e["path"] for e in entries
        if e.get("isdir") and e["path"].startswith(config_dir + "/")
        and "/" not in e["path"][len(config_dir) + 1:]
    )
    orphan_dirs = []
    for d in subdirs:
        files = [e["path"] for e in entries if e.get("isreg") and e["path"].startswith(d + "/")]
        if d.rsplit("/", 1)[-1] not in q["app_dirs"] and files and all(f in orphan_paths for f in files):
            orphan_dirs.append(d)

    systemd_dir = q["systemd_dir"]
    unit_marked = set(scan.get("unit_marked") or [])
    unit_orphans = []
    for path in sorted(scan.get("unit_files") or []):
        name = path.rsplit("/", 1)[-1]
        if path.rsplit("/", 1)[0] == systemd_dir and name not in q["expected_units"] and path in unit_marked:
            unit_orphans.append({"name": name, "path": path})

    secrets_rm = []
    volumes_rm = []
    for app in q["absent"]:
        secrets_rm.extend(app["secrets"])
        if app["purge_volumes"]:
            volumes_rm.extend(v["volume_name"] for v in app["volumes"])

    return {
        "orphans": orphans,
        "orphan_dirs": orphan_dirs,
        "networks_rm": [o["stem"] for o in orphans if o["kind"] == "network"],
        "unit_orphans": unit_orphans,
        "secrets_rm": secrets_rm,
        "volumes_rm": volumes_rm,
    }


def quadlets_service_names(grep_lines):
    """Parse `grep -rH ^ServiceName= dir` output into {path: first name}."""
    out = {}
    for line in grep_lines or []:
        path, sep, rest = line.partition(":")
        m = SERVICE_NAME_RE.match(rest) if sep else None
        if m and path not in out:
            out[path] = m.group(1)
    return out


# -------------------------------------------------------------------- services

def quadlets_services(q, changed_files=None, changed_secrets=None):
    """Ordered service actions, like the requisites in apps.sls/network.sls.

    Each item: {name, state, enabled}. state is started, restarted, stopped
    or None (only enable/disable); enabled is True/False or None (leave it).
    """
    changed_files = set(changed_files or [])
    changed_secrets = set(changed_secrets or [])
    actions = [{
        "name": q["network"]["service"],
        "state": "restarted" if q["network"]["file"] in changed_files else "started",
        "enabled": None,
    }]
    for app in q["apps"]:
        restart_ok = app["restart_on_change"]
        vol_files = {v["name"]: v["file"] for v in app["volumes"]}

        # Timers run with the app; other units with [Install] are only
        # enabled, since a timer or a dependency starts them.
        for u in app["units"]:
            if u["kind"] != "timer":
                if u["has_install"]:
                    actions.append({"name": u["name"], "state": None, "enabled": app["enabled"]})
                continue
            if app["running"]:
                state = "restarted" if (restart_ok and u["file"] in changed_files) else "started"
            else:
                state = "stopped"
            actions.append({"name": u["name"], "state": state, "enabled": app["enabled"] if u["has_install"] else None})

        def container_action(c, app=app, vol_files=vol_files, restart_ok=restart_ok):
            if not app["running"]:
                return {"name": c["service"], "state": "stopped", "enabled": None}
            watch = [c["file"]] + ([app["pod"]["file"]] if app["pod"] else []) + [vol_files[v] for v in c["volumes"]]
            changed = any(w in changed_files for w in watch) or any(s in changed_secrets for s in c["secrets"])
            return {"name": c["service"], "state": "restarted" if (restart_ok and changed) else "started", "enabled": None}

        # Running: pod first, then its containers. Stopped: containers first.
        if app["running"]:
            if app["pod"]:
                changed = app["pod"]["file"] in changed_files
                actions.append({"name": app["pod"]["service"], "state": "restarted" if (restart_ok and changed) else "started", "enabled": None})
            actions.extend(container_action(c) for c in app["containers"])
        else:
            actions.extend(container_action(c) for c in app["containers"])
            if app["pod"]:
                actions.append({"name": app["pod"]["service"], "state": "stopped", "enabled": None})
    return actions


class FilterModule:
    def filters(self):
        return {
            "quadlets_bind_sources": quadlets_bind_sources,
            "quadlets_unit_paths": quadlets_unit_paths,
            "quadlets_normalize": quadlets_normalize,
            "quadlets_orphans": quadlets_orphans,
            "quadlets_clean": quadlets_clean,
            "quadlets_service_names": quadlets_service_names,
            "quadlets_services": quadlets_services,
        }
