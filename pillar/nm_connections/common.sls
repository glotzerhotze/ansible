# /etc/NetworkManager/NetworkManager.conf, written as
#   <section>: {key: value, ...}
# Hosts without conf.settings keep the file their package installed.
# YAML lists become "a,b", YAML booleans become true/false, a key set to
# null is left out, a section without keys is written as an empty [section].
# Quote values YAML would otherwise change: '*' (alias), 'no'/'yes'/'on'/'off'
# (booleans). Reference: `man NetworkManager.conf`.
nm_connections:
  conf:
    # path: /etc/NetworkManager/NetworkManager.conf
    # true: restart NetworkManager after a change instead of
    # `nmcli general reload conf`. Settings such as [main] plugins or
    # [ifupdown] managed are only read at startup.
    restart: false
    settings:
      main:
        configure-and-quit: 'no'
        no-auto-default: '*'
        plugins: [keyfile]
      ifupdown:
        managed: false
