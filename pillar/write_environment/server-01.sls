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

{%- from 'ipam.jinja' import ip %}

write_environment:

  # Fully-specified example: creates the file, creates the parent
  # directory if needed, and sets explicit owner/group/modes.
  registry-mirror:
    enabled: true
    path: /var/lib/containers/storage/volumes/registry-mirror-config/_data/config.yml
    createpath: true
    owner: root
    group: root
    dir_mode: '0755'
    file_mode: '0600'
    config: |
      # CNCF Distribution registry (registry:3) as a Docker Hub pull-through cache
      # Served at https://docker.klessen.cloud
      # Recipe: https://distribution.github.io/distribution/recipes/mirror/
      # Mounted into the container at /etc/distribution/config.yml

      version: 0.1

      log:
        level: info
        formatter: text
        fields:
          service: registry-mirror

      storage:
        # The recipe recommends the filesystem driver for a pull-through cache
        filesystem:
          rootdirectory: /var/lib/registry
        # Must be enabled, otherwise the scheduler cannot expire cached content (proxy.ttl)
        delete:
          enabled: true
        cache:
          blobdescriptor: inmemory
        maintenance:
          uploadpurging:
            enabled: true
            age: 168h
            interval: 24h
            dryrun: false

      http:
        addr: :443
        host: https://docker.klessen.cloud
        # http.secret is supplied via REGISTRY_HTTP_SECRET (see .env)
        headers:
          X-Content-Type-Options: [nosniff]
        tls:
          minimumtls: tls1.3
          #letsencrypt:
          #  cachefile: /var/lib/registry-acme/cache
          #  # Overridden by REGISTRY_HTTP_TLS_LETSENCRYPT_EMAIL (see .env)
          #  email: admin@klessen.cloud
          #  # Only issue certificates for this hostname (protects against bogus SNI)
          #  hosts: [docker.klessen.cloud]

      health:
        storagedriver:
          enabled: true
          interval: 10s
          threshold: 3

      proxy:
        # Only one upstream per registry instance; Docker daemon mirrors only support Docker Hub
        remoteurl: https://registry-1.docker.io
        # Docker Hub credentials are optional and supplied via
        # REGISTRY_PROXY_USERNAME / REGISTRY_PROXY_PASSWORD (see docker-compose.yml).
        # WARNING: any private image that account can see becomes pullable through this mirror.
        ttl: 168h

  # The paperless settings moved into pillar/quadlets/server-01.sls
  # (apps:paperless-ngx:containers:app:environment). This only removes the
  # old .env from the host; drop the entry once that has run.
  paperless-ngx:
    enabled: false
    path: /etc/containers/systemd/paperless-ngx/.env

  # haproxy in the paperless-ngx pod (pillar/quadlets/server-01.sls): TLS on
  # 443 in front of the web UI, plain http on 80 redirects to https. The
  # certificate paperless-ngx.pem and its key
  # paperless-ngx.pem.key are put into the same volume by the acme_sh formula
  # (pillar/acme_sh/server-01.sls).
  paperless-ngx-haproxy:
    enabled: true
    path: /var/lib/containers/storage/volumes/paperless-ngx-haproxy/_data/haproxy.cfg
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
          # websocket for the live status updates in the web UI
          timeout tunnel 1h

      frontend http
          # IPv4 and IPv6; only redirects, keeping host, path and query
          bind [::]:80 v4v6
          http-request redirect scheme https code 301

      frontend https
          # IPv4 and IPv6; the key is loaded from <crt>.key
          bind [::]:443 v4v6 ssl crt /usr/local/etc/haproxy/paperless-ngx.pem alpn h2,http/1.1
          http-request set-header X-Forwarded-Proto https
          default_backend paperless

      backend paperless
          # PAPERLESS_BIND_ADDR=127.0.0.1 in the same pod
          server app 127.0.0.1:8000

  # haproxy in the influxdb pod (pillar/quadlets/server-01.sls): TLS on 443
  # in front of the web UI and the API, plain http on 80 redirects to https.
  # The certificate influxdb.pem and its key influxdb.pem.key are put into
  # the same volume by the acme_sh formula (pillar/acme_sh/server-01.sls).
  influxdb-haproxy:
    enabled: true
    path: /var/lib/containers/storage/volumes/influxdb-haproxy/_data/haproxy.cfg
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
          # long-running Flux queries
          timeout client 5m
          timeout server 5m

      frontend http
          # IPv4 and IPv6; only redirects, keeping host, path and query
          bind [::]:80 v4v6
          http-request redirect scheme https code 301

      frontend https
          # IPv4 and IPv6; the key is loaded from <crt>.key
          bind [::]:443 v4v6 ssl crt /usr/local/etc/haproxy/influxdb.pem alpn h2,http/1.1
          http-request set-header X-Forwarded-Proto https
          default_backend influxdb

      backend influxdb
          # INFLUXD_HTTP_BIND_ADDRESS=127.0.0.1:8086 in the same pod
          server influxdb 127.0.0.1:8086

  # haproxy in the immich pod (pillar/quadlets/server-01.sls): TLS on 443 in
  # front of the web UI and the API the mobile apps use, plain http on 80
  # redirects to https. The certificate immich.pem and its key immich.pem.key
  # are put into the same volume by the acme_sh formula
  # (pillar/acme_sh/server-01.sls).
  immich-haproxy:
    enabled: true
    path: /var/lib/containers/storage/volumes/immich-haproxy/_data/haproxy.cfg
    createpath: true
    owner: '99'
    group: '99'
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
          # request headers only; upload bodies fall under timeout client
          timeout http-request 10s
          # large photo and video uploads and downloads (upstream's proxy
          # example uses 600s); haproxy sets no body size limit
          timeout client 10m
          timeout server 10m
          # websocket for the live updates in the web UI and the apps
          timeout tunnel 1h

      frontend http
          # IPv4 and IPv6; only redirects, keeping host, path and query
          bind [::]:80 v4v6
          http-request redirect scheme https code 301

      frontend https
          # IPv4 and IPv6; the key is loaded from <crt>.key
          bind [::]:443 v4v6 ssl crt /usr/local/etc/haproxy/immich.pem alpn h2,http/1.1
          http-request set-header X-Forwarded-Proto https
          default_backend immich

      backend immich
          # IMMICH_HOST=127.0.0.1 in the same pod
          server immich 127.0.0.1:2283
