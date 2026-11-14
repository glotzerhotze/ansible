restic:
  # version: '0.19.1'
  client:

    paths:
      - /var/lib/containers/storage/volumes

    excludes: []

    schedule:
      method: systemd          # systemd | cron | none
      on_calendar: '*-*-* 02:00:00'
      randomized_delay: 300s

    # Optional: dump a database first (runs as the restic user)
    # pre_backup:
    #   - pg_dumpall > /var/lib/restic/data/postgres.sql

    # Optional: dead man's switch, best set per minion
    # heartbeat_url: https://hc-ping.com/<uuid>

    # The repository password is generated on each minion and copied to the
    # master (needs `file_recv: True` in /etc/salt/master). Alternatively set
    # it per minion in pillar:
    password: {{ salt['onepassword.read']('op://infra/restic-backup-passwords/' ~ grains['id']) | yaml_dquote }}
