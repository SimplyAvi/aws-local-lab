#!/usr/bin/env bash
# aws-local-lab :: ci/lint.sh
#
# Static checks that need no Docker daemon. Run by the CI `lint` job; also
# runnable locally:  ci/lint.sh
#
#   1. shellcheck every tracked shell script (bin/* and every *.sh)
#   2. `docker compose config -q` for the core stack, the no-token overlay, and
#      every compose file under integration/
#   3. `make -n` parse check for the everyday targets
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

fail=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# --- 1. shellcheck ---------------------------------------------------------
step "shellcheck"
scripts=()
while IFS= read -r f; do
  [ -n "$f" ] && scripts+=("$f")
done < <(
  {
    git ls-files -- 'bin/*' '*.sh'
    # bin/ entries without a .sh suffix that are still shell scripts
    for f in bin/*; do
      [ -f "$f" ] || continue
      if head -n1 "$f" | grep -qE '^#!.*(bash|sh)\b'; then printf '%s\n' "$f"; fi
    done
  } | sort -u
)
printf '  %s\n' "${scripts[@]}"
if ! shellcheck --external-sources "${scripts[@]}"; then
  fail=1
fi

# --- 2. docker compose config -------------------------------------------
step "docker compose config"
compose_checks=(
  "docker-compose.yml"
  "docker-compose.yml:docker-compose.no-token.yml"
)
while IFS= read -r f; do
  compose_checks+=("$f")
done < <(git ls-files -- 'integration/**/docker-compose*.yml' 'integration/**/*.smoke.yml')

for entry in "${compose_checks[@]}"; do
  args=()
  IFS=':' read -ra files <<< "$entry"
  for cf in "${files[@]}"; do args+=(-f "$cf"); done
  printf '  compose %s ... ' "$entry"
  if docker compose "${args[@]}" config -q; then
    echo "ok"
  else
    echo "FAIL"
    fail=1
  fi
done

# --- 3. make dry-run parse ---------------------------------------------
step "make -n"
for tgt in up down restart status reset logs ps integrate-smoke \
           sample-deploy sample-test sample-destroy \
           tf-validate tf-fmt-check tf-foundation-apply tf-destroy-all \
           load-up load-run load-down; do
  printf '  make -n %s ... ' "$tgt"
  if make -n "$tgt" >/dev/null 2>&1; then
    echo "ok"
  else
    echo "FAIL"
    make -n "$tgt" >/dev/null || true
    fail=1
  fi
done

exit "$fail"
