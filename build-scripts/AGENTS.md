# Build Scripts Directory (`build-scripts/`)

## Overview
Houses compilation and build management logic for third-party upstream components packaged into the snap.

## Responsibilities
- `build-component.sh`: Central orchestration script. Given a component name, it clones the git repository from `components/<name>/repository` at the commit or tag in `components/<name>/version`, and runs `components/<name>/build.sh` within the build environment.
- `components/`: Directory containing metadata and build definitions for each upstream dependency.
