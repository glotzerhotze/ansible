# acme_sh on rpi-02: the certificate for grafana. Account and Gandi DNS
# settings are the same as in server-01.sls; see acme_sh/defaults.yaml for
# all defaults.
acme_sh:
  email: tilo@klessen.cloud
  # version: '3.1.6'

  renewal:
    method: systemd        # systemd | cron | none

  # Settings shared by all certificates (merged into each one)
  cert_defaults:
    server: letsencrypt    # letsencrypt_test while you try things out
    keylength: ec-256
    challenge:
      method: dns
      provider: dns_gandi_livedns
    env:
      GANDI_LIVEDNS_TOKEN: {{ salt['onepassword.read']('op://infra/gandi/token') | yaml_squote }}

  certificates:

    # grafana web UI, served by haproxy in the grafana pod, which loads the
    # key from <crt>.key next to the certificate
    grafana.mgmt.gz.klessen.cloud:
     # absolute paths are used as given; null skips a file
      files:
        key: /var/lib/containers/storage/volumes/grafana-haproxy/_data/grafana.pem.key
        fullchain: /var/lib/containers/storage/volumes/grafana-haproxy/_data/grafana.pem
        cert: null
        ca: null
      # haproxy reads the certificate only at start
      reload_cmd: systemctl try-restart grafana-haproxy.service
