# AGENTS.md

Configuration for a small home fleet (Debian trixie hosts and Raspberry Pis),
in the middle of a move from Salt to Ansible (MIGRATION.md has the status
table). Each formula is managed by exactly one of them: what is in
`salt/top.sls` is Salt's, what is in `site.yml` is Ansible's. The Ansible part
is described in its own section below; everything else here is about Salt.

Salt states, pillar, reactor and master config for the fleet. The master is a SaltGUI build of
[cdalvaro/docker-salt-master](https://github.com/cdalvaro/docker-salt-master),
running under Podman on rpi-01 (`192.168.23.65`) as the container
`salt-master-app` in the pod `salt-master` (systemd unit `salt-master-pod`),
with haproxy in front of SaltGUI. The pod is itself a quadlet, managed by
Ansible from `inventory/host_vars/rpi-01/quadlets.yml`. Nothing in this repo runs locally. You edit
files here, then `scripts/deploy.sh` rsyncs them into the container's volumes.

## Layout and where it lands in the container

| Repo path   | Host volume (`/var/lib/containers/storage/volumes/…`) | Container path                  | Purpose |
|-------------|-------------------------------------------------------|---------------------------------|---------|
| `salt/`     | `salt-master-srv/_data/salt`                          | `/home/salt/data/srv/salt`      | State tree (`file_roots` base) |
| `pillar/`   | `salt-master-srv/_data/pillar`                        | `/home/salt/data/srv/pillar`    | Pillar tree (`pillar_roots` base) |
| `reactor/`  | `salt-master-srv/_data/reactor`                       | `/home/salt/data/srv/reactor`   | Reactor SLS, referenced by absolute path |
| `modules/`  | `salt-master-srv/_data/modules`                       | `/home/salt/data/srv/modules`   | Master-side custom modules (`module_dirs`) |
| `config/*`  | `salt-master-config/_data`                            | `/home/salt/data/config`        | Master `*.conf` drop-ins, auto-included |
| `3pfs/*`    | `salt-master-3pfs/_data`                              | `/home/salt/data/3pfs`          | Third-party formulas, git submodules |

Container conventions to follow:

- `SALT_BASE_DIR` defaults to `/home/salt/data/srv`, and the container expects
  `salt/` and `pillar/` directly under it. Keep that structure.
- Each subdirectory of `/home/salt/data/3pfs/` is added to `file_roots` **when
  the container starts**. So `3pfs/apt-formula/apt` is served as `salt://apt`.
  New formulas only show up after a restart or after running
  `entrypoint.sh app:reload-3rd-formulas` inside the container.
- Every `*.conf` file in `config/` is included by the master. Name new files
  with a numeric prefix (`NN-topic.conf`) so their load order stays explicit.
- Paths inside config and reactor files are **container** paths
  (`/home/salt/data/...`), never host or macOS paths.
- The salt-api user is `saltgui`, which SaltGUI logs in with. It is set as
  `SALT_API_USER` in `inventory/host_vars/rpi-01/quadlets.yml` and must match
  `external_auth` in `config/20-salt-api.conf`. The password comes from
  1Password and reaches the container as the podman secret `salt-api-pass`.
  Never put the password itself here.
- Keys (`/home/salt/data/keys`) and logs (`/home/salt/data/logs`) are not
  managed here.

## Directory guide

- `salt/top.sls`: the highstate. Every minion gets `local_grains`, `users`,
  `apt.*`, `packages` and `nm_connections`.
  `packages.backports_kernel` is skipped on Raspberry Pis (checked with
  `grains['productname']`).
- `salt/<formula>/`: in-house formulas.
  - `local_grains`: writes `pillar:local_grains` into grains, then refreshes
    grains.
  - `nm_connections`: manages NetworkManager keyfiles. Its `README.md`
    documents the pillar schema.
  - `packages/backports_kernel.sls`: extends the upstream `packages` formula.
- `pillar/top.sls`: every minion gets `<formula>.common`, plus per-host files
  named `<formula>.<short_name>` and `<formula>.<minion_id with . → _>`. It uses
  `ignore_missing: True`, so a missing per-host file is fine. A **misnamed**
  file is silently ignored too, so double-check file names.
- `pillar/<formula>/`: one directory per formula, named after the formula's
  top-level pillar key.
- `pillar/apt/common.sls`: pillar for the greenaar apt formula in
  `3pfs/apt-formula`. Third-party signing keys are set per repository with
  `key_url`. Keep the `signed-by` file name ending in `.asc`, so Salt stores
  the armored key without needing `gpg`.
- `pillar/ipam.yaml`: every fleet IP and MAC address (subnets, gateways,
  host interfaces, macvlan shims, container IPs and MACs, DNS servers).
  Pillar files look addresses up with the macros in `pillar/ipam.jinja`
  (`ip`, `ips`, `cidr`, `mac`) instead of hard-coding them. A lookup that
  misses fails the pillar render.
  Neither file is in `top.sls`; they are only imported.
- `reactor/local_grains.sls`: wired up in `config/10-reactor.conf`. It runs
  `state.apply local_grains` on a minion at `salt/minion/*/start` and on the
  custom event `custom/grains/sync`.
- `modules/modules/`: custom execution modules that run on the **master**.
  `config/50-modules.conf` points `module_dirs` at `/home/salt/data/srv/modules`,
  and Salt looks for a `modules/` subdirectory inside it, which is why the
  path is doubled. Currently this holds `onepassword.py` (see Secrets).
  Changes take effect after a master restart. These modules are not synced
  to minions; minion-side modules would go in `salt/_modules/`.
- `config/`: master drop-ins.
  - `10-reactor.conf`: reactor wiring.
  - `20-salt-api.conf`: PAM `external_auth` for `saltgui`,
    `netapi_enable_clients`, and salt-api on `127.0.0.1:8000` behind the
    pod's haproxy.
  - `30-gitfs.conf`: gitfs, currently disabled.
  - `40-onepassword.conf`: settings for the `onepassword` module.
  - `50-modules.conf`: `module_dirs`.
  - `onepassword.token`: the 1Password service account token. It is
    gitignored, but **it is deployed** with `config/*`.
- `3pfs/`: upstream `saltstack-formulas` repos as git submodules. **Do not
  edit them.** Adjust behaviour through pillar, or add a wrapper state under
  `salt/`. `3pfs/salt-bootstrap` is excluded from deploy.
- `scripts/deploy.sh`: rsyncs everything above to the master with
  `--delete`, then restarts it. The local tree is the source of truth: a file
  deleted here also disappears on the master.
- `renovate.json`, `.github/workflows/renovate.yml`: Renovate runs weekly on
  GitHub and opens pull requests for newer image tags in
  `inventory/host_vars/*/quadlets.yml` and for the control-node image's
  dependencies in `control-node/`. Every `<name>_version: "<tag>"` in the
  quadlet settings needs a `# renovate: depName=<image>` comment directly above
  it, so add one for each new image. Merging such a PR deploys nothing.

## Ansible

Runs in the control-node container `ansible-controller` on rpi-01 (a quadlet
of itself, see MIGRATION.md). You edit files here, `scripts/ansible-sync.sh`
rsyncs the tree into the container's repo volume, and `scripts/ansible.sh`
runs `ansible-playbook` in it.

- `site.yml`: the play. Roles join it as their formula leaves `salt/top.sls`,
  in the same change, never before.
- `inventory/hosts.yml`: hosts by short name (the minion IDs), grouped into
  `raspberry_pis` and `servers`. Use groups or facts where states used grains.
- `inventory/host_vars/<host>/<role>.yml`: per-host settings, one variable per
  role, named after the role (`quadlets`). Ansible does **not** merge a dict
  from `group_vars` with the same dict from `host_vars`; the host's value
  replaces it. Keep a host's settings for a role complete in one file, and let
  the role merge them onto its defaults.
- `inventory/group_vars/all/ipam.yml`: the `ipam` variable, read from
  `pillar/ipam.yaml` (one copy for both tools). Look addresses up with the
  filters in `plugins/filter/ipam.py`: `"{{ ipam | ipam_ip('hosts:rpi-01:apps:pihole:ipv4') }}"`,
  `ipam_ips`, `ipam_cidr`, `ipam_mac`. A miss fails the run.
- `roles/<role>/`: `defaults/main.yml` holds `<role>_defaults`, `tasks/`, a
  `README.md` with the schema. Keep logic that would be long Jinja in a
  filter plugin under `plugins/filter/` with tests in `tests/`, as the
  quadlets role does (`plugins/filter/quadlets.py`).
- `plugins/lookup/op.py`: 1Password, see Secrets.
- `control-node/`: the image (Containerfile, ansible-core pin, collections).
  Built by hand with `control-node/build.sh <tag>`.
- Variables files are plain YAML. Jinja only runs inside quoted `"{{ … }}"`
  values; a literal `{{` for an application goes in `{% raw %}…{% endraw %}`.
- Task names describe the outcome; use fully qualified module names
  (`ansible.builtin.file`). Tasks must be idempotent and work in check mode
  (read-only probes get `check_mode: false` and `changed_when: false`).
- Secrets in Ansible: `"{{ lookup('op', 'op://infra/<item>/<field>') }}"`, quoted.
  Lookups are lazy and re-run on every use, and the service account is rate
  limited, so a role resolves its settings once with a `no_log` `set_fact`.
  Tasks that handle secret values use `no_log: true`, pass the values on stdin
  (never in `environment:` or on a command line, which `ps` and `-vvv` show),
  and loops over data containing secrets must not print it (`loop_control.label`
  or loop over a list without the values).
- Validate before suggesting a run: `python -m pytest tests/`,
  `ansible-lint site.yml roles/`, `ansible-playbook --syntax-check site.yml`.
  On the hosts, always dry-run first:
  `scripts/ansible.sh site.yml --check --diff --limit <host>`.

## Conventions (Salt)

- Formulas follow the saltstack-formulas layout: `init.sls`, a `map.jinja`
  that merges `defaults.yaml` with pillar (`pillar.get(..., merge=True)`),
  plus `pillar.example.sls`, `files/` and `README.md`.
- Validate pillar input in Jinja and fail loudly with
  `{{ raise('<formula>: …') }}`. Don't silently skip bad data.
- Use `tpldir` for paths that refer back to the formula itself, so it can be
  relocated.
- State IDs are prefixed with the formula name (`restic-download`,
  `nm_connection_<name>`). Keep requisites (`require`, `onchanges`) explicit.
- States must be idempotent. Use `unless`/`onlyif`/`onchanges` on `cmd.run`.
- Branch on hardware or OS with grains, as the existing files already do
  (`'raspberry pi' in grains.get('productname','') | lower`).
- Pillar SLS files may use Jinja. YAML anchors (`<<: *debian`) are used in
  `pillar/apt/common.sls`.
- Some existing comments are in German. Either language is fine; match the
  file you are editing.

## Secrets

Secrets come from **1Password** and are read on the master while pillar is
rendered. They are never written into this repo:

```jinja
wifi-security.psk: {{ salt['onepassword.read']('op://infra/<item>/<field>') | yaml_dquote }}   # keep quoted
```

- Always pipe the value through `yaml_dquote`. Otherwise a value containing
  `: `, ` #`, `yes` or leading zeros breaks the YAML or changes its type.
- Also available: `onepassword.get(vault, item, field='password',
  section=None)` and `onepassword.item(vault, item)`. The full docs are in
  the module docstring.
- Only the master needs the `op` CLI (`/usr/bin/op` inside the container)
  and the token. Minions only receive the resolved values in their own
  pillar. Never call `onepassword.*` from states under `salt/`.
- The service account is rate limited, and pillar renders for every minion
  on every refresh. References by ID (`op://<vault-id>/<item-id>/...`) cost
  1 read; references by name cost 3. The module caches values for
  `cache_ttl` (300 s), so a rotated secret reaches minions within 5 minutes,
  or right away after a master restart.
- States that write secrets to files set `show_changes: False`, as
  `nm_connections` does, so values don't leak into diffs and job returns. Do
  the same in any new state that handles secrets.

Rules:

- Never write a secret value into a file in this repo, and never print one.
  When a profile or config needs one, add a 1Password reference. If you
  don't know the `op://` path, ask the user instead of leaving the field
  empty: an empty PSK would wipe the working key on the host.
- The user password hash in `pillar/users/` comes from 1Password
  (`op://infra/tk-user/password-hash`). It is still a secret: don't print it,
  and avoid `pillar.items` on minions, which shows it.
- Never read, print or modify `config/onepassword.token`.
- To check a secret on the master, prefer `salt-run salt.cmd
  onepassword.version` or `onepassword.ratelimit`. Only use
  `salt-run salt.cmd onepassword.read` when the user asks, because it prints
  the secret.

## Validating changes

There is no local Salt or CI. Before suggesting a deploy:

1. Check that the YAML parses and the Jinja is balanced (read it carefully;
   `python -c 'import yaml'` only helps on files without Jinja).
2. After deploying, check on the master, as a dry run first:

   ```bash
   ssh root@192.168.23.65
   podman exec -it salt-master-app salt '<minion>' pillar.items          # pillar renders?
   podman exec -it salt-master-app salt '<minion>' state.show_sls <sls>  # states render?
   podman exec -it salt-master-app salt '<minion>' state.apply test=True # dry run
   ```

   (The container name may differ. Check with `podman ps`.)

   After changing `modules/` or `config/40-onepassword.conf`, check that the
   module loads and can authenticate before rendering any pillar:
   `podman exec -it salt-master-app salt-run salt.cmd onepassword.version`.
3. For `nm_connections` changes, use `test=True` and leave `activate` off on
   the interface the minion uses to reach the master.

## Do not

- Run `scripts/deploy.sh`, `scripts/ansible-sync.sh`, `scripts/ansible.sh`
  (other than with `--check`), `state.apply` without `test=True`, or anything
  that touches `192.168.23.65` or the minions unless the user explicitly asks.
  They change live hosts.
- Edit or commit inside `3pfs/*` submodules.
- Hard-code host paths or minion IDs in states. Per-host data belongs in
  `pillar/<formula>/<host>.sls`.
- Commit `.DS_Store` or `.idea/`.
- Commit `config/onepassword.token` or any secret value. `pillar/` and
  `inventory/` are committed, so secrets in them must stay 1Password
  references.
