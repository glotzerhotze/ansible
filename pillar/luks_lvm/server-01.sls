# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Example pillar for the luks_lvm formula.
#
# Find stable disk names with:   ls -l /dev/disk/by-id/
# Prefer the ata-/nvme-/scsi- names that include the serial number; avoid
# the -partN entries (this formula encrypts whole disks).
#
# Keep `key` values out of plain-text pillar: use the GPG renderer
# (#!yaml|gpg) or another secrets backend.

luks_lvm:
  devices:
    crypt_data:
      disk: /dev/disk/by-id/ata-SanDisk_SD8SB8U512G1122_163027423112
      key: {{ salt['onepassword.read']('op://infra/data-disk-encryption/ata-SanDisk_SD8SB8U512G1122_163027423112') | yaml_dquote }}
      vg: vg_data
      crypttab_opts: luks,nofail,discard   # per-device override

    # 2) A disk that already has LUKS with LVM inside (set up by hand or on
    #    another machine). It is never reformatted: unlocked with the key,
    #    its VG activated, and the LVs listed under vgs: mounted.
    #crypt_archive:
    #  disk: /dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNF0R123456A
    #  key: "the-existing-passphrase-of-that-disk"
    #  vg: vg_archive

  # --- Volume groups and logical volumes -------------------------------------
  vgs:
    vg_data:
      lvs:
        restic:
          size: 100G           # pre-created if missing, grown if you raise it
          fs: ext4
          mountpoint: /var/lib/restic/repos
          opts: defaults,nofail
        backups:
          size: 200G           # only used at creation time
          fs: ext4
          mountpoint: /var/lib/restic/backups
          opts: defaults,nofail

    #vg_archive:
    #  lvs:
    #    # No size/extents: the LV must already exist; it is only mounted.
    #    home:
    #      fs: ext4
    #      mountpoint: /mnt/old-home
    #    backup:
    #      fs: btrfs
    #      mountpoint: /mnt/old-backup
