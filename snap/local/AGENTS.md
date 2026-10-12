# Snap Local Assets Directory (`snap/local/`)

## Overview
Contains files dumped directly into the snap filesystem via the `wrappers` part in `snapcraft.yaml`. The part excludes `AGENTS.md` files via `stage:` so repository documentation is not shipped in the snap payload.

## Responsibilities
- Houses default configuration files deployed to the snap runtime environment.
- Holds custom executables and entrypoint wrapper scripts for daemons and commands.

## Key Files & Directories
- `etc/`: Configuration templates and environment defaults (`defaults.env`).
- `bin/`: Executables and daemon wrapper scripts (`cilium-agent-wrapper`, `install-cni`, `setup-etcd`).
