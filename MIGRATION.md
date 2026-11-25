# Salt → Ansible

The fleet moves from Salt to Ansible one formula at a time. Salt keeps
managing everything that has not moved yet; a formula leaves `salt/top.sls`
in the same change that brings its Ansible role, so the two never manage the
same thing.

## Status

| Salt formula / state              | Ansible                         | Status |
| --------------------------------- | ------------------------------- | ------ |
| `quadlets` (in-house)             | `roles/quadlets`                | **done**: same unit files, checked against Salt 3008.5 for all four hosts |
| `nm_connections` (in-house)       | role, ini/keyfile templates     | todo |
| `restic` (in-house)               | role                            | todo |
| `acme_sh` (in-house)              | role                            | todo |
| `luks_lvm` (in-house)             | role (`community.crypto`, `community.general.lvg/lvol`) | todo |
| `local_grains` + reactor          | dropped: inventory groups do the targeting | todo (removed with Salt) |
| `packages`, `packages.backports_kernel` | `ansible.builtin.apt` tasks | todo |
| `apt.*` (greenaar)                | `ansible.builtin.deb822_repository`, templates | todo |
| `users` (saltstack-formulas)      | `ansible.builtin.user`, `ansible.posix.authorized_key` | todo |
| `openssh.*` (greenaar)            | templates for `sshd_config` / `ssh_config` | todo |
| `locale` (greenaar)               | `community.general.locale_gen`  | todo |
| `write_environment` (greenaar)    | `ansible.builtin.copy` / `template` | todo |
| `samba` + `pdbedit` modules       | role + a small module in `library/` | todo |
| `telegraf.agent` (greenaar)       | role                            | todo |

## How Ansible runs here

The control node is a container on rpi-01, `ansible-controller`, managed by
the quadlets role like every other container (`inventory/host_vars/rpi-01/quadlets.yml`).

- **Image**: `control-node/` (Debian trixie, ansible-core, collections, the
  1Password CLI). Built and pushed by hand with `control-node/build.sh <tag>`,
  like the salt-master image.
- **Code**: `scripts/ansible-sync.sh` rsyncs this working tree into the
  container's repo volume, as `scripts/deploy.sh` does for the Salt master.
- **Runs**: `scripts/ansible.sh site.yml --check --diff` runs `ansible-playbook`
  in the container over `ssh` + `podman exec`.
- **SSH**: the container logs in as root with its own key, which it loads from
  1Password into an ssh-agent at start (`ANSIBLE_SSH_KEY_REF`), so the key
  never touches a disk. It reaches rpi-01 itself through the macvlan shim.
- **Secrets**: `lookup('op', 'op://…')` (`plugins/lookup/op.py`) reads them with
  the same 1Password service account as the Salt master. The token is the
  podman secret `ansible-op-token`, mounted at `/run/secrets/op-token`.
- **Restarts**: the role never restarts the control-node container during a
  run (`restart_on_change: false`). After a new image tag, restart it by hand
  between runs: `systemctl restart ansible-controller` on rpi-01.

## Bootstrap (once)

1. **SSH key.** In 1Password, create an SSH Key item `ansible-controller` in the
   `infra` vault that the service account can read. Put its public key into
   `/root/.ssh/authorized_keys` on rpi-01, rpi-02, rpi-03 and server-01. If you
   name it differently, adjust `ANSIBLE_SSH_KEY_REF` in
   `inventory/host_vars/rpi-01/quadlets.yml`.
2. **Address.** The container gets `192.168.23.108` / `fd42:ac1d:feed:1::6c` /
   `02:ac:1d:fe:ed:6c` (`pillar/ipam.yaml`). Make sure nothing else uses it and
   that it is outside the DHCP pool.
3. **Salt side.** Deploy this branch with `scripts/deploy.sh`. This takes
   `quadlets` out of Salt's highstate and adds the shim route for the control
   node on rpi-01. Apply it on rpi-01, dry run first:

   ```sh
   podman exec -it salt-master-app salt rpi-01 state.apply nm_connections test=True
   podman exec -it salt-master-app salt rpi-01 state.apply nm_connections
   ```

   Nothing on the hosts changes otherwise. Containers keep running, and Salt
   just stops touching them.
4. **Image.** `control-node/build.sh 2.22.0-1` (from your Mac).
5. **Token.** On rpi-01, create the podman secret from the token the Salt master
   already uses:

   ```sh
   podman secret create ansible-op-token \
     /var/lib/containers/storage/volumes/salt-master-config/_data/onepassword.token
   ```

6. **First run**, from a throwaway container on rpi-01 (host network, so it
   reaches every host on mgmt). It creates the control-node quadlet and takes
   over rpi-01's other quadlets:

   ```sh
   rsync -a --delete --exclude .git --exclude 3pfs ./ root@192.168.23.65:/root/ansible-bootstrap/
   ssh -t root@192.168.23.65
   podman run --rm -it --network host \
     --secret ansible-op-token,type=mount,target=op-token,uid=1000,gid=1000,mode=0400 \
     -e 'ANSIBLE_SSH_KEY_REF=op://infra/ansible-controller/private key?ssh-format=openssh' \
     -v /root/ansible-bootstrap:/srv/ansible:ro,Z \
     hub.klessen.cloud/glotzerhotze/ansible-controller:2.22.0-1 \
     ansible-playbook site.yml --limit rpi-01 --check --diff
   # the same without --check, then:
   rm -rf /root/ansible-bootstrap
   ```

7. **From then on**, from your Mac:

   ```sh
   scripts/ansible-sync.sh
   scripts/ansible.sh site.yml --check --diff
   scripts/ansible.sh site.yml
   ```

### What the first run changes

Under Salt, the quadlet unit files carry `# Managed by Salt (quadlet formula)`
as their first line. The role adopts them: it rewrites the header line, and a
file whose only change is that line restarts nothing and does not re-create
the network. If all is as Salt left it, the first run per host is one
`daemon-reload`, and secrets and images are left as they are. The dry run
shows each header change as a one-line diff. Any other diff is a real
difference between the host and the settings, and it restarts what it touches.

## Things that work differently in Ansible

- **No deep merge across files.** A dict in `host_vars` replaces the same dict
  from `group_vars`; Salt's pillar merged them. Keep a role's settings for a
  host in one variable in one file, and let the role merge it onto its
  defaults (as `quadlets_defaults` does).
- **Lookups are lazy.** A `lookup('op', …)` in a variable runs again every
  time the variable is used. The service account is rate limited, so roles
  resolve such variables once per run with `set_fact` (see
  `roles/quadlets/tasks/prepare.yml`).
- **No Jinja around YAML.** Variables files are plain YAML; Jinja only runs
  inside quoted `"{{ … }}"` values. A YAML comment is just a comment (no
  1Password read hides in it), and `{% set %}` became an ordinary variable.
- **No event bus.** The reactor and `local_grains` exist for targeting and for
  converging a minion when it starts. Inventory groups do the targeting, and
  runs are started by hand (or later by a timer in the control node).
- **Provisioning.** The netboot.xyz preseed still bootstraps a Salt minion
  (`scripts/netboot.xyz/assets/preseed/advanced.cfg`). Once Salt is gone, it
  only needs to install the control node's public key for root; the first
  `site.yml` run does the rest.

## When everything has moved

- Mark the `salt-master` app `absent: true` in
  `inventory/host_vars/rpi-01/quadlets.yml` (add `purge_volumes: true` to drop
  its volumes), and remove route4 from the rpi-01 shim.
- Delete `salt/`, `pillar/` (move `pillar/ipam.yaml` to `inventory/` and point
  `inventory/group_vars/all/ipam.yml` at it), `config/`, `modules/`,
  `reactor/`, `3pfs/` and `scripts/deploy.sh`, and uninstall `salt-minion` on
  the hosts.
- Rotate the 1Password service account token: the old file copy in the
  salt-master volume goes away with it.
