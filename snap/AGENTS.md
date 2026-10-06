# Snapcraft Directory (`snap/`)

## Overview
Contains the core Snapcraft packaging configuration and lifecycle logic for `cilium-snap`.

## Responsibilities
- Define the snap package specification, architecture targets, confinement, parts, and daemon services in `snapcraft.yaml`.
- Handle snap configuration and initialization via lifecycle hooks in `hooks/`.
- Provide runtime entrypoints and daemon wrappers in `local/`.

## Key Files & Directories
- `snapcraft.yaml`: Main snap recipe defining parts (`cilium`, `etcd`, `cni-plugins`, `llvm`, `runtime-deps`), daemons, and apps.
- `hooks/`: Snap hooks (`install`, `configure`) managing environment configuration and initialization.
- `local/`: Local scripts, environment defaults, and daemon wrappers bundled directly into the snap payload.
