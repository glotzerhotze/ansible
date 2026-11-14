########################################################################
# Example pillar data for the write_environment formula.
#
# Each key under write_environment is an arbitrary identifier - it is
# only used to name the generated Salt states and to build the
# contents_pillar lookup path (write_environment:<name>:config).
#
# Supported keys per entry:
#   path        (required) - full path to the file to manage
#   enabled     (default: False) - True creates/updates the file,
#                                  False (or omitted) removes it
#   createpath  (default: False) - True creates the parent directory
#                                  if it does not already exist
#   owner       (default: root)
#   group       (default: root)
#   dir_mode    (default: '700')
#   file_mode   (default: '600')
#   config      - literal file contents (only needed when enabled: True)
#
# If write_environment is not present in pillar at all, the formula
# takes no action.
#
# IMPORTANT: always quote dir_mode/file_mode, e.g. dir_mode: '0755'.
# YAML 1.1 (what PyYAML/Salt parses) treats an unquoted leading-zero
# number as octal, so `file_mode: 0600` silently becomes the integer
# 384, not the string "0600" -- the file ends up with the wrong
# permissions instead of erroring. Quoting it as '0600' avoids this
# entirely.
########################################################################

write_environment:

  # haproxy in the grafana pod (pillar/quadlets/rpi-02.sls): TLS on 443 in
  # front of the web UI, plain http on 80 redirects to https. The
  # certificate grafana.pem and its key grafana.pem.key are put into the
  # same volume by the acme_sh formula (pillar/acme_sh/rpi-02.sls).
  grafana-haproxy:
    enabled: true
    path: /var/lib/containers/storage/volumes/grafana-haproxy/_data/haproxy.cfg
    createpath: true
    owner: root
    group: root
    dir_mode: '0755'
    file_mode: '0644'
    config: |
      # Mounted into the container at /usr/local/etc/haproxy/haproxy.cfg

      global
          log stdout format raw local0
          # started as root (User=root in the quadlet) to bind 80/443 and read
          # the key, then switches to the image's unprivileged user
          user haproxy
          group haproxy

      defaults
          mode http
          log global
          option httplog
          option forwardfor
          timeout connect 5s
          timeout http-request 10s
          timeout client 5m
          timeout server 5m
          # websocket for Grafana Live (dashboard updates)
          timeout tunnel 1h

      frontend http
          # IPv4 and IPv6; only redirects, keeping host, path and query
          bind [::]:80 v4v6
          http-request redirect scheme https code 301

      frontend https
          # IPv4 and IPv6; the key is loaded from <crt>.key
          bind [::]:443 v4v6 ssl crt /usr/local/etc/haproxy/grafana.pem alpn h2,http/1.1
          http-request set-header X-Forwarded-Proto https
          default_backend grafana

      backend grafana
          # GF_SERVER_HTTP_ADDR=127.0.0.1 in the same pod
          server grafana 127.0.0.1:3000
