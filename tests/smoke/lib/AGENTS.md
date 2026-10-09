# Smoke Test Library (`tests/smoke/lib/`)

## Overview
Shared bash helpers sourced by `run.sh` before any case file.

## Files
- `harness.sh`: Test registration and execution (`run_case`, `print_summary`), assertions (`assert_eq`, `assert_ne`, `assert_contains`, `assert_not_contains`, `assert_matches`, `assert_file`, `assert_dir`, `assert_executable`, `assert_json`, `assert_cmd`, `assert_cmd_fails`, `assert_mountpoint`), polling (`retry_until`), and the `fail`/`skip`/`log`/`info`/`warn` output primitives.
- `snap.sh`: Knowledge of this specific snap -- app names, service names, `snap_config` lookup against the rendered `config.env`, `cilium-dbg` JSON accessors, `cni_invoke`, endpoint helpers (`endpoint_id_for_container`, `endpoint_resolve_identity`), `ip_in_cidr`, and `smoke_teardown_netns`.
