# Cilium Snap Root Directory

## Overview
Root directory for the `cilium-snap` snap packaging project.

## Responsibilities
- Houses project-level documentation, licensing, and configuration (`README.md`, `LICENSE`, `.gitignore`).
- Coordinates snap building via `snap/snapcraft.yaml` and component compilation scripts in `build-scripts/`.

## Key Files & Directories
- `snap/`: Snapcraft metadata, lifecycle hooks, and local service wrappers.
- `build-scripts/`: Scripts and component definitions for building upstream source components.
- `tests/`: The smoke test suite that exercises a built snap end to end.
- `docs/`: Architecture, setup, configuration, and testing documentation, an architecture diagram, and agent-summarised findings write-ups (`docs/findings.md`, `docs/findings/`).
- `.github/`: GitHub Actions CI workflows (lint, formatting, and smoke-test checks).
- `README.md`: Concise repository overview, documentation index, and quick-start guide.
- `LICENSE`: GNU General Public License v3.0 (GPL-3.0).
- `.gitignore`: Ignore rules for local build artifacts and temporary files.
- `.yamllint.yaml`: yamllint ruleset enforced by CI on `snap/snapcraft.yaml` and `.github/`.

Every directory in this repository has its own AGENTS.md with directory-local context; consult the nearest one before working in a subtree.
