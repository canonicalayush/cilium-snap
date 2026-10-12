# Snap Hooks Directory (`snap/hooks/`)

## Overview
Contains the snap lifecycle hook scripts invoked by `snapd` during installation and configuration events.

## Responsibilities
- `install`: Runs once upon snap installation. Initializes state and runtime directories (e.g., `/var/snap/cilium-snap/...`).
- `configure`: Executed upon installation and whenever `snap set cilium-snap ...` is invoked. Reads snap configuration settings, generates runtime environment files (such as `$SNAP_DATA/config.env`), and restarts the affected daemons so the new values take effect.
- `remove`: Runs once upon snap removal. Deletes the host CNI config and binaries that `install-cni` wrote outside `$SNAP`.
