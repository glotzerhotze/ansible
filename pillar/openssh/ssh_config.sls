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
# --- SSH client: /etc/ssh/ssh_config, also written by openssh.config.
# These are defaults for everyone on the host. Users can override any of them
# in ~/.ssh/config. Crypto is left at OpenSSH's defaults on purpose: a client
# always gets the strongest algorithm both sides support, so restricting the
# list only causes failures against old switches and appliances.
ssh_config:
  # The layout depends on how the formula's template writes this file:
  # Host blocks first (sorted, so '*' always comes first), then every other
  # option. That gives:
  #   Host *
  #       Include /etc/ssh/ssh_config.d/*.conf   <- drop-ins are read first
  #   <the options below>                        <- still inside Host *
  # ssh keeps the first value it finds, so drop-ins and ~/.ssh/config override
  # these defaults. That mirrors the Debian layout, and it keeps systemd's
  # 20-systemd-ssh-proxy.conf (ssh vsock/..., unix/...) working.
  # Rules for editing:
  #   * Put per-host exceptions (e.g. an old switch) in a drop-in file.
  #   * Don't add more Hosts entries; the options below would end up in the
  #     last one.
  #   * Don't set ConfigBanner. The template writes it into the file a second
  #     time as an option; the formula's `ssh -G` check then rejects the file
  #     and the state fails.
  Hosts:
    '*':
      Include: /etc/ssh/ssh_config.d/*.conf

  # Trust a new host's key on first connect, but refuse to connect if a
  # known host's key changes.
  StrictHostKeyChecking: accept-new
  # Hash known_hosts entries, so a compromised account doesn't reveal which
  # other hosts it connects to.
  HashKnownHosts: 'yes'
  # Give up on unreachable hosts after 15 s instead of about 2 minutes.
  ConnectTimeout: 15
  # Keep idle sessions alive through NAT/firewalls and close dead ones after
  # about 3 minutes.
  ServerAliveInterval: 60
  ServerAliveCountMax: 3
  # Skip Kerberos/GSSAPI, which adds DNS lookups and delay to every login.
  # Set 'yes' if you use Kerberos.
  GSSAPIAuthentication: 'no'
  # Send the locale and color hints; the server accepts them (AcceptEnv
  # above). Same list as Debian 13 ships.
  SendEnv: LANG LC_* COLORTERM NO_COLOR
