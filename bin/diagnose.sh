#!/usr/bin/env bash
# aws-local-lab :: diagnose - check the whole lab and print a PASS/WARN/FAIL
# report with an explanation and a suggested fix for every non-PASS.
#
# Run by `make doctor`. See docs/troubleshooting.md for the symptom -> fix
# reference this tool is the front door to.
#
#   bin/diagnose.sh                 human-readable report (colorized on a TTY)
#   bin/diagnose.sh --json          machine-readable JSON
#   bin/diagnose.sh --emit-finding  hirdr-knowledge finding stub on stdout
#
# Exit codes: 0 = no FAIL, 1 = at least one FAIL, 2 = bad usage.
#
# Deps: docker, curl, jq, coreutils. No other runtime dependencies.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- config (all overridable from the environment / .env) -------------------
EDGE_PORT="${EDGE_PORT:-4566}"
LAB_ENDPOINT="${LAB_ENDPOINT:-http://localhost:${EDGE_PORT}}"
HEALTH_URL="${LAB_ENDPOINT}/_localstack/health"
CONTAINER="aws-local-lab"
NETWORK="aws-local-lab"
VOLUME="aws-local-lab-data"
LOAD_PROJECT="aws-local-lab-load-harness"
LOAD_LB_PORT="${LOAD_LB_PORT:-8080}"
MIN_MEM_GB=4
MIN_CPU=2
MIN_DISK_GB=5
LOG_TAIL=30

MODE="human"

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json)          MODE="json" ;;
    --emit-finding)  MODE="finding" ;;
    -h|--help)       usage; exit 0 ;;
    *) printf 'diagnose: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --- colors (TTY + human mode only) ----------------------------------------
if [ "$MODE" = "human" ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BOLD=''
fi

# --- result collection ----------------------------------------------------
R_NAME=(); R_STATUS=(); R_MSG=(); R_FIX=()
CONTAINER_LOG_TAIL=""
CONTAINER_STATE="unknown"

add_result() {
  R_NAME+=("$1"); R_STATUS+=("$2"); R_MSG+=("$3"); R_FIX+=("${4:-}")
}
pass() { add_result "$1" PASS "$2" ""; }
warn() { add_result "$1" WARN "$2" "${3:-}"; }
fail() { add_result "$1" FAIL "$2" "${3:-}"; }

have() { command -v "$1" >/dev/null 2>&1; }

# docker inspect wrapper: quiet, whitespace-trimmed, never fails the script
di() {
  docker inspect "$@" 2>/dev/null | tr -d '[:space:]'
}

# ==========================================================================
# checks
# ==========================================================================

DOCKER_OK=0

check_docker() {
  if ! have docker; then
    fail "docker.cli" "the 'docker' CLI is not on PATH" \
      "Install Docker Desktop (macOS/Windows) or the docker engine (Linux)."
    return
  fi
  if docker info >/dev/null 2>&1; then
    local v
    v="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
    pass "docker.daemon" "Docker daemon reachable (engine v${v})"
    DOCKER_OK=1
  else
    fail "docker.daemon" "'docker info' failed - the Docker daemon is not reachable" \
      "Start Docker Desktop (or 'systemctl start docker'), then re-run 'make doctor'."
  fi
}

check_compose() {
  if docker compose version >/dev/null 2>&1; then
    local v
    v="$(docker compose version --short 2>/dev/null || echo '?')"
    pass "docker.compose" "docker compose v${v} present"
  else
    fail "docker.compose" "'docker compose' (Compose v2) is not available" \
      "Install Docker Compose v2 - it ships with Docker Desktop; on Linux: 'apt install docker-compose-plugin'."
  fi
}

check_resources() {
  [ "$DOCKER_OK" -eq 1 ] || return
  local info mem_bytes ncpu mem_gb
  info="$(docker system info --format '{{json .}}' 2>/dev/null || echo '{}')"
  mem_bytes="$(printf '%s' "$info" | jq -r '.MemTotal // 0' 2>/dev/null || echo 0)"
  ncpu="$(printf '%s' "$info" | jq -r '.NCPU // 0' 2>/dev/null || echo 0)"
  mem_gb=$(( mem_bytes / 1073741824 ))

  if [ "$mem_bytes" -eq 0 ]; then
    warn "docker.memory" "could not read Docker's allocated memory" \
      "Check 'docker system info'."
  elif [ "$mem_gb" -lt "$MIN_MEM_GB" ]; then
    warn "docker.memory" "Docker has ~${mem_gb} GiB RAM allocated (< ${MIN_MEM_GB} GiB) - the lab plus a real app stack needs headroom" \
      "Docker Desktop -> Settings -> Resources -> raise Memory to >= ${MIN_MEM_GB} GB."
  else
    pass "docker.memory" "Docker has ~${mem_gb} GiB RAM allocated"
  fi

  if [ "$ncpu" -eq 0 ]; then
    warn "docker.cpu" "could not read Docker's allocated CPUs" "Check 'docker system info'."
  elif [ "$ncpu" -lt "$MIN_CPU" ]; then
    warn "docker.cpu" "Docker has only ${ncpu} CPU allocated" \
      "Docker Desktop -> Settings -> Resources -> raise CPUs to >= ${MIN_CPU}."
  else
    pass "docker.cpu" "Docker has ${ncpu} CPUs allocated"
  fi
}

check_network() {
  [ "$DOCKER_OK" -eq 1 ] || return
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    pass "network" "external Docker network '${NETWORK}' exists"
  else
    fail "network" "external Docker network '${NETWORK}' is missing" \
      "Run 'make up' (creates it) or 'docker network create ${NETWORK}'."
  fi
}

# port: docker-published-by-us | docker-published-by-other | host-process | free
check_one_port() {
  local port="$1" purpose="$2" owner_is_lab="$3" conflict_sev="${4:-warn}"
  local row cname
  row="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | awk -F'\t' -v p=":${port}->" 'index($2,p){print $1; exit}')"
  if [ -n "$row" ]; then
    cname="$row"
    if [ "$owner_is_lab" = "yes" ] || [ "$cname" = "$CONTAINER" ]; then
      pass "port.${port}" "port ${port} (${purpose}) is bound by our container '${cname}'"
    else
      "$conflict_sev" "port.${port}" "port ${port} (${purpose}) is bound by container '${cname}', which is not this lab" \
        "Stop it, or set ${purpose%% *} to a free port in .env and pass it to every 'make' target."
    fi
    return
  fi
  local proc=""
  if have lsof; then
    proc="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1" (pid "$2")"}')"
  elif have ss; then
    proc="$(ss -ltnp 2>/dev/null | awk -v p=":${port} " 'index($0,p){print $NF; exit}')"
  fi
  if [ -n "$proc" ]; then
    "$conflict_sev" "port.${port}" "port ${port} (${purpose}) is held by a non-Docker process: ${proc}" \
      "Stop that process, or move the lab off ${port} (EDGE_PORT / LOAD_LB_PORT in .env)."
  else
    pass "port.${port}" "port ${port} (${purpose}) is free or served by the lab"
  fi
}

check_ports() {
  [ "$DOCKER_OK" -eq 1 ] || return
  # a busy edge port blocks 'make up' outright -> FAIL
  check_one_port "$EDGE_PORT" "EDGE_PORT / LocalStack edge" "no" "fail"
  if [ -n "$(docker ps --filter "label=com.docker.compose.project=${LOAD_PROJECT}" -q 2>/dev/null)" ]; then
    check_one_port "$LOAD_LB_PORT" "LOAD_LB_PORT / load-harness balancer" "yes" "warn"
  fi
}

check_container() {
  [ "$DOCKER_OK" -eq 1 ] || return
  local state exitcode restarting
  state="$(di -f '{{.State.Status}}' "$CONTAINER")"
  [ -n "$state" ] || state="missing"
  CONTAINER_STATE="$state"
  case "$state" in
    missing)
      fail "container" "the LocalStack container '${CONTAINER}' does not exist" \
        "Run 'make up NO_TOKEN=1'."
      ;;
    running)
      restarting="$(di -f '{{.State.Restarting}}' "$CONTAINER")"
      if [ "$restarting" = "true" ]; then
        CONTAINER_LOG_TAIL="$(docker logs --tail "$LOG_TAIL" "$CONTAINER" 2>&1 || true)"
        fail "container" "the LocalStack container is restart-looping" \
          "Inspect the last ${LOG_TAIL} log lines below; usually a bad LOCALSTACK_IMAGE / missing paid token. Try 'make reset NO_TOKEN=1 && make up NO_TOKEN=1'."
      else
        local health
        health="$(di -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER")"
        pass "container" "the LocalStack container is running${health:+ (health: ${health})}"
      fi
      ;;
    restarting)
      CONTAINER_LOG_TAIL="$(docker logs --tail "$LOG_TAIL" "$CONTAINER" 2>&1 || true)"
      fail "container" "the LocalStack container is stuck restarting" \
        "See the log tail below. Commonly a 2026.x/:latest image with no token. 'make reset NO_TOKEN=1 && make up NO_TOKEN=1'."
      ;;
    exited|dead)
      exitcode="$(di -f '{{.State.ExitCode}}' "$CONTAINER")"; [ -n "$exitcode" ] || exitcode='?'
      CONTAINER_LOG_TAIL="$(docker logs --tail "$LOG_TAIL" "$CONTAINER" 2>&1 || true)"
      local fix="See the last ${LOG_TAIL} log lines below, then 'make up NO_TOKEN=1'."
      if [ "$exitcode" = "55" ]; then
        fix="Exit 55 = you are on a 2026.x / ':latest' image with no auth token. Either 'make up NO_TOKEN=1' (pins localstack/localstack:4.14.0, the last tokenless release) or add a PAID LOCALSTACK_AUTH_TOKEN plus LOCALSTACK_IMAGE=localstack/localstack:latest in .env."
      fi
      fail "container" "the LocalStack container has exited (code ${exitcode})" "$fix"
      ;;
    *)
      warn "container" "the LocalStack container is in state '${state}'" \
        "Check 'make ps' and 'make logs'."
      ;;
  esac
}

check_edge() {
  [ "$DOCKER_OK" -eq 1 ] || return
  if curl -sf --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
    pass "edge" "the edge health endpoint is reachable (${HEALTH_URL})"
  else
    local fix="Run 'make up NO_TOKEN=1'."
    [ "$CONTAINER_STATE" = "running" ] && fix="Container is up but the edge is not answering yet - wait for boot ('make logs'), or it crashed after start."
    fail "edge" "the edge health endpoint is not reachable (${HEALTH_URL})" "$fix"
  fi
}

check_services() {
  local body err
  body="$(curl -sf --max-time 5 "$HEALTH_URL" 2>/dev/null || echo '')"
  [ -n "$body" ] || return
  err="$(printf '%s' "$body" | jq -r '[.services // {} | to_entries[] | select(.value=="error") | .key] | join(", ")' 2>/dev/null || echo '')"
  if [ -n "$err" ]; then
    warn "services" "these services report state 'error': ${err}" \
      "Check 'make logs'; 'make restart' often clears a transient start failure."
  else
    local running avail
    running="$(printf '%s' "$body" | jq -r '[.services // {} | .[] | select(.=="running")] | length' 2>/dev/null || echo '?')"
    avail="$(printf '%s' "$body" | jq -r '[.services // {} | .[] | select(.=="available")] | length' 2>/dev/null || echo '?')"
    pass "services" "${running} running, ${avail} available, none in error"
  fi
}

read_token() {
  if [ -n "${LOCALSTACK_AUTH_TOKEN:-}" ]; then
    printf '%s' "$LOCALSTACK_AUTH_TOKEN"; return
  fi
  if [ -f "$REPO_ROOT/.env" ]; then
    grep -E '^LOCALSTACK_AUTH_TOKEN=' "$REPO_ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' '
  fi
}

check_image() {
  [ "$DOCKER_OK" -eq 1 ] || return
  [ "$CONTAINER_STATE" != "missing" ] || return
  local running pins token
  running="$(di -f '{{.Config.Image}}' "$CONTAINER")"
  [ -n "$running" ] || return
  pins="$(grep -hoE 'localstack/localstack:[0-9][0-9A-Za-z._-]*' "$REPO_ROOT"/docker-compose*.yml 2>/dev/null | sort -u | paste -sd', ' -)"
  token="$(read_token)"

  if printf '%s' "$pins" | grep -qF "$running"; then
    pass "image" "running image '${running}' matches a docker-compose pin"
  else
    warn "image" "running image '${running}' does not match the compose pin(s): ${pins:-none found}" \
      "Expected drift? Otherwise 'make reset NO_TOKEN=1 && make up NO_TOKEN=1' to get back on the pinned image."
  fi

  case "$running" in
    *:latest|*:2026.*|*:2027.*)
      if [ -z "$token" ]; then
        fail "image.token" "image '${running}' is a tokenless-incompatible tag but no LOCALSTACK_AUTH_TOKEN is set - it will exit 55" \
          "Use 'make up NO_TOKEN=1' (pins 4.14.0) or set a PAID LOCALSTACK_AUTH_TOKEN in .env."
      else
        warn "image.token" "image '${running}' needs a PAID token; a free 'Hobby' token unlocks nothing beyond the community image" \
          "See docs/fidelity-matrix.md - only a paid Base tier and up adds services."
      fi
      ;;
  esac
}

check_volume() {
  [ "$DOCKER_OK" -eq 1 ] || return
  if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
    pass "volume" "named volume '${VOLUME}' exists"
  else
    warn "volume" "named volume '${VOLUME}' does not exist yet" \
      "Created automatically on the first 'make up'."
  fi
}

check_disk() {
  [ "$DOCKER_OK" -eq 1 ] || return
  local avail_kb avail_gb
  if [ "$CONTAINER_STATE" = "running" ]; then
    avail_kb="$(docker exec "$CONTAINER" df -P /var/lib/localstack 2>/dev/null | awk 'NR==2{print $4}')"
  else
    avail_kb="$(docker run --rm alpine df -P / 2>/dev/null | awk 'NR==2{print $4}')"
  fi
  if [ -z "${avail_kb:-}" ]; then
    warn "disk" "could not determine free disk on the Docker VM" "Check 'docker run --rm alpine df -h'."
    return
  fi
  avail_gb=$(( avail_kb / 1048576 ))
  if [ "$avail_gb" -lt "$MIN_DISK_GB" ]; then
    warn "disk" "only ~${avail_gb} GiB free on the Docker VM (< ${MIN_DISK_GB} GiB)" \
      "Run 'docker system prune' / 'make reset', or grow the Docker disk image."
  else
    pass "disk" "~${avail_gb} GiB free on the Docker VM"
  fi
}

check_env() {
  if [ ! -f "$REPO_ROOT/.env" ]; then
    warn "env" ".env is not present (built-in defaults are in use)" \
      "cp .env.example .env  (defaults are fine for the no-token path)."
    return
  fi
  local missing=""
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    grep -qE "^[[:space:]]*${key}=" "$REPO_ROOT/.env" || missing="${missing} ${key}"
  done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$REPO_ROOT/.env.example" | tr -d '=')
  if [ -n "$missing" ]; then
    warn "env" ".env is missing keys present in .env.example:${missing}" \
      "Add them (copy the annotated defaults from .env.example)."
  else
    pass "env" ".env present and defines every .env.example key"
  fi
}

check_socket() {
  [ "$DOCKER_OK" -eq 1 ] || return
  [ "$CONTAINER_STATE" = "running" ] || return
  if docker exec "$CONTAINER" sh -c 'test -S /var/run/docker.sock && test -r /var/run/docker.sock' >/dev/null 2>&1; then
    pass "socket" "/var/run/docker.sock is mounted and readable inside the container (Lambda can run)"
  else
    fail "socket" "the Docker socket is not usable inside the container - Lambda invokes will fail" \
      "Confirm docker-compose.yml mounts '/var/run/docker.sock:/var/run/docker.sock' and Docker Desktop file sharing permits it."
  fi
}

check_dns() {
  [ "$DOCKER_OK" -eq 1 ] || return
  [ "$CONTAINER_STATE" = "running" ] || return
  if docker exec "$CONTAINER" sh -c 'getent hosts localhost.localstack.cloud >/dev/null 2>&1 || python3 -c "import socket,sys; socket.gethostbyname(\"localhost.localstack.cloud\")"' >/dev/null 2>&1; then
    pass "dns" "'localhost.localstack.cloud' resolves from inside the container"
  else
    warn "dns" "'localhost.localstack.cloud' does not resolve inside the container - some cross-container calls can fail" \
      "For in-network clients use 'http://${NETWORK}:4566'; see docs/troubleshooting.md."
  fi
}

check_cli() {
  if have aws; then
    pass "cli.aws" "the 'aws' CLI is on PATH"
  else
    warn "cli.aws" "the 'aws' CLI is not on PATH" \
      "Install AWS CLI v2; 'bin/awslocal' wraps it for the lab endpoint."
  fi
  if have awslocal; then
    pass "cli.awslocal" "'awslocal' is on PATH"
  else
    pass "cli.awslocal" "'awslocal' is not on PATH - use the repo's './bin/awslocal' wrapper (no install needed)"
  fi
}

# ==========================================================================
# output
# ==========================================================================

overall_status() {
  local s has_warn=0
  for s in "${R_STATUS[@]}"; do
    [ "$s" = "FAIL" ] && { echo FAIL; return; }
    [ "$s" = "WARN" ] && has_warn=1
  done
  [ "$has_warn" -eq 1 ] && echo WARN || echo PASS
}

render_human() {
  local i n_pass=0 n_warn=0 n_fail=0
  printf '%saws-local-lab doctor%s  %s\n' "$C_BOLD" "$C_RESET" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%sendpoint=%s  container=%s%s\n\n' "$C_DIM" "$LAB_ENDPOINT" "$CONTAINER" "$C_RESET"

  for i in "${!R_NAME[@]}"; do
    local st="${R_STATUS[$i]}" color tag
    case "$st" in
      PASS) color="$C_GREEN"; tag="PASS"; n_pass=$((n_pass+1)) ;;
      WARN) color="$C_YELLOW"; tag="WARN"; n_warn=$((n_warn+1)) ;;
      FAIL) color="$C_RED"; tag="FAIL"; n_fail=$((n_fail+1)) ;;
      *)    color=""; tag="$st" ;;
    esac
    printf '  %s[%s]%s %-16s %s\n' "$color" "$tag" "$C_RESET" "${R_NAME[$i]}" "${R_MSG[$i]}"
    if [ "$st" != "PASS" ] && [ -n "${R_FIX[$i]}" ]; then
      printf '       %s-> fix:%s %s\n' "$C_DIM" "$C_RESET" "${R_FIX[$i]}"
    fi
  done

  if [ -n "$CONTAINER_LOG_TAIL" ]; then
    printf '\n%s--- last %s log lines from %s ---%s\n' "$C_DIM" "$LOG_TAIL" "$CONTAINER" "$C_RESET"
    printf '%s\n' "$CONTAINER_LOG_TAIL" | sed 's/^/  /'
  fi

  printf '\n%s--- per-service health (bin/health-check.sh) ---%s\n' "$C_DIM" "$C_RESET"
  if ! LAB_ENDPOINT="$LAB_ENDPOINT" "$SCRIPT_DIR/health-check.sh" 2>&1 | sed 's/^/  /'; then
    printf '  %s(edge unreachable - see the FAIL above)%s\n' "$C_DIM" "$C_RESET"
  fi

  local overall
  overall="$(overall_status)"
  printf '\n%s%s%s  -  %d pass, %d warn, %d fail\n' \
    "$C_BOLD" "$overall" "$C_RESET" "$n_pass" "$n_warn" "$n_fail"
}

render_json() {
  local i items="" overall
  overall="$(overall_status)"
  for i in "${!R_NAME[@]}"; do
    items+="$(jq -n \
      --arg n "${R_NAME[$i]}" --arg s "${R_STATUS[$i]}" \
      --arg m "${R_MSG[$i]}" --arg f "${R_FIX[$i]}" \
      '{name:$n, status:$s, message:$m, fix:$f}')"
  done
  printf '%s' "$items" | jq -s \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg overall "$overall" \
    --arg endpoint "$LAB_ENDPOINT" \
    --arg logtail "$CONTAINER_LOG_TAIL" \
    '{tool:"aws-local-lab/diagnose", timestamp:$ts, endpoint:$endpoint, overall:$overall, container_log_tail:$logtail, checks:.}'
}

render_finding() {
  # hirdr-knowledge finding stub (see that repo's templates/finding.md /
  # bin/kb-ticket). Best-effort front-matter; not a hard dependency.
  local overall i sev
  overall="$(overall_status)"
  sev="low"; [ "$overall" = "WARN" ] && sev="medium"; [ "$overall" = "FAIL" ] && sev="high"
  local sha
  sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf -- '---\n'
  printf 'title: "aws-local-lab diagnose: %s"\n' "$overall"
  printf 'kind: finding\n'
  printf 'status: %s\n' "$([ "$overall" = PASS ] && echo resolved || echo open)"
  printf 'severity: %s\n' "$sev"
  printf 'component: aws-local-lab\n'
  printf 'created: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'git_sha: %s\n' "$sha"
  printf 'tags: [localstack, diagnostics, lab-core]\n'
  printf -- '---\n\n'
  # shellcheck disable=SC2016  # markdown backticks, not shell expansion
  printf '## Summary\n\n`bin/diagnose.sh` overall result: **%s**.\n\n' "$overall"
  printf '## Findings\n\n'
  for i in "${!R_NAME[@]}"; do
    [ "${R_STATUS[$i]}" = "PASS" ] && continue
    printf -- '- **[%s] %s** - %s\n' "${R_STATUS[$i]}" "${R_NAME[$i]}" "${R_MSG[$i]}"
    [ -n "${R_FIX[$i]}" ] && printf -- '  - fix: %s\n' "${R_FIX[$i]}"
  done
  local any=0
  for i in "${!R_STATUS[@]}"; do [ "${R_STATUS[$i]}" != "PASS" ] && any=1; done
  [ "$any" -eq 0 ] && printf -- '- none - all checks passed.\n'
  if [ -n "$CONTAINER_LOG_TAIL" ]; then
    # shellcheck disable=SC2016  # markdown fences, not shell expansion
    printf '\n## Container log tail\n\n```\n%s\n```\n' "$CONTAINER_LOG_TAIL"
  fi
  # shellcheck disable=SC2016  # markdown fences/backticks, not shell expansion
  printf '\n## Repro\n\n```\nmake doctor\n```\n\nAttach a full bundle with `make logs-bundle`.\n'
}

# ==========================================================================
# main
# ==========================================================================

check_docker
check_compose
check_resources
check_network
check_container
check_ports
check_edge
check_services
check_image
check_volume
check_disk
check_env
check_socket
check_dns
check_cli

case "$MODE" in
  json)    render_json ;;
  finding) render_finding ;;
  *)       render_human ;;
esac

[ "$(overall_status)" = "FAIL" ] && exit 1
exit 0
