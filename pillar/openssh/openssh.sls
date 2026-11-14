# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Pillar for greenaar/openssh-formula (Debian 12/13, Ubuntu 24.04+): a
# key-only, hardened sshd plus conservative SSH client defaults.
#
# Wire-up:
#   pillar/top.sls   base: {'*': [openssh]}
#   salt/top.sls     base: {'*': [openssh.config]}   # includes `openssh`
#                    (+ openssh.auth_map if you enable it below)
#
# Before rolling out:
#   * every admin needs a working key on the target hosts, because password
#     and root logins are disabled here;
#   * run `state.apply openssh.config test=True` first and keep an SSH session
#     open while it applies. The formula checks both files before writing
#     them (`sshd -t` for the server, `ssh -G` for the client), and
#     restarting sshd does not drop open sessions.
---
openssh:
  sshd_enable: true
  # Don't set server_version/client_version: latest (this fork's example
  # does), or every highstate becomes an upgrade. Let your normal patching
  # update openssh.

  # Create the host keys listed in HostKey below if they are missing. This
  # does nothing when the package has already made them, and it never replaces
  # an existing key, so host fingerprints stay the same. ECDSA keys stay on
  # disk but are not offered.
  generate_ed25519_keys: true
  generate_rsa_keys: true
  generate_rsa_size: 4096

  # Login banner: this fork's `openssh.banner` writes a "fancy" banner by
  # default, with hostname, internal IP, distro and hardware. sshd shows a
  # banner before login, so anyone who can reach port 22 can read it. It is
  # off here (no `Banner` in sshd_config). To turn it on, add
  # `Banner: /etc/ssh/banner` under sshd_config and apply `openssh.banner`.
  # On internet-facing hosts, use the short version instead:
  fancy_banner: true

  # Authorized keys: put each key in salt://ssh_keys/<name>.pub and add
  # `openssh.auth_map` to the state top. The users must already exist.
  # auth_map:
  #   admins:
  #     source: salt://ssh_keys
  #     users:
  #       alice:
  #         alice.laptop: {}
  #         alice.old-laptop:
  #           present: false
