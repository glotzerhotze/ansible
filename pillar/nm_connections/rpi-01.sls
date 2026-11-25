# NetworkManager profiles for schnorchel (nm_connections formula)
# Addresses: pillar/ipam.yaml
{%- from 'ipam.jinja' import ip, ips, cidr %}

nm_connections:
  connections:

    schnorchel-mgmt:
      settings:
        connection.type: ethernet
        connection.uuid: c1c77320-1ecf-36e7-8d1f-eeac1c1a8b96
        connection.interface-name: eth0
        connection.autoconnect-priority: -999
        ipv4.method: manual
        ipv4.address1: {{ cidr('rpi-01', 'mgmt') }}
        ipv4.gateway: {{ ip('networks:mgmt:ipv4:gateway') }}
        ipv4.dns: {{ ips('dns') }}
        ipv4.dns-search: [mgmt.gz.klessen.cloud]
        ipv4.ignore-auto-dns: true
        ipv4.may-fail: false
        ipv6.method: auto
        ipv6.addr-gen-mode: default

    schnorchel-iot:
      settings:
        connection.type: vlan
        connection.uuid: 45b937da-1e50-4757-a386-04d14440ca42
        connection.interface-name: eth0.30
        vlan.parent: eth0
        vlan.id: 30
        vlan.flags: 1                # reorder headers (NM default)
        ipv4.method: manual
        ipv4.address1: {{ cidr('rpi-01', 'iot') }}
        ipv4.gateway: {{ ip('networks:iot:ipv4:gateway') }}
        ipv4.dns: {{ ips('dns') }}
        ipv4.dns-search: [iot.gz.klessen.cloud]
        ipv6.method: disabled
        ipv6.addr-gen-mode: default
        ipv6.address1: {{ cidr('rpi-01', 'iot', 'ipv6') }}

    schnorchel-surfer:
      settings:
        connection.type: wifi
        connection.uuid: d9ee17bc-0921-4c52-951c-6821df2ff641
        connection.interface-name: wlan0
        wifi.mode: infrastructure
        wifi.ssid: schnorchel-surfer
        wifi-security.key-mgmt: wpa-psk
        wifi-security.psk: {{ salt['onepassword.read']('op://infra/schnorchel-surfer/password') | yaml_dquote }}   # keep quoted
        ipv4.method: manual
        ipv4.address1: {{ cidr('rpi-01', 'surfer') }}
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
        macvlan.mode: 2              # 2 = bridge
        macvlan.parent: eth0
        ipv4.method: manual
        ipv4.address1: {{ ip('hosts:rpi-01:shim:ipv4') }}/32
        ipv4.route1: {{ ip('hosts:rpi-01:apps:pihole:ipv4') }}/32       # ph-01.mgmt.klessen.cloud
        ipv4.route2: {{ ip('hosts:rpi-01:apps:unbound:ipv4') }}/32      # unbound-01
        ipv4.route3: {{ ip('hosts:rpi-01:apps:ansible-controller:ipv4') }}/32  # Ansible control node
        ipv4.route4: {{ ip('hosts:rpi-01:apps:salt-master:ipv4') }}/32  # salt-master.klessen.cloud
        ipv6.method: auto
        ipv6.addr-gen-mode: default
        ipv6.ip6-privacy: 0
