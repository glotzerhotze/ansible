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
sshd_config:
  ConfigBanner: |
    # Managed by Salt (openssh-formula). Local edits will be overwritten.
    # /etc/ssh/sshd_config.d/ is NOT included on purpose, so neither packages
    # nor cloud-init (e.g. 50-cloud-init.conf turning passwords back on)
    # can override what is set here.
  # (This fork would write `Include` as the first line if you set it here.
  # Leaving it unset is what keeps drop-ins out.)

  # --- Host keys: Ed25519 first, RSA for older clients. No ECDSA, no DSA.
  HostKey:
    - /etc/ssh/ssh_host_ed25519_key
    - /etc/ssh/ssh_host_rsa_key

  # --- Logging. VERBOSE logs the fingerprint of the key used for each login.
  LogLevel: VERBOSE

  # --- Authentication: public keys only, no root.
  # Proxmox VE nodes need root key logins between cluster members; use
  # 'prohibit-password' there.
  PermitRootLogin: 'prohibit-password'
  PubkeyAuthentication: 'yes'
  AuthenticationMethods: publickey
  PasswordAuthentication: 'no'
  KbdInteractiveAuthentication: 'no'
  GSSAPIAuthentication: 'no'
  AuthorizedKeysFile: .ssh/authorized_keys
  # Keep PAM for account and session handling (expiry/locks, limits,
  # systemd-logind, pam_motd). Debian ships this too.
  UsePAM: 'yes'

  # --- Brute-force and DoS limits.
  LoginGraceTime: 30
  # Each key the client's agent offers counts as one try. Clients that hold
  # many keys should use IdentitiesOnly/IdentityFile.
  MaxAuthTries: 4
  MaxStartups: '10:30:60'  # must be quoted: YAML 1.1 reads a:b:c as base 60
  # Close connections whose client has gone away after about 15 minutes.
  ClientAliveInterval: 300
  ClientAliveCountMax: 3

  # --- Forwarding. ProxyJump, -L and -D still work. -R, the agent and X11
  # do not. To hop through a bastion, use `ssh -J bastion host`; it doesn't
  # need agent forwarding.
  AllowTcpForwarding: local
  AllowAgentForwarding: 'no'
  X11Forwarding: 'no'

  # --- Misc.
  UseDNS: 'no'
  PrintMotd: 'no'  # pam_motd already shows it; same as Debian ships
  # Locale and terminal color hints, same list as Debian 13 ships.
  AcceptEnv: LANG LC_* COLORTERM NO_COLOR
  # Built into sshd, so the openssh-sftp-server package isn't needed, and it
  # works with chroot.
  Subsystem: sftp internal-sftp
  # Drop the Debian revision from the version string. Trade-off: scanners
  # that only look from the network can then no longer see Debian's
  # backported fixes and report false positives. Delete this line if you
  # scan that way.
  DebianBanner: 'no'

  # --- Crypto. These lines remove weak algorithms from OpenSSH's built-in
  # defaults instead of listing the allowed ones. A fixed list breaks
  # `sshd -t` on any version that doesn't know one of its names, and it would
  # freeze out newer defaults such as the ML-KEM post-quantum key exchange.
  #   KEX:     drop finite-field DH. Debian 13's OpenSSH 10 already does that
  #            on its own, so this matters on Debian 12. Keeps the mlkem and
  #            sntrup hybrids, curve25519 and NIST ECDH. NIST ECDH stays
  #            because it is the only option left for FIPS-mode clients and
  #            old Java/Python SSH libraries. ssh-audit will flag it. If you
  #            have no such clients, append ',ecdh-sha2-nistp*' to the list.
  #   MACs:    keep only encrypt-then-MAC with SHA-2 or UMAC-128. This drops
  #            SHA-1, 64-bit tags and encrypt-and-MAC. Paramiko 2.7+, PuTTY
  #            and Go handle it fine.
  #   Ciphers: the default set is already AEAD/CTR only, so nothing to drop.
  KexAlgorithms: '-diffie-hellman-group*'
  MACs: '-hmac-sha1*,umac-64*,hmac-sha2-256,umac-128@openssh.com'

  # --- added to allow brother scanner to upload via ssh
  # Brother uses a really old openssh client on their hardware :-/
  HostKeyAlgorithms: '+ssh-rsa'
  PubkeyAcceptedAlgorithms: '+ssh-rsa'

  # --- Who may log in. This is the best extra control you can add, but turn
  # it on only after the group exists everywhere and every admin is in it.
  # Otherwise it locks everyone out.
  # AllowGroups:
  #   - ssh-users

  # --- Optional: SFTP-only accounts, jailed to their home directory. The
  # chroot directory must be owned by root and not writable by group/others.
  # matches:
  #   sftp_only:
  #     type:
  #       Group: sftp-only
  #     options:
  #       ChrootDirectory: '%h'
  #       ForceCommand: internal-sftp
  #       AllowTcpForwarding: 'no'
  #       PermitTTY: 'no'
