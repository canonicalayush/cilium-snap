# Snap Hooks Directory (`snap/hooks/`)

## Overview
Contains the snap lifecycle hook scripts invoked by `snapd` during installation and configuration events.

## Responsibilities
- `install`: Runs once upon snap installation. Initializes state and runtime directories (e.g., `/var/snap/cilium-snap/...`), populates baseline configuration, and seeds defaults.
- `configure`: Executed upon installation and whenever `snap set cilium-snap ...` is invoked. Reads snap configuration settings and generates runtime environment files (such as `$SNAP_DATA/config.env`).
