locale:
  # extra locale-related packages beyond the `locales` default
  pkgs:
    - locales

  # locales to generate (locale.present)
  present:
    - en_US.UTF-8
    - de_DE.UTF-8

  # system-wide default locale (locale.system / localectl)
  # `requires` must match one of the entries in `present`
  default:
    name: de_DE.UTF-8
    requires: de_DE.UTF-8
