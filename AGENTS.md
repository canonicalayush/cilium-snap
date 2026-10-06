# Cilium Snap Root Directory

## Overview
Root directory for the `cilium-snap` snap packaging project.

## Responsibilities
- Houses project-level documentation, licensing, and configuration (`README.md`, `LICENSE`, `.gitignore`).
- Coordinates snap building via `snap/snapcraft.yaml` and component compilation scripts in `build-scripts/`.

## Key Files & Directories
- `snap/`: Snapcraft metadata, lifecycle hooks, and local service wrappers.
- `build-scripts/`: Scripts and component definitions for building upstream source components.
- `README.md`: Concise repository overview, scope, build, and usage guide.
- `LICENSE`: GNU General Public License v3.0 (GPL-3.0).
- `.gitignore`: Ignore rules for local build artifacts and temporary files.
