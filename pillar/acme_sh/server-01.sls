# Example pillar for the acme_sh formula. Every key is optional except the
# certificates themselves; see acme_sh/defaults.yaml for all defaults.
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

    # Wildcard cert via Gandi Live DNS (method and credentials from
    # cert_defaults). Files land in /etc/ssl/acme/klessen.cloud/:
    # privkey.pem, cert.pem, chain.pem, fullchain.pem
    docker.klessen.cloud:
     # absolute paths are used as given; null skips a file
      files:
        key: /var/lib/containers/storage/volumes/registry-mirror-config/_data/docker.klessen.cloud.key
        fullchain: /var/lib/containers/storage/volumes/registry-mirror-config/_data/fullchain.cer
        cert: null
        ca: null
    hub.klessen.cloud:
     # absolute paths are used as given; null skips a file
      files:
        key: /var/lib/containers/storage/volumes/registry-config/_data/hub.klessen.cloud.key
        fullchain: /var/lib/containers/storage/volumes/registry-config/_data/fullchain.cer
        cert: null
        ca: null
    # paperless-ngx web UI, served by haproxy in the paperless-ngx pod, which
    # loads the key from <crt>.key next to the certificate
    paperless-ngx.mgmt.gz.klessen.cloud:
     # absolute paths are used as given; null skips a file
      files:
        key: /var/lib/containers/storage/volumes/paperless-ngx-haproxy/_data/paperless-ngx.pem.key
        fullchain: /var/lib/containers/storage/volumes/paperless-ngx-haproxy/_data/paperless-ngx.pem
        cert: null
        ca: null
      # haproxy reads the certificate only at start
      reload_cmd: systemctl try-restart paperless-ngx-haproxy.service
    # InfluxDB web UI and API, served by haproxy in the influxdb pod, which
    # loads the key from <crt>.key next to the certificate
    influxdb.mgmt.gz.klessen.cloud:
     # absolute paths are used as given; null skips a file
      files:
        key: /var/lib/containers/storage/volumes/influxdb-haproxy/_data/influxdb.pem.key
        fullchain: /var/lib/containers/storage/volumes/influxdb-haproxy/_data/influxdb.pem
        cert: null
        ca: null
      # haproxy reads the certificate only at start
      reload_cmd: systemctl try-restart influxdb-haproxy.service
    # Immich web UI and API, served by haproxy in the immich pod, which
    # loads the key from <crt>.key next to the certificate
    immich.mgmt.gz.klessen.cloud:
     # absolute paths are used as given; null skips a file
      files:
        key: /var/lib/containers/storage/volumes/immich-haproxy/_data/immich.pem.key
        fullchain: /var/lib/containers/storage/volumes/immich-haproxy/_data/immich.pem
        cert: null
        ca: null
      # haproxy reads the certificate only at start
      reload_cmd: systemctl try-restart immich-haproxy.service
