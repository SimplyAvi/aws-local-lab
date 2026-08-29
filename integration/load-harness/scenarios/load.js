// k6 load scenario for the aws-local-lab Layer 3 harness.
//
//   docker compose run --rm k6 run /scenarios/load.js
//   (wrapped by `make load-run`)
//
// Drives traffic at Traefik (http://traefik:80 inside the shared network),
// which balances across the app replicas. Each iteration does a write path
// (POST /work -> S3 + DynamoDB) and a read-back (GET /work/:id).
import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";

const BASE = __ENV.TARGET_URL || "http://traefik:80";

const replicasSeen = new Counter("replicas_seen_total");
const writeLatency = new Trend("write_latency", true);

export const options = {
  scenarios: {
    ramp: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: __ENV.RAMP_UP || "10s", target: Number(__ENV.VUS || 20) },
        { duration: __ENV.HOLD || "20s", target: Number(__ENV.VUS || 20) },
        { duration: __ENV.RAMP_DOWN || "5s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<2000"],
  },
};

export default function () {
  const res = http.get(`${BASE}/`);
  check(res, { "root 200": (r) => r.status === 200 });
  if (res.status === 200) {
    try {
      replicasSeen.add(1, { replica: res.json("replica") });
    } catch (_) {
      // ignore parse errors under fault injection
    }
  }

  const w = http.post(`${BASE}/work`, JSON.stringify({ t: Date.now() }), {
    headers: { "Content-Type": "application/json" },
  });
  const ok = check(w, {
    "work 201": (r) => r.status === 201,
    "roundtrip ok": (r) => {
      try {
        return r.json("roundtrip") === true;
      } catch (_) {
        return false;
      }
    },
  });
  writeLatency.add(w.timings.duration);

  if (ok && w.status === 201) {
    const id = w.json("id");
    const g = http.get(`${BASE}/work/${id}`);
    check(g, { "read-back 200": (r) => r.status === 200, "found": (r) => r.json("found") === true });
  }

  sleep(0.5);
}
