# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Example pillar for the restic formula, together with the users formula
# and the openssh formula (saltstack-formulas/users-formula and
# saltstack-formulas/openssh-formula).
#
# Generate one key pair for the backups on the master:
#   ssh-keygen -N "" -t ed25519 -C restic@salt-master -f /root/restic_id_ed25519
# and paste it below. Keeping the private key in pillar (instead of
# salt://restic/id_ed25519 as in the original example) means only the
# minions that are targeted with this pillar can read it.
#
# Suggested pillar top.sls:
#   base:
#     '*':                       # every host that is backed up
#       - restic.client
#     'backup.example.com':      # the backup server
#       - restic.server
#
# Suggested state top.sls:
#   base:
#     '*':
#       - users
#       - openssh
#       - restic                 # = restic.client
#     'backup.example.com':
#       - restic.server
#
# Order on first rollout: apply the server first, so it accepts the key
# before the clients try to initialise their repositories.
#
# The two YAML documents below go into two separate pillar files. A host that
# is both server and client gets both; Salt merges them.
---

########################################################################
# pillar/restic/client.sls  (all backup clients)
########################################################################

users:
  restic:
    fullname: Restic Backup
    home: /var/lib/restic
    system: true
    createhome: true
    shell: /bin/bash
    user_dir_mode: '0750'
    # makes the users formula write ~/.ssh/id_ed25519
    ssh_key_type: ed25519
    ssh_keys:
      privkey: {{ salt['onepassword.read']('op://infra/restic-user/ssh-private-key') | yaml_dquote }}
      pubkey: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKk7+PQ7Hv3Qd7wsMc90NQ+R/lzeLUAW9NNrGZSeO+VK restic-server@homelab
    # Do NOT set `ssh_config` here: restic.client writes ~/.ssh/config.
    # (Or set restic:client:sftp:manage_ssh_config: false and do it here.)

restic:
  # version: '0.19.1'
  client:
    sftp:
      host: server-01.mgmt.gz.klessen.cloud
      # port: 22
      # With openssh.known_hosts from the openssh formula you can pin the
      # server key instead of trusting it on first use:
      # strict_host_key_checking: 'yes'

    forget:
      keep:
        last: 3
        daily: 7
        weekly: 4
        monthly: 6
