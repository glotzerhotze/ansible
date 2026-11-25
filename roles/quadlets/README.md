# quadlets role

Ansible role that rolls out rootful [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) from the host's `quadlets` variable. A quadlet here is an **app**: one or more containers in their own directory `/etc/containers/systemd/<app>/`. An app with several containers runs them in a **pod**, so they share one network namespace (`localhost`). Every app is attached to one shared **macvlan** network with a configurable static **IP and MAC address**, and can use any number of **volumes** (named podman volumes shared by its containers, host directories, or raw `--volume` specs).

It is a port of the Salt formula `salt/quadlets`. For the same settings it writes byte-identical unit files apart from the header line. This was checked against Salt 3008.5 for all four hosts. The logic lives in `plugins/filter/quadlets.py`, and the tasks only carry out the plan it returns. Tests: `python -m pytest tests/`.

## Requirements

- Podman 5.0 or newer: `.pod` units and quadlets in subdirectories (Debian 13 ships 5.4)
- systemd with cgroup v2
- Rootful: macvlan with fixed addresses does not work rootless, so units go to `/etc/containers/systemd`

## Usage

```yaml
# site.yml
- hosts: all
  roles:
    - role: quadlets
      tags: [quadlets]
```

```sh
ansible-playbook site.yml --tags quadlets --limit rpi-02 --check --diff   # dry run
```

| Tasks file      | Does                                                                   |
| --------------- | ---------------------------------------------------------------------- |
| `main.yml`      | Everything below, in this order                                        |
| `prepare.yml`   | Resolves the settings (1Password reads happen once, here), scans the host, validates, renders |
| `clean.yml`     | Stops and removes apps that left the settings or are `absent: true`    |
| `apply.yml`     | App directories, bind dirs, unit files, secrets, image pulls           |
| `services.yml`  | One `daemon-reload`, network re-creation, then start/restart/stop      |

## Settings

One variable per host, `quadlets`, in `inventory/host_vars/<host>/quadlets.yml`. The four hosts there are complete, commented examples. Minimal:

```yaml
quadlets:
  network:
    name: lan
    parent: eth0
    subnet: 192.168.10.0/24
    gateway: 192.168.10.1
  apps:
    web:
      ip: 192.168.10.50
      mac: '02:42:c0:a8:0a:32'
      volumes:
        html: {}                     # podman volume "web-html"
      containers:
        web:
          image: docker.io/library/nginx:1.27
          volumes:
            - volume: html
              target: /usr/share/nginx/html
            - source: /srv/web/conf.d    # host dir, created if missing
              target: /etc/nginx/conf.d
              options: [ro, Z]
```

This writes `lan.network`, `web/web.container` and `web/web-html.volume` below `/etc/containers/systemd`, and runs `web.service` with container name `web` at 192.168.10.50 / 02:42:c0:a8:0a:32.

### `quadlets.network`

| Key                  | Default   | Meaning                                                                 |
| -------------------- | --------- | ----------------------------------------------------------------------- |
| `name`               | `macvlan` | Unit file `<name>.network`, podman network `<name>`, service `<name>-network.service` |
| `parent`             | required  | Host interface (`eth0`, `bond0.20`, …)                                  |
| `subnet`             | required  | CIDR, string or list (add an IPv6 subnet + `ipv6: true` for dual stack) |
| `gateway`            |           | String or list                                                          |
| `ip_range`           |           | Pool for apps without a static `ip`                                     |
| `mode`               |           | macvlan mode: `bridge`, `private`, `vepa`, `passthru`                   |
| `ipv6`               | `false`   |                                                                         |
| `options`            | `{}`      | Extra driver options, e.g. `mtu: 9000`                                  |
| `recreate_on_change` | `true`    | See *Network changes* below                                             |
| `Network`, `Unit`, … |           | Raw unit sections                                                       |

The network is shared by all apps, so its unit stays directly in `/etc/containers/systemd`.

### `quadlets.apps.<app>`

| Key             | Default   | Meaning                                                                     |
| --------------- | --------- | --------------------------------------------------------------------------- |
| `containers`    | required  | Mapping of container name to settings, see below                            |
| `pod`           | `auto`    | `auto`: a pod when there is more than one container. `true`: always. `false`: never (one container only) |
| `ip` / `ip6`    |           | Static address on the macvlan; must lie inside `subnet`                     |
| `mac`           |           | Static MAC, **quoted**. `auto` derives `02:42:<ip in hex>` from `ip`         |
| `hostname`      | `<app>`   |                                                                             |
| `dns`           |           | String or list                                                              |
| `description`   |           | `[Unit] Description=` of the pod, or of the single container               |
| `volumes`       | `{}`      | Named podman volumes of this app, see below                                 |
| `secrets`       | `{}`      | Podman secrets of this app, name → value, see below                         |
| `units`         | `{}`      | Plain systemd `.service`/`.timer` units of this app, see below              |
| `running`       | `true`    | `false` keeps the units but stops the services                              |
| `enabled`       | `true`    | `false` drops `[Install]`, so nothing starts at boot                        |
| `absent`        | `false`   | Stop the services and delete the app's units, directory, secrets and systemd units |
| `purge_volumes` | `false`   | With `absent`, also `podman volume rm` its named volumes                     |
| `restart_on_change` | `true` | `false`: changes are written, but the services are not restarted for them. For the control-node container, which a run must not restart under itself |
| `Pod`, `Unit`, `Service`, `Install` | | Raw sections of the `.pod` unit (pods only)                |

`ip`, `mac`, `hostname` and `dns` belong to the app: in a pod they are set on the pod (the containers share its network namespace), otherwise on the single container.

Unit names follow the app name. The pod is `<app>.pod` → `<app>-pod.service`, pod name `<app>`. A container with the same name as its app is `<app>.container` → `<app>.service`, every other one is `<app>-<container>.container` → `<app>-<container>.service`. Container names default to the unit name.

### `quadlets.apps.<app>.containers.<name>`

| Key                 | Default        | Meaning                                                             |
| ------------------- | -------------- | ------------------------------------------------------------------- |
| `image`             | required       | Fully qualified image (or a `.image`/`.build` quadlet reference)     |
| `container_name`    | unit name      | Podman container name                                               |
| `description`       |                | `[Unit] Description=`                                               |
| `environment`       | `{}`           | Mapping. Values are literal: `%` and `$` are escaped for systemd     |
| `environment_files` |                | String or list                                                      |
| `labels`            | `{}`           | Mapping                                                             |
| `command`           |                | `Exec=` (arguments after the image)                                 |
| `entrypoint`, `user`, `group`, `auto_update` | | Map to the Quadlet keys of the same name                  |
| `volumes`           | `[]`           | Mounts, see below                                                   |
| `pull`              | `true`         | Pre-pull the image during the run                                   |
| `Container`, `Unit`, `Service`, `Install`, `Quadlet` | | Raw unit sections, written as-is      |

`quadlets.container_defaults` is merged into every container. By default it sets `Restart=always`, `TimeoutStartSec=900` and `WantedBy=multi-user.target`. `quadlets.pod_defaults` does the same for pods (`WantedBy=multi-user.target`).

**Raw sections.** Any capitalized key is a unit section and its keys go into the file unchanged. A list value repeats the key:

```yaml
Container:
  AddCapability: [NET_ADMIN, SYS_NICE]
  Secret: db-pass,type=env,target=DB_PASS
Service:
  Restart: on-failure
```

In a pod, `Network`, `IP`, `IP6`, `HostName`, `DNS` and `PublishPort` are rejected under a container's `Container:`; set them on the app, or under the app's `Pod:`.

### Volumes

Named volumes are defined once per app and mounted by any of its containers:

```yaml
apps:
  app:
    volumes:
      # <app>-<name>.volume; the podman volume is called <app>-<name>
      # unless volume_name is set.
      data: {}
      legacy:
        volume_name: legacy-data      # adopt an existing podman volume
      share:
        Volume:                       # optional raw [Volume] keys
          Device: //nas/share
          Type: cifs
          Options: credentials=/etc/nas-cred
```

Each entry in a container's `volumes` is one of:

```yaml
volumes:
  # A volume of this app
  - volume: data
    target: /var/lib/app
    options: Z                    # string or list: ro, z, Z, U, ...

  # Host path (bind mount). Missing paths are created as directories;
  # existing files (e.g. /etc/localtime) are left alone.
  - source: /srv/app/config
    target: /config
    options: [ro, Z]
    create: true                  # default
    user: root                    # owner/mode for the created directory
    group: root
    mode: '0750'

  # Raw podman --volume spec, passed through unchanged
  - /etc/localtime:/etc/localtime:ro
  - other-app-data.volume:/shared   # share another app's named volume
```

### Secrets

Values come from the settings (in this repo: 1Password via the `op` lookup, `plugins/lookup/op.py`) and become podman secrets on the host. Containers use them with the regular `Secret=` key, so the value never ends up in a unit file:

```yaml
apps:
  pihole:
    secrets:
      pihole: "{{ lookup('op', 'op://infra/pihole/password') }}"
    containers:
      pihole:
        Container:
          Secret: pihole,type=env,target=FTLCONF_webserver_api_password
```

- The name is the podman secret name, which is global on the host, so it must be unique across apps.
- The value travels on stdin only, both for the comparison and for `podman secret create --replace <name> -`. It is never on a command line or in the environment, where `ps` and `-vvv` output would show it, and the tasks run with `no_log`. Within the role, secret values only exist in `_quadlets_plan.secrets`, which only `no_log` tasks loop over.
- The secret is only replaced when the stored value differs. Containers that reference it via `Container:Secret` are then restarted.
- Empty or non-string values are rejected, so a failed lookup never replaces a working secret with an empty one.
- Secrets are created only with `manage_services: true`. Removing an app (`absent: true`) removes its secrets. A secret that is only dropped from the settings stays on the host.
- The comparison also runs under `--check`, so a dry run shows which secrets would be replaced.

### Systemd units

Helper jobs that are not containers (downloads, backups, clean-ups) can be added as plain systemd units. Quadlet does not process `.service`/`.timer` files, so they are written to `systemd_dir` (`/etc/systemd/system`) with the role's header line:

```yaml
apps:
  unbound:
    units:
      unbound-root-hints.service:
        Unit:
          Requires: unbound-etc-volume.service
          After: unbound-etc-volume.service
        Service:
          Type: oneshot
          ExecStart: /usr/bin/curl --fail -o /var/lib/containers/storage/volumes/unbound-etc/_data/named.root https://www.internic.net/domain/named.root
      unbound-root-hints.timer:
        Timer:
          OnCalendar: daily
          Persistent: true
        Install:
          WantedBy: timers.target
    containers:
      unbound:
        Unit:                       # also run it before every container start
          Wants: unbound-root-hints.service
          After: unbound-root-hints.service
```

- Keys are the unit file names and must end in `.service` or `.timer`. The values hold only raw sections. A list value repeats the key, as for multiple `ExecStart=` lines in a oneshot.
- Timers follow the app: started with `running`, enabled with `enabled` (when they have `[Install]`). Services with `[Install]` are only enabled or disabled, never started, because a timer or a dependency starts them. Services without `[Install]` are just written.
- A hand-written unit with the same name in `systemd_dir` stops the run before anything changes. Units dropped from the settings, or belonging to an absent app, are stopped, disabled and deleted. Only files with the header line are touched.
- Unit names share the global namespace with the generated quadlet services, and clashes are rejected. A name that matches a distro unit (in `/usr/lib/systemd/system`) overrides it.

## Behaviour

- **No settings, no action.** A host without a `quadlets` variable skips the role, so it can run on every host. An empty `quadlets` mapping with `apps: {}` still runs the clean-up.

- **Validation.** Invalid settings stop the run with a list of every problem, before anything is changed. It checks for: missing image, unknown option (typo), app settings on a container and vice versa, IP outside the subnet or equal to the gateway, duplicate IP/MAC across apps, malformed or multicast MAC, unquoted MAC, mounts of undefined volumes, volumes without target or with relative paths, pod-owned keys on pod containers, clashing unit names, and a hand-written unit with the same file name elsewhere under `/etc/containers/systemd` (Quadlet unit names are global across subdirectories).
- **Changes** to a `.container` or `.volume` unit trigger one `daemon-reload` and a restart of the containers using it. A changed `.pod` restarts the pod and its containers.
- **Images** are pulled during the run, so a slow pull never hits the systemd start timeout and a typo fails the run.
- **Network changes.** Podman never updates an existing network from a changed `.network` unit. With `recreate_on_change` the role stops everything attached (systemd propagates the stop through `Requires=`), removes the podman network and starts everything again on the new network. This is skipped on the very first rollout, so a pre-existing network with the same name is never deleted.
- **Removal.** Deleting an app or a container from the settings, or setting `absent: true`, stops the services and deletes the unit files before any new container starts, so an IP or MAC can be reused in the same run. An app directory is deleted once nothing but such files is left in it. Only files with the role's header line (or the Salt formula's) are touched; hand-written quadlets are left alone. Named volume data is kept unless `purge_volumes: true`.
- **Check mode.** `--check --diff` shows the unit file diffs, which secrets differ and which images are missing. Services of apps that do not exist yet are reported but cannot be checked, because no `daemon-reload` happens in check mode.
- **Boot.** Quadlet services cannot be `systemctl enable`d. Boot start comes from the `[Install]` section that the generator applies. `enabled: false` removes it.

## Things to know about macvlan

- **The host cannot reach its own macvlan containers** through the parent interface, which is a kernel restriction. If the host needs access, give it a macvlan "shim" interface on the same parent, for example:

  ```sh
  ip link add lan-shim link eth0 type macvlan mode bridge
  ip addr add 192.168.10.254/32 dev lan-shim
  ip link set lan-shim up
  ip route add 192.168.10.48/28 dev lan-shim   # the container range
  ```

  Make this persistent with systemd-networkd or NetworkManager.
- Use **locally administered unicast MACs**: the first octet is `x2`, `x6`, `xA` or `xE`, for example `02:…`. Always quote them in YAML. Unquoted values like `12:34:56:00:11:22` become a base-60 number.
- Keep static IPs out of your DHCP server's pool, and out of `ip_range` if you set one.
- Some switches and Wi-Fi access points drop frames from multiple MACs on one port. On Wi-Fi, use `ipvlan` instead (`network: {driver: ipvlan}`); MACs then don't apply.
- Unit names are global. An app called `nginx` generates `nginx.service` and shadows a distro `nginx.service`.

## Differences from the Salt formula

- **Header line.** Unit files start with `# Managed by Ansible (quadlets role) - …`. Files with the Salt formula's header (`quadlets_adopt_markers`) count as the role's own. A file that differs from the new rendering only in that header line is rewritten without restarting anything or re-creating the network. Taking over a host from Salt therefore costs one `daemon-reload` and nothing else.
- **One variable per host.** Ansible does not deep-merge a host's `quadlets` with a `quadlets` from group_vars: the host's value replaces it. Keep each host's settings complete in `host_vars/<host>/quadlets.yml`. The role merges them onto `quadlets_defaults`, which works like the formula's `defaults.yaml`.
- **`restart_on_change`** is new (see the app table).
- **Bind directories** behave as in the formula: a source that exists as a regular file is left alone, and directories are ensured on every run, with owner and mode when set.
