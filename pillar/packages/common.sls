# -*- coding: utf-8 -*-
# vim: ft=yaml
---
packages:
  pkgs:
    # A dict of "package: version" pairs:
    held: []

    # Alternativelly, held packages can also be specified as a list with
    # no versions. In this case, the package will be held in the installed
    # version.
    # held:
    #   - alien
    #   - iotop

    wanted:
    - git
    - curl
    - wget
    - 1password-cli
    - tcpdump
    - jq
{%- if 'raspberry pi' in grains.get('productname', '') | lower %}
    # Signs the Raspberry Pi archive (raspian-trixie in pillar/apt/common.sls)
    - raspberrypi-archive-keyring
{%- endif %}
    unwanted: []
    required:
      pkgs: []

  retry_options:
    # https://docs.saltstack.com/en/latest/ref/states/requisites.html#retrying-states
    attempts: 5
    until: true
    interval: 30
    splay: 20
