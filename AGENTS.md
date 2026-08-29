# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Foundation (FR-1, `lab-core`)

- Core stack: `docker-compose.yml` (token mode, `localstack/localstack:4.9.0`) +
  `docker-compose.no-token.yml` (pinned `3.8.1`, no token). Drive it all via the
  `Makefile`; `make up NO_TOKEN=1` for the offline path.
- Pinned tags, the `/_localstack/health` contract, and the network/volume names
  are recorded in [`docs/foundation.md`](docs/foundation.md) - read that before
  building on the lab.
- External Docker network `aws-local-lab` and named volume `aws-local-lab-data`
  are the integration seams. `make up` creates the network; `make reset` wipes both.
- Sibling tracks add Makefile targets below the `>>> sibling-track targets`
  marker and README subsections under their own headings to avoid collisions.
- Seam dirs `terraform/`, `examples/`, `integration/` are stubs for sibling tracks.
- Shell scripts must stay `shellcheck`-clean (NFR-7).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
