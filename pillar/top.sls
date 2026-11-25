{%- set minion_id  = grains['id'] %}
{%- set short_name = minion_id.split('.')[0] %}
{%- set full_name  = minion_id | replace('.', '_') %}

base:
  # Defaults for all minions
  '*':
    - apt.common
    - luks_lvm.{{ short_name }}
    - locale.common
    - local_grains.common
    - local_grains.{{ short_name }}
    - local_grains.{{ full_name }}
    - nm_connections.common
    - nm_connections.{{ short_name }}
    - users.tk
    - openssh.openssh
    - openssh.ssh_config
    - openssh.sshd_config
    - packages.common
    - packages.{{ short_name }}
    - write_environment.{{ short_name }}
    - write_environment.telegraf
    - acme_sh.{{ short_name }}
    - restic.client
    - restic.{{ short_name }}
    - samba.{{ short_name }}
    - telegraf.linux-template
    # Don't fail the pillar render if one of the files above doesn't exist
    - ignore_missing: True

  'server-01':
    - users.docs
    - restic.server
    - ignore_missing: True

## won't be used as we split in specific formulas
#  # Minion-specific pillar. Order matters: later files override earlier ones,
#  # so the most specific data (full minion ID) comes last.
#  '{{ minion_id }}':
#    - {{ minion_id }}
#    # Don't fail the pillar render if one of the files above doesn't exist
#    - ignore_missing: True
