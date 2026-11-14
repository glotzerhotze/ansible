# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Pillar for greenaar/apt-formula (3pfs/apt-formula), a fork of
# saltstack-formulas/apt-formula. See its README.md and pillar.example.
# salt/top.sls applies apt.repositories, apt.apt_conf, apt.preferences and
# apt.unattended. apt.listchanges is not in top.sls, so the listchanges block
# below has no effect until it is added there.
---
apt:
  # Set the right keyring for the distro (ie ubuntu-keyring or ...)
  keyring_package: debian-archive-keyring

#  remove_apt_conf: true
#  clean_apt_conf_d: true

  # Empty /etc/apt/sources.list and delete every file in sources.list.d that
  # is not generated from `repositories` below (`unmanaged` entries are kept).
  remove_sources_list: true
  clean_sources_list_d: true

#  remove_preferences: true
#  clean_preferences_d: true

  keyrings_dir: '/etc/apt/keyrings'
  # Leave this off: the clean deletes every file no file state manages, which
  # includes the keys pkgrepo writes from key_url below.
#  clean_keyrings_d: true

  # Each entry becomes /etc/apt/apt.conf.d/<name>. Values must be mappings:
  # the formula's apt_conf.jinja iterates them with dictsort, so the list form
  # shown in the formula's README fails to render.
  apt_conf_d:
    30release:
      # The regex also covers stable-security and stable-updates. With a plain
      # "stable" they get priority 500 against stable's 990, so apt never
      # picks their newer versions.
      'APT::Default-Release': '/^stable(|-security|-updates)$/'
    '40dpkg-options':
      'Dpkg::Options':
      - '--force-confdef'
      - '--force-confold'
      DSelect:
        Clean: auto
        Options: -f
        UpdateOptions: ""
        PromptAfterUpdate: "no"

  unattended:
    allowed_origins: [ ]
    origins_patterns:
    - "origin=Debian,codename=${distro_codename},label=Debian"
    - "origin=Debian,codename=${distro_codename},label=Debian-Security"
    - "origin=Debian,codename=${distro_codename}-security,label=Debian-Security"
    - "origin=Debian,codename=${distro_codename}-updates,label=Debian"
    - "origin=Debian,codename=${distro_codename}-proposed-updates,label=Debian"
    - "origin=Debian,codename=${distro_codename}-backports,label=Debian Backports"
    package_blacklist: [ ]
    mail: root
    mail_report: only-on-error
    mail_only_on_error: false   # needed so mail_report is honoured
    remove_unused_dependencies: true
    automatic_reboot: false
    dpkg_options: "--force-confold"

  listchanges:
    profiles:
      cmdline:
        frontend: pager
      apt:
        frontend: pager
        email_address: root
        confirm: 1
#      custom:
#        frontend: browser
#        browser: mozilla

  # This replaces the default repositories from the formula's map.jinja
  # instead of merging with them (its README says merged, repositories.sls
  # does not), so every Debian suite has to be listed here.
  #
  # Third-party signing keys: with key_url and signed-by set, pkgrepo
  # downloads key_url into the signed-by file. Keep that file name ending in
  # .asc: Salt then stores the vendor's armored key as is, while any other
  # name makes it dearmor the key with gpg, which the minion may not have.
  # Nothing checks the key's hash or fingerprint.
  repositories:
    debian: &debian
      distro: trixie
      url: http://deb.debian.org/debian
      comps: [main, contrib, non-free, non-free-firmware]
      opts: "signed-by=/usr/share/keyrings/debian-archive-keyring.gpg"

    debian-updates:
      <<: *debian
      distro: trixie-updates

    debian-proposed-updates:
      <<: *debian
      distro: trixie-proposed-updates

    debian-backports:
      <<: *debian
      distro: trixie-backports

    debian-security:
      <<: *debian
      distro: trixie-security
      url: http://security.debian.org/debian-security

    influxdata:
      distro: stable
      url: https://repos.influxdata.com/debian/
      comps: [main]
      key_url: https://repos.influxdata.com/influxdata-archive.key
      opts: "signed-by=/etc/apt/keyrings/influxdata-archive.asc"

    # Left alone and excluded from the sources.list.d clean.
    salt:
      unmanaged: true
      filename: salt.sources

  {%- if 'raspberry pi' in grains.get('productname', '') | lower %}
    raspian-trixie:
      distro: trixie
      url: http://archive.raspberrypi.com/debian
      comps: [ main ]
      opts: "signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.pgp"

    1password:
      distro: stable
      url: https://downloads.1password.com/linux/debian/arm64
      comps: [ main ]
      key_url: https://downloads.1password.com/linux/keys/1password.asc
      opts: "signed-by=/etc/apt/keyrings/1password-archive-keyring.asc"

  {%- else %}
    1password:
      distro: stable
      url: https://downloads.1password.com/linux/debian/amd64
      comps: [ main ]
      key_url: https://downloads.1password.com/linux/keys/1password.asc
      opts: "signed-by=/etc/apt/keyrings/1password-archive-keyring.asc"

  {%- endif %}

  preferences:
#    00-rspamd:
#      package: rspamd
#      pin: origin rspamd.com
#      priority: 650
    01-all:
      pin: release stable
      priority: 610
#    02-all:
#      pin: release testing
#      priority: 600
#    03-all:
#      pin: release unstable
#      priority: 50
