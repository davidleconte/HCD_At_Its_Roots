# Contributing

## Getting Started

1. Clone the repo and place `hcd-1.2.3-bin.tar.gz` in the project root
2. Run `make up` to start the cluster
3. Run `make test` to verify everything works (requires `pytest` and `pyyaml`)

## Development Workflow

1. Create a feature branch from `main`
2. Make your changes
3. Run validation:
   ```bash
   make test          # 184 tests must pass
   make demo-score    # 79/79 modules must pass
   make validate      # docker-compose.yml syntax
   make lint          # shellcheck + ruff
   ```
4. Push and open a PR using the provided template

## Code Style

- **Shell**: `set -e`, quote all variable expansions (`"${VAR}"`), lowercase for locals, UPPERCASE for env vars
- **Python**: Follow ruff defaults, use `#!/usr/bin/env python3` shebang
- **YAML**: 2-space indentation, use anchors to reduce duplication
- **Docker**: Specific base image tags, minimize layers, clean caches in same RUN, non-root user

## Adding a Demo Module

1. Add a new `case` block in `scripts/demo-entropy.sh` inside `run_module()`
2. Follow the existing pattern: `header` -> explanation -> `log_cmd` -> `lookfor` -> `takeaway` -> `challenge`
3. Update `TOTAL_MODULES` and `PART_NAMES` array at the top of the script
4. Add a test in `tests/test_demo_entropy.py` if the module has specific logic
5. Run `make demo-score` to verify all modules still pass

## Reporting Issues

Use the GitHub issue templates for bug reports and feature requests.
