# Environment of telegraf.service: the package's unit reads
# EnvironmentFile=-/etc/default/telegraf as root, so 0600 root:root is enough.
# Kept here rather than in pillar/write_environment/<host>.sls so every host
# with this pillar gets it. telegraf only reads it at start: restart
# telegraf.service after rotating the token.
write_environment:
  telegraf:
    enabled: true
    path: /etc/default/telegraf
    owner: root
    group: root
    file_mode: '0600'
    config: |
      # Managed by Salt (pillar/telegraf/linux-template.sls)
      INFLUX_TOKEN={{ salt['onepassword.read']('op://infra/influxdb/telegraf_token') | yaml_dquote }}
