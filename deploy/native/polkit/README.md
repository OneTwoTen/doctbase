# Native polkit rules

`50-doctbase.rules` is the narrow lifecycle allowlist installed to
`/etc/polkit-1/rules.d/`. It lets only the `doctbase-management` service
account start, stop, restart, enable or disable Doctbase **application** units.

- Infrastructure units (`postgresql@18-doctbase.service`,
  `doctbase-pgbouncer.service`, `doctbase-caddy.service`) are deliberately
  excluded; restarting them stays an explicit operator action.
- No wildcard unit match is allowed. A new application unit must be added to
  the explicit list and covered by `tests/unit/install_units_test.zig`.
- The installer must not grant broad systemd control to any Doctbase service
  user.
