# Upgrade guide

The Doctbase upgrade command is not implemented yet. Do not use this page as a
production upgrade procedure. The supported flow will back up the instance,
run migrations under a lock, verify service health, and roll back on failure.

Before this guide is finalized, it will document supported source and target
versions, the backup location, rollback behavior, and recovery steps.
