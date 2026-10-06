#!/usr/bin/env python3
"""Probe a Strands Decider server: health, ready, smoke, latency, window and concurrency checks.

Stdlib only, Python 3.9 or later. Use it on the GPU host (http://127.0.0.1:8000) or through
the SSM tunnel (http://127.0.0.1:8099). The last output line is a JSON summary.
Exit status: 0 when all checks pass, 1 when one or more checks fail.

The checks:
- health: /health has the status ok and the served name.
- ready: /ready has the served name, both revisions, the warm-up gate and the GPU memory.
- smoke: one request with a noul, a choice and a score question.
- latency: p50 and p95 for each shape. The 25- and 40-question shapes have a state near
  3800 tokens.
- window: a state longer than the window gets HTTP 422 with "code": "context_window_exceeded".
- concurrency: the server allows 1 evaluation and 1 waiter. With more than 2 requests at the
  same time, HTTP 503 with "Retry-After" and {"code": "busy"} is a correct answer. Each
  HTTP 200 answer must be equal to the sequential answer.

Language: ASD-STE100.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Dict, List, Optional, Tuple

SENTENCE = (
    "The deploy script reads the region list and starts one GPU host in the first zone "
    "that has capacity. "
)
TOPICS = ["billing", "network", "storage", "identity", "compute", "database"]
RISK = ["none", "low", "medium", "high", "critical"]
ALL_TESTS = ("health", "ready", "smoke", "latency", "window", "concurrency")
MODEL = "strands-decider-2B-hobson-v19-bb282d7-b1485b2"
V19_REVISION = "bb282d786bc251fd4e3068de3ada9ddbb38127cd"
BASE_REVISION = "b1485b2fa6dfa1287294f269f5fb618e03d52d7c"
# Reference server p50 in ms on one NVIDIA L4 GPU (g6.xlarge). The warm-up gate in
# bootstrap/decider-serve uses the same values. The latency check shows them in its summary.
REFERENCE_MS = {"256/1q": 62, "256/4q": 131, "1024/1q": 137, "1024/4q": 191,
                "2048/1q": 302, "2048/4q": 358, "3800/1q": 635, "3800/4q": 693}


def percentile(values: List[float], pct: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(pct / 100.0 * len(ordered)) - 1)
    return round(ordered[index], 1)


def answer_delta(want: Dict[str, Any], got: Dict[str, Any]) -> Tuple[float, bool]:
    """Return the largest probability difference and whether the top answers are equal."""
    delta, same = 0.0, True
    for key, a in want.items():
        b = got.get(key, {})
        if a.get("type") == "noul":
            delta = max(delta, abs(a["noul"] - b.get("noul", -9.0)))
            continue
        if a.get("type") == "choice" and a.get("choice") != b.get("choice"):
            same = False
        pa, pb = a.get("probabilities", {}), b.get("probabilities", {})
        if set(pa) != set(pb):
            same = False
            continue
        for option, value in pa.items():
            delta = max(delta, abs(value - pb[option]))
    return delta, same


class Probe:
    def __init__(self, base: str, model: str, timeout: float) -> None:
        self.base = base.rstrip("/")
        self.model = model
        self.timeout = timeout
        self.failures: List[str] = []
        self.summary: Dict[str, Any] = {"base": self.base}
        self.tokens_base = 0
        self.tokens_per_sentence = 0.0

    # -- transport ------------------------------------------------------------------------------
    def post(self, body: Dict[str, Any]) -> Tuple[int, Dict[str, Any], float]:
        status, payload, ms, _ = self.post_full(body)
        return status, payload, ms

    def post_full(self, body: Dict[str, Any]) -> Tuple[int, Dict[str, Any], float, Dict[str, str]]:
        data = json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            self.base + "/v1/systemone", data=data, method="POST",
            headers={"content-type": "application/json"},
        )
        started = time.perf_counter()
        headers: Dict[str, str] = {}
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                status, payload = response.status, json.loads(response.read())
                headers = {k.lower(): v for k, v in response.headers.items()}
        except urllib.error.HTTPError as exc:
            status = exc.code
            raw = exc.read().decode("utf-8", "replace")
            headers = {k.lower(): v for k, v in exc.headers.items()}
            try:
                payload = json.loads(raw)
            except ValueError:
                payload = {}
            if not isinstance(payload, dict):
                payload = {}
            payload["error"] = raw[:300]
        except (urllib.error.URLError, OSError) as exc:
            status, payload = 0, {"error": str(exc)}
        return status, payload, (time.perf_counter() - started) * 1000.0, headers

    def check(self, ok: bool, message: str) -> bool:
        print(("PASS " if ok else "FAIL ") + message, flush=True)
        if not ok:
            self.failures.append(message)
        return ok

    # -- request builders -----------------------------------------------------------------------
    @staticmethod
    def state_of(sentences: int, salt: int = 0) -> str:
        return f"Ticket {salt} is about {TOPICS[salt % len(TOPICS)]}. " + SENTENCE * sentences

    @staticmethod
    def questions(kind: str) -> Dict[str, Any]:
        """The shapes 1q, 4q, 25q and 40q. They are the same as the warm-up shapes in
        bootstrap/decider-serve."""
        if kind == "1q":
            return {"fail": {"type": "noul", "instructions": "Does this text describe a failure?"}}
        if kind in ("25q", "40q"):
            out: Dict[str, Any] = {}
            for i in range(int(kind[:-1])):
                if i % 3 == 0:
                    out[f"q{i}"] = {"type": "noul", "instructions": f"Does item {i} of this text describe a failure?"}
                elif i % 3 == 1:
                    out[f"q{i}"] = {"type": "choice", "instructions": f"Which area does item {i} discuss?",
                                    "criteria": {t: None for t in TOPICS}}
                else:
                    out[f"q{i}"] = {"type": "score", "instructions": f"How risky is change {i}?", "criteria": RISK}
            return out
        return {
            "fail": {"type": "noul", "instructions": "Does this text describe a failure?"},
            "topic": {"type": "choice", "instructions": "Which area does this text discuss?",
                      "criteria": {t: None for t in TOPICS}},
            "risk": {"type": "score", "instructions": "How risky is this change?", "criteria": RISK},
            "action": {"type": "noul", "instructions": "Does the text ask for an action?"},
        }

    def body(self, sentences: int, kind: str, salt: int = 0) -> Dict[str, Any]:
        return {"model": self.model, "state": self.state_of(sentences, salt),
                "questions": self.questions(kind)}

    def sentences_for(self, tokens: int) -> int:
        return max(0, int((tokens - self.tokens_base) / self.tokens_per_sentence))

    # -- tests ----------------------------------------------------------------------------------
    def health(self) -> None:
        try:
            with urllib.request.urlopen(self.base + "/health", timeout=10) as response:
                info = json.loads(response.read())
        except (urllib.error.URLError, OSError, ValueError) as exc:
            self.check(False, f"health: {exc}")
            return
        self.summary["health"] = info
        self.check(info.get("status") == "ok",
                   f"health status={info.get('status')} device={info.get('device')} "
                   f"max_length={info.get('max_length')} base={info.get('base_model')}")
        self.check(info.get("model") == self.model, f"health model={info.get('model')}")

    def ready(self) -> None:
        try:
            with urllib.request.urlopen(self.base + "/ready", timeout=10) as response:
                info = json.loads(response.read())
        except (urllib.error.URLError, OSError, ValueError) as exc:
            self.check(False, f"ready: {exc}")
            return
        self.summary["ready"] = info
        self.check(info.get("ready") is True, f"ready={info.get('ready')}")
        self.check(info.get("model") == self.model, f"ready model={info.get('model')}")
        self.check(info.get("v19_revision") == V19_REVISION and info.get("base_revision") == BASE_REVISION,
                   f"ready v19_revision={info.get('v19_revision')} base_revision={info.get('base_revision')}")
        gate = info.get("gate", {})
        self.check(gate.get("pass") is True, f"ready warm-up gate pass={gate.get('pass')} failed={gate.get('failed')}")
        print(f"INFO ready warmup_ms={info.get('warmup_ms')} gpu={info.get('gpu')} "
              f"gpu_memory_mib={info.get('gpu_memory_mib')}")

    def gpu_memory(self) -> None:
        """Record the GPU memory of the server process (torch numbers from /ready)."""
        try:
            with urllib.request.urlopen(self.base + "/ready", timeout=10) as response:
                memory = json.loads(response.read()).get("gpu_memory_mib")
        except (urllib.error.URLError, OSError, ValueError):
            memory = None
        self.summary["gpu_memory_mib_after"] = memory
        print(f"INFO gpu_memory_mib after the tests: {memory}")

    def smoke(self) -> None:
        body = {
            "model": self.model,
            "state": "Help! My payouts have been failing for 3 days.",
            "questions": {
                "is_urgent": {"type": "noul", "instructions": "Does this convey urgency?"},
                "department": {"type": "choice", "instructions": "Route it.",
                               "criteria": {"billing": "money", "technical": "bugs",
                                            "sales": "pricing"}},
                "frustration": {"type": "score", "instructions": "How frustrated?",
                                "criteria": ["Calm", "Frustrated", "Very angry"]},
            },
        }
        status, payload, ms = self.post(body)
        if not self.check(status == 200, f"smoke HTTP {status} in {ms:.0f} ms {payload.get('error', '')}"):
            return
        answers = payload.get("answers", {})
        urgent = answers.get("is_urgent", {})
        department = answers.get("department", {})
        frustration = answers.get("frustration", {})
        probabilities = department.get("probabilities", {})
        noul = urgent.get("noul")
        self.check(payload.get("model") == self.model, f"smoke response model={payload.get('model')}")
        self.check(isinstance(noul, (int, float)) and 0.0 <= noul <= 1.0, f"smoke noul is_urgent={noul}")
        self.check(department.get("choice") in ("billing", "technical", "sales")
                   and abs(sum(probabilities.values()) - 1.0) < 1e-3,
                   f"smoke choice={department.get('choice')} "
                   f"p={ {k: round(v, 3) for k, v in probabilities.items()} }")
        self.check(isinstance(frustration.get("score"), (int, float))
                   and sorted(frustration.get("legend", {}).values()) == sorted(["Calm", "Frustrated", "Very angry"]),
                   f"smoke score={frustration.get('score')} legend={frustration.get('legend')}")
        usage = payload.get("usage", {})
        self.check(usage.get("input_tokens", 0) > 0,
                   f"smoke usage={usage} server_ms={payload.get('latency_ms')} client_ms={ms:.0f}")
        self.summary["smoke"] = {"answers": answers, "usage": usage, "client_ms": round(ms, 1),
                                 "server_ms": payload.get("latency_ms")}

    def calibrate(self) -> bool:
        s0, p0, _ = self.post(self.body(0, "1q"))
        s1, p1, _ = self.post(self.body(20, "1q"))
        if s0 != 200 or s1 != 200:
            return self.check(False, f"calibrate HTTP {s0}/{s1} {p0.get('error', '')}{p1.get('error', '')}")
        self.tokens_base = p0["usage"]["input_tokens"]
        self.tokens_per_sentence = (p1["usage"]["input_tokens"] - self.tokens_base) / 20.0
        print(f"INFO calibrate: base {self.tokens_base} tokens, {self.tokens_per_sentence:.1f} tokens per sentence")
        return self.tokens_per_sentence > 0

    def latency(self, repeat: int) -> None:
        rows = []
        shapes = [(t, k) for t in (256, 1024, 2048, 3800) for k in ("1q", "4q")]
        shapes += [(3800, "25q"), (3800, "40q")]
        for target, kind in shapes:
            body = self.body(self.sentences_for(target), kind)
            for _ in range(2):  # Warm-up for this shape. Triton can compile again.
                self.post(body)
            client, server, tokens, errors = [], [], 0, 0
            for _ in range(repeat):
                status, payload, ms = self.post(body)
                if status != 200:
                    errors += 1
                    continue
                client.append(ms)
                server.append(float(payload.get("latency_ms", 0.0)))
                tokens = payload["usage"]["input_tokens"]
            reference = REFERENCE_MS.get(f"{target}/{kind}")
            row = {"target_tokens": target, "questions": kind, "input_tokens": tokens,
                   "reference_server_ms": reference,
                   "n": len(client), "errors": errors,
                   "client_p50_ms": percentile(client, 50), "client_p95_ms": percentile(client, 95),
                   "server_p50_ms": percentile(server, 50), "server_p95_ms": percentile(server, 95)}
            rows.append(row)
            self.check(errors == 0,
                       f"latency {kind} {tokens:>5} tokens: client p50 {row['client_p50_ms']} ms, "
                       f"p95 {row['client_p95_ms']} ms; server p50 {row['server_p50_ms']} ms "
                       f"(n={len(client)}, errors={errors})")
        self.summary["latency"] = rows

    def window(self) -> None:
        status, payload, _ = self.post(self.body(self.sentences_for(6000), "1q"))
        self.check(status == 422,
                   f"window: a state of about 6000 tokens gives HTTP {status} (want 422) "
                   f"{payload.get('error', '')[:140]}")
        self.check(payload.get("code") == "context_window_exceeded",
                   f"window: code={payload.get('code')!r} (want 'context_window_exceeded') "
                   f"detail={str(payload.get('detail'))[:100]!r}")
        self.summary["window"] = {"status": status, "code": payload.get("code"), "detail": payload.get("detail")}

    def concurrency(self, workers: int, rounds: int) -> None:
        bodies = []
        for i in range(12):
            questions = {
                "topic": {"type": "choice", "instructions": f"Which area does ticket {i} discuss?",
                          "criteria": {t: None for t in TOPICS[: 3 + i % 4]}},
                "risk": {"type": "score", "instructions": "How risky is this change?", "criteria": RISK},
                "fail": {"type": "noul", "instructions": "Does this text describe a failure?"},
            }
            bodies.append({"model": self.model, "state": self.state_of(3 + 7 * i, salt=i),
                           "questions": questions})
        baseline = []
        for body in bodies:
            status, payload, _ = self.post(body)
            if not self.check(status == 200, f"concurrency baseline HTTP {status} {payload.get('error', '')}"):
                return
            baseline.append(payload["answers"])
        jobs = [(i, body) for _ in range(rounds) for i, body in enumerate(bodies)]
        started = time.perf_counter()
        with ThreadPoolExecutor(max_workers=workers) as pool:
            results = list(pool.map(lambda job: (job[0],) + self.post_full(job[1]), jobs))
        wall_ms = (time.perf_counter() - started) * 1000.0
        statuses = sorted({r[1] for r in results})
        ok = [r for r in results if r[1] == 200]
        # With more than 2 requests at the same time, 503 + Retry-After + code busy is correct.
        busy = [r for r in results if r[1] == 503 and r[4].get("retry-after") == "1"
                and r[2].get("code") == "busy"]
        errors = [r for r in results if r[1] != 200 and r not in busy]
        mismatches, max_delta = 0, 0.0
        for i, status, payload, _, _ in ok:
            delta, same = answer_delta(baseline[i], payload.get("answers", {}))
            max_delta = max(max_delta, delta)
            mismatches += 0 if (same and delta <= 0.02) else 1
        self.check(not errors, f"concurrency: {len(errors)} errors in {len(jobs)} requests with {workers} "
                               f"workers, statuses={statuses}, 200={len(ok)}, 503 busy={len(busy)}")
        if workers > 2:
            self.check(len(busy) > 0, f"concurrency: {len(busy)} busy answers (503 + Retry-After: 1) with "
                                      f"{workers} workers (want more than 0)")
        self.check(len(ok) > 0 and mismatches == 0,
                   f"concurrency: {mismatches} of {len(ok)} HTTP 200 answers differ from the sequential "
                   f"answers, max probability delta {max_delta:.4f}")
        self.summary.setdefault("concurrency", []).append({
            "requests": len(jobs), "workers": workers, "ok": len(ok), "busy": len(busy),
            "errors": len(errors), "statuses": statuses, "mismatches": mismatches,
            "max_delta": round(max_delta, 5), "wall_ms": round(wall_ms, 1),
            "requests_per_s": round(len(jobs) / (wall_ms / 1000.0), 2)})
        print(f"INFO concurrency: {len(jobs)} requests in {wall_ms:.0f} ms with {workers} workers "
              f"({self.summary['concurrency'][-1]['requests_per_s']} requests/s)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default="http://127.0.0.1:8000")
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--tests", default=",".join(ALL_TESTS))
    parser.add_argument("--repeat", type=int, default=12)
    parser.add_argument("--workers", default="2,8",
                        help="Comma list. Each value is one concurrency run (default 2,8).")
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()
    tests = [t.strip() for t in args.tests.split(",") if t.strip()]
    unknown = sorted(set(tests) - set(ALL_TESTS))
    if unknown:
        parser.error(f"unknown tests: {unknown}")

    probe = Probe(args.base, args.model, args.timeout)
    if "health" in tests:
        probe.health()
    if "ready" in tests:
        probe.ready()
    if "smoke" in tests:
        probe.smoke()
    if ("latency" in tests or "window" in tests) and probe.calibrate():
        if "latency" in tests:
            probe.latency(args.repeat)
        if "window" in tests:
            probe.window()
    if "concurrency" in tests:
        for workers in [int(w) for w in args.workers.split(",") if w.strip()]:
            probe.concurrency(workers, args.rounds)
    if "ready" in tests:
        probe.gpu_memory()
    probe.summary["ok"] = not probe.failures
    probe.summary["failures"] = probe.failures
    print(json.dumps(probe.summary, separators=(",", ":")))
    return 0 if not probe.failures else 1


if __name__ == "__main__":
    sys.exit(main())
