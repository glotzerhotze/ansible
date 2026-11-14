# NetworkManager profiles for rpi-02 (nm_connections formula)
# Addresses: pillar/ipam.yaml
{%- from 'ipam.jinja' import ip, ips, cidr %}
nm_connections:
  connections:

    # Management LAN - the interface Salt talks over, so never set activate here
    schnorchel-mgmt:
      settings:
        connection.type: ethernet
        connection.uuid: 97ea5a2e-7a51-312f-838e-bf402f666166
        connection.interface-name: eth0
        connection.autoconnect-priority: -999
        ipv4.method: manual
        ipv4.address1: {{ cidr('rpi-03', 'mgmt') }}
        ipv4.gateway: {{ ip('networks:mgmt:ipv4:gateway') }}
        ipv4.dns: {{ ips('dns') }}
        ipv4.dns-search: [mgmt.gz.klessen.cloud]
        ipv4.ignore-auto-dns: true
        ipv4.may-fail: false
        ipv6.method: auto
        ipv6.addr-gen-mode: default

    schnorchel-surfer:
      settings:
        connection.type: wifi
        connection.uuid: 698f5c45-9ed1-4fb0-83cb-2bc05e4c87df
        connection.interface-name: wlan0
        wifi.mode: infrastructure
        wifi.ssid: schnorchel-surfer
        wifi-security.key-mgmt: wpa-psk
        wifi-security.psk: {{ salt['onepassword.read']('op://infra/schnorchel-surfer/password') | yaml_dquote }}   # keep quoted
        ipv4.method: manual
        ipv4.address1: {{ cidr('rpi-03', 'surfer') }}
        ipv4.gateway: {{ ip('networks:surfer:ipv4:gateway') }}
        ipv4.dns: {{ ips('dns') }}
        ipv4.dns-search: [surfer.gz.klessen.cloud]
        ipv4.ignore-auto-dns: true
        ipv4.may-fail: false
        ipv6.method: auto
        ipv6.addr-gen-mode: default

    # macvlan shim so the host can reach containers on the macvlan network
    macvlan-shim:
      settings:
        connection.type: macvlan
        connection.uuid: 8c423272-6e8b-3528-ba1d-5c42f49a7ecc
        connection.interface-name: macvlan-shim
        macvlan.mode: 2              # bridge
        macvlan.parent: eth0
        ipv4.method: manual
        ipv4.address1: {{ ip('hosts:rpi-03:shim:ipv4') }}/32
        ipv4.route1: {{ ip('orphaned:rpi-03-route1') }}/32
        ipv6.method: auto
        ipv6.addr-gen-mode: default
