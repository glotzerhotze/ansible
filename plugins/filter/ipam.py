# -*- coding: utf-8 -*-
"""
Lookups into the fleet's IPAM data (the `ipam` variable, see
inventory/group_vars/all/ipam.yml). Port of pillar/ipam.jinja.

    {{ ipam | ipam_ip('hosts:rpi-01:apps:pihole:ipv4') }}   ->  192.168.23.3
    {{ ipam | ipam_ip('networks:mgmt:ipv4:gateway') }}      ->  192.168.23.254
    {{ ipam | ipam_ip('networks:mgmt:ipv4:subnet') }}       ->  192.168.23.0/24
    {{ ipam | ipam_cidr('rpi-01', 'mgmt') }}                ->  192.168.23.65/24
    {{ ipam | ipam_cidr('rpi-01', 'iot', 'ipv6') }}         ->  fd42:ac1d:feed:30::65/64
    {{ ipam | ipam_ips('dns') }}                            ->  ['192.168.23.3', '192.168.23.33']
    {{ ipam | ipam_mac('hosts:rpi-01:apps:pihole:mac') }}   ->  02:ac:1d:fe:ed:03

A path that does not exist or does not hold an address fails the run
instead of producing an empty value: an empty address on the mgmt profile
would cut a host off.
"""

from __future__ import annotations

import ipaddress
import re
from collections.abc import Mapping

from ansible.errors import AnsibleFilterError

MAC_RE = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$", re.IGNORECASE)


def _traverse(data, path):
    cur = data
    for part in str(path).split(":"):
        if isinstance(cur, Mapping) and part in cur:
            cur = cur[part]
        elif isinstance(cur, list) and part.lstrip("-").isdigit() and -len(cur) <= int(part) < len(cur):
            cur = cur[int(part)]
        else:
            return None
    return cur


def _is_ip(value):
    """An address or address/prefix (salt's is_ip)."""
    if not isinstance(value, str):
        return False
    for parse in (ipaddress.ip_address, ipaddress.ip_interface):
        try:
            parse(value)
            return True
        except ValueError:
            pass
    return False


def ipam_ip(ipam, path):
    value = _traverse(ipam, path)
    if not _is_ip(value):
        raise AnsibleFilterError(f'ipam: "{path}" is not an address in the ipam data')
    return value


def ipam_ips(ipam, path):
    values = _traverse(ipam, path)
    if not isinstance(values, list):
        raise AnsibleFilterError(f'ipam: "{path}" is not a list in the ipam data')
    for value in values:
        if not _is_ip(value):
            raise AnsibleFilterError(f'ipam: "{path}" has a non-address entry "{value}"')
    return list(values)


def ipam_mac(ipam, path):
    value = _traverse(ipam, path)
    if not isinstance(value, str) or not MAC_RE.match(value):
        raise AnsibleFilterError(f'ipam: "{path}" is not a MAC address (xx:xx:xx:xx:xx:xx) in the ipam data')
    return value


def ipam_cidr(ipam, host, net, family="ipv4"):
    key = f"hosts:{host}:{net}:{family}"
    addr = ipam_ip(ipam, key)
    subnet = ipam_ip(ipam, f"networks:{net}:{family}:subnet")
    try:
        network = ipaddress.ip_network(subnet, strict=False) if "/" in subnet else None
        inside = network is not None and ipaddress.ip_address(addr) in network
    except ValueError:
        inside = False
    if not inside:
        raise AnsibleFilterError(f"ipam: {key} ({addr}) is not inside networks:{net}:{family}:subnet ({subnet})")
    return f"{addr}/{subnet.split('/')[1]}"


class FilterModule:
    def filters(self):
        return {
            "ipam_ip": ipam_ip,
            "ipam_ips": ipam_ips,
            "ipam_mac": ipam_mac,
            "ipam_cidr": ipam_cidr,
        }
