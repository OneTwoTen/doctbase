# Configuration reference

The instance configuration contract is defined in
[`specs/001-doctbase-install-config/contracts/config.md`](../specs/001-doctbase-install-config/contracts/config.md).
The current runtime supports a subset of that contract; validate a file with
`doctbase config validate` before using it.

The default path is `/etc/doctbase/doctbase.toml`. Development runs can select
another path with `--config` or `DOCTBASE_CONFIG`. Generated configuration is
owned by Doctbase and should not be edited by hand.

This reference will be expanded with the supported key table and defaults as
the configuration and install tasks are completed.
