# Snap Local Etc Directory (`snap/local/etc/`)

## Overview
Stores default environment templates and configuration seeds packaged into the snap.

## Responsibilities
- Provide fallback and initial configuration values for snap daemons.
- Seed the baseline configuration (`defaults.env`) that hooks evaluate when producing active runtime configuration files.
