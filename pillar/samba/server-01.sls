# pillar/samba.sls
# Standalone Samba server for greenaar/samba-formula, tuned for macOS
# (Monterey and later) clients, sharing the restic backup directory.
#
# Encrypt this file (e.g. gpg renderer) once it holds a real NT hash.

samba:
  role: ROLE_STANDALONE

  conf:
    render:
      # The formula's defaults only render [global] and drop every other
      # section. List the share here so it is rendered, without also pulling
      # in the default [homes] and [printers] sections.
      section_order: ['global', 'backups', 'docs', 'funstuff']
      include_unordered_sections: no
      include_skeleton: no

    sections:
      global:
        workgroup: WORKGROUP
        server string: "%h backup server"
        security: user
        map to guest: never
        # Same networks as the formula default; add yours if clients live
        # elsewhere (e.g. 172.16.0.0/12).
        hosts allow: "127. 10. 192.168."

        # The formula defaults enable CUPS printing; this is a file-only box.
        load printers: "no"
        printing: bsd
        printcap name: /dev/null
        disable spoolss: "yes"

        # SMB2+ only; macOS uses SMB2/3 and NTLMv2 (Samba's default
        # "ntlm auth = ntlmv2-only" is fine for it).
        server min protocol: SMB2

        # --- macOS compatibility (vfs_fruit) ---
        # Must be set in [global] so the Apple SMB2 extensions (AAPL) are
        # negotiated on the first connection, before any share is opened.
        vfs objects: catia fruit streams_xattr
        "fruit:metadata": stream
        "fruit:model": MacSamba
        "fruit:posix_rename": "yes"
        "fruit:veto_appledouble": "no"
        "fruit:nfs_aces": "no"
        "fruit:wipe_intentionally_left_blank_rfork": "yes"
        "fruit:delete_empty_adfiles": "yes"
        ea support: "yes"

      backups:
        comment: "restic backup repositories"
        path: /var/lib/restic/backups
        browseable: "yes"
        read only: "no"
        valid users: restic
        # Keep everything written over SMB owned by the restic account, so
        # restic on the server and over the share see the same ownership.
        force user: restic
        force group: restic
        create mask: "0660"
        directory mask: "0770"
        # Keep Finder's .DS_Store files out of the repository.
        veto files: "/.DS_Store/"
        delete veto files: "yes"

      docs:
        comment: "docs user for document archiving"
        path: /home/docs
        browseable: "yes"
        read only: "no"
        valid users: docs
        # Keep everything written over SMB owned by the restic account, so
        # restic on the server and over the share see the same ownership.
        force user: docs
        force group: docs
        create mask: "0660"
        directory mask: "0770"
        # Keep Finder's .DS_Store files out of the repository.
        veto files: "/.DS_Store/"
        delete veto files: "yes"

      funstuff:
        comment: "funstuff"
        path: /mnt/base/funstuff
        browseable: "yes"
        read only: "no"
        valid users: tk
        # Keep everything written over SMB owned by the restic account, so
        # restic on the server and over the share see the same ownership.
        force user: tk
        force group: tk
        create mask: "0660"
        directory mask: "0770"
        # Keep Finder's .DS_Store files out of the repository.
        veto files: "/.DS_Store/"
        delete veto files: "yes"

  users:
    docs:
      password:
            # NT hash of the SMB password, not the plaintext. Generate with:
            #   printf '%s' 'YourPassword' | iconv -t UTF-16LE \
            #     | openssl dgst -md4 -provider default -provider legacy \
            #     | awk '{print toupper($NF)}'
            nt: {{ salt['onepassword.read']('op://infra/samba-linux-server/password') | yaml_squote }}
    restic:
      password:
        # NT hash of the SMB password, not the plaintext. Generate with:
        #   printf '%s' 'YourPassword' | iconv -t UTF-16LE \
        #     | openssl dgst -md4 -provider default -provider legacy \
        #     | awk '{print toupper($NF)}'
        nt: {{ salt['onepassword.read']('op://infra/samba-linux-server/password') | yaml_squote }}
