# NetworkManager profiles for schnorchel (nm_connections formula)
# Addresses: pillar/ipam.yaml
{%- from 'ipam.jinja' import ip, ips, cidr %}

nm_connections:
  purge: true

  connections:

    schnorchel-mgmt:
      settings:
        connection.type: ethernet
        connection.uuid: c1c77320-1ecf-36e7-8d1f-eeac1c1a8b96
        connection.interface-name: enp0s31f6
        connection.autoconnect: true
        connection.autoconnect-priority: 100
        ipv4.method: manual
        ipv4.address1: {{ cidr('server-01', 'mgmt') }}
        ipv4.gateway: {{ ip('networks:mgmt:ipv4:gateway') }}
        ipv4.dns: {{ ips('dns') }}
        ipv4.dns-search: [mgmt.gz.klessen.cloud]
        ipv4.ignore-auto-dns: true
        ipv4.may-fail: false
        ipv6.method: auto
        ipv6.addr-gen-mode: default

#    schnorchel-iot:
#      settings:
#        connection.type: vlan
#        connection.uuid: 45b937da-1e50-4757-a386-04d14440ca42
#        connection.interface-name: enp0s31f6.30
#        vlan.parent: enp0s31f6
#        vlan.id: 30
#        vlan.flags: 1                # reorder headers (NM default)
#        ipv4.method: manual
#        ipv4.address1: {{ cidr('server-01', 'iot') }}
#        ipv4.gateway: {{ ip('networks:iot:ipv4:gateway') }}
#        ipv4.dns: {{ ips('dns') }}
#        ipv4.dns-search: [iot.gz.klessen.cloud]
#        ipv6.method: auto
#        ipv6.addr-gen-mode: default
#        ipv6.address1: {{ cidr('server-01', 'iot', 'ipv6') }}

    ## iot-vlan interface
    enp0s31f6vlan30:
      settings:
        connection.id: enp0s31f6.30
        connection.uuid: 070e9e86-7f77-471c-9e60-e67a70c97574
        connection.type: vlan
        connection.controller: br-iot
        connection.interface-name: enp0s31f6.30
        connection.port-type: bridge
        vlan.falgs: 1
        vlan.id: 30
        vlan.parent: enp0s31f6

    ## bridge for home-assistant so the VM can use the correct network
    bridge-br-iot:
      settings:
        connection.id: bridge-br-iot
        connection.uuid: 82912720-223c-4284-a81d-a111cbba5247
        connection.type: bridge
        connection.interface-name: br-iot
        ipv4.address1: {{ cidr('server-01', 'iot') }}
        ipv4.dns: {{ ips('dns') }}
        ipv4.method: manual
        ipv4.never-default: true
        ipv6.addr-gen-mode: default
        ipv6.method: auto

    # macvlan shim so the host can reach containers on the macvlan network
    macvlan-shim:
      settings:
        connection.type: macvlan
        connection.uuid: 8c423272-6e8b-3528-ba1d-5c42f49a7ecc
        connection.interface-name: macvlan-shim
        macvlan.mode: 2              # 2 = bridge
        macvlan.parent: enp0s31f6
        ipv4.method: manual
        ipv4.address1: {{ ip('hosts:server-01:shim:ipv4') }}/32
        ipv4.route1: {{ ip('hosts:server-01:apps:registry-mirror:ipv4') }}/32   # docker.klessen.cloud
        ipv4.route2: {{ ip('hosts:server-01:apps:registry:ipv4') }}/32          # hub.klessen.cloud
        ipv4.route3: {{ ip('hosts:server-01:apps:paperless-ngx:ipv4') }}/32     # paperless-ngx
        ipv4.route4: {{ ip('hosts:server-01:apps:influxdb:ipv4') }}/32          # influxdb
        ipv4.route5: {{ ip('hosts:server-01:apps:immich:ipv4') }}/32            # immich
        ipv6.method: auto
        ipv6.addr-gen-mode: default
        ipv6.ip6-privacy: 0
