# acme_sh on rpi-03: the certificate for Pi-hole. Account and Gandi DNS
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

    # Pi-hole web UI (FTL's own web server). FTL wants key and certificate
    # in one PEM file (webserver.tls.cert, /etc/pihole/tls.pem in the
    # pihole-etc volume), so reload_cmd builds it from acme.sh's copies and
    # no separate files are installed. FTL reads it only at start.
    ph-02.mgmt.gz.klessen.cloud:
      files:
        key: null
        cert: null
        ca: null
        fullchain: null
      reload_cmd: |
        pem=/var/lib/containers/storage/volumes/pihole-etc/_data/tls.pem
        umask 077
        cat "$CERT_FULLCHAIN_PATH" "$CERT_KEY_PATH" > "$pem.tmp"
        chown 1000:1000 "$pem.tmp"
        mv -f "$pem.tmp" "$pem"
        systemctl try-restart pihole.service
