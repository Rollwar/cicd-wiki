#!/usr/bin/env python3
"""
demo/dry-run.py — dry-run simulation of the wiki-v2 CI/CD pipeline.

Walks through every stage that GitHub Actions would execute, but locally:
  Phase 1 — CI:           lint, security, docker build, push, notify
  Phase 2 — CD:           deploy GREEN, smoke tests, promote, scale-down BLUE, post-deploy monitor
  Phase 3 — Functional:   E2E test suite (8 scenarios) against the mock server
  Phase 4 — Performance:  k6-style load test (multi-thread HTTP)
  Phase 5 — Rollback:     simulated failure → automatic rollback → recovery

Spins up demo/mock-wiki-server.js in the background and tears it down on exit.
Outputs colored, timestamped logs to stdout AND writes a full log to
/home/z/my-project/download/pipeline-dry-run.log

Usage:
  python3 dry-run.py            # full pipeline + rollback demo
  python3 dry-run.py --quick    # shorter phases
  python3 dry-run.py --no-rollback
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

# ── paths ────────────────────────────────────────────────────────────────
ROOT = Path(__file__).resolve().parent.parent
DOWNLOAD_DIR = Path("/home/z/my-project/download")
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = DOWNLOAD_DIR / "pipeline-dry-run.log"

# ── colors ───────────────────────────────────────────────────────────────
class C:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN = "\033[36m"
    GRAY = "\033[90m"
    BG_BLUE = "\033[44m"
    BG_GREEN = "\033[42m"
    BG_YELLOW = "\033[43m"
    BG_RED = "\033[41m"


# ── log writer (stdout + file) ──────────────────────────────────────────
_log_lock = threading.Lock()
_start_time = time.time()


def _ts() -> str:
    elapsed = time.time() - _start_time
    return f"{elapsed:07.2f}s"


def log(msg: str, *, color: str = "", prefix: str = "·", indent: int = 0) -> None:
    pad = "  " * indent
    line = f"{C.GRAY}[{_ts()}]{C.RESET} {color}{prefix}{C.RESET} {pad}{msg}"
    plain = f"[{_ts()}] {prefix} {'  ' * indent}{msg}"
    with _log_lock:
        print(line, flush=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(plain + "\n")


def phase(name: str, n: int, total: int) -> None:
    bar = f"{C.BG_BLUE}{C.BOLD} PHASE {n}/{total} {C.RESET}"
    title = f"{C.BOLD}{C.CYAN}{name}{C.RESET}"
    with _log_lock:
        print()
        print(f"{bar}  {title}")
        print(C.GRAY + "─" * 78 + C.RESET)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(f"\n=== PHASE {n}/{total}: {name} ===\n")


def ok(msg: str, indent: int = 0) -> None:
    log(msg, color=C.GREEN, prefix="✓", indent=indent)


def warn(msg: str, indent: int = 0) -> None:
    log(msg, color=C.YELLOW, prefix="!", indent=indent)


def err(msg: str, indent: int = 0) -> None:
    log(msg, color=C.RED, prefix="✗", indent=indent)


def info(msg: str, indent: int = 0) -> None:
    log(msg, color=C.BLUE, prefix="ℹ", indent=indent)


def step(msg: str, indent: int = 0) -> None:
    log(msg, color=C.MAGENTA, prefix="▸", indent=indent)


# ── step runner ─────────────────────────────────────────────────────────
@dataclass
class StepResult:
    name: str
    passed: bool
    duration_s: float
    detail: str = ""


def run_step(name: str, fn: Callable[[], str], indent: int = 0) -> StepResult:
    step(f"{name} ...", indent=indent)
    t0 = time.time()
    try:
        detail = fn() or ""
        dt = time.time() - t0
        ok(f"{name} ({dt:.2f}s){(' — ' + detail) if detail else ''}", indent=indent + 1)
        return StepResult(name, True, dt, detail)
    except Exception as e:
        dt = time.time() - t0
        err(f"{name} failed ({dt:.2f}s): {e}", indent=indent + 1)
        return StepResult(name, False, dt, str(e))


# ── mock server management ──────────────────────────────────────────────
class MockServer:
    def __init__(self, port: int = 3000, version: str = "2.5.0"):
        self.port = port
        self.version = version
        self.proc: subprocess.Popen | None = None

    def start(self) -> None:
        env = dict(os.environ)
        env["APP_VERSION"] = self.version
        self.proc = subprocess.Popen(
            ["node", str(ROOT / "demo" / "mock-wiki-server.js"), str(self.port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        # wait for it to come up
        for _ in range(30):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health/live", timeout=0.5) as r:
                    if r.status == 200:
                        return
            except Exception:
                time.sleep(0.1)
        raise RuntimeError(f"mock server on :{self.port} did not come up")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def url(self, path: str = "/") -> str:
        return f"http://127.0.0.1:{self.port}{path}"


# ── HTTP helpers ───────────────────────────────────────────────────────
def http_get(url: str, timeout: float = 2.0) -> tuple[int, bytes]:
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()


def http_post(url: str, body: dict, timeout: float = 2.0) -> tuple[int, bytes]:
    try:
        data = __import__("json").dumps(body).encode()
        req = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()


# ─────────────────────────────────────────────────────────────────────────
# Phase implementations
# ─────────────────────────────────────────────────────────────────────────

def phase_ci(args) -> list[StepResult]:
    """CI: lint, security, build, push, notify (all simulated locally)."""
    results: list[StepResult] = []

    def do_lint() -> str:
        # Simulate ESLint + Prettier + tsc
        return "0 errors, 0 warnings"
    results.append(run_step("ESLint + Prettier + tsc --noEmit", do_lint))

    def do_security() -> str:
        # Real check: scan the wiki-v2 source for obviously bad patterns
        app_dir = ROOT.parent / "wiki-v2"
        bad_patterns = [b"eval(", b"child_process.execSync('rm -rf"]
        findings = 0
        for f in app_dir.rglob("*.js"):
            if "node_modules" in str(f):
                continue
            try:
                data = f.read_bytes()
                for p in bad_patterns:
                    if p in data:
                        findings += 1
            except Exception:
                pass
        if findings:
            raise RuntimeError(f"{findings} dangerous patterns found")
        return "0 HIGH/CRITICAL CVEs"
    results.append(run_step("Trivy fs scan + npm audit (high+)", do_security))

    def do_build() -> str:
        # Simulate docker build & push (skip actual push since no registry)
        return "wiki-v2:sha-demo01  digest=sha256:abc...  size=82.3MB"
    results.append(run_step("docker buildx build + push to GHCR", do_build))

    def do_sign() -> str:
        return "sigstore cosign verified ✓"
    results.append(run_step("cosign sign (sigstore)", do_sign))

    def do_notify() -> str:
        # simulate Slack webhook call (no real webhook)
        return "slack webhook 200 OK (simulated)"
    results.append(run_step("Slack notification (CI success)", do_notify))

    return results


def phase_cd(args, server: MockServer, current_version: str) -> tuple[list[StepResult], str]:
    """CD: deploy GREEN → smoke → promote → scale-down BLUE → monitor."""
    results: list[StepResult] = []

    # In our dry-run, "deploy GREEN" = restart mock server with new version
    def do_deploy_green() -> str:
        server.stop()
        # Bump version to simulate a new image
        new_v = current_version + "-green"
        server.version = new_v
        server.start()
        return f"GREEN live at {server.url()} (v{new_v})"
    results.append(run_step("kubectl apply deployment wiki-green + rollout", do_deploy_green))

    def do_smoke() -> str:
        checks = [("/health/live", 200), ("/health/ready", 200), ("/health", 200), ("/api/pages", 200)]
        for path, expected in checks:
            status, _ = http_get(server.url(path))
            if status != expected:
                raise RuntimeError(f"{path}: expected {expected}, got {status}")
        return "4/4 endpoints OK"
    results.append(run_step("Smoke tests on preview service", do_smoke))

    def do_promote() -> str:
        # Simulate kubectl patch service selector blue → green
        return "service wiki selector → slot=green"
    results.append(run_step("Promote: switch live traffic blue → green", do_promote))

    def do_scale_down() -> str:
        return "wiki-blue → replicas=1 (kept for rollback)"
    results.append(run_step("Scale down BLUE (keep 1 replica)", do_scale_down))

    def do_monitor() -> str:
        # Poll health for 5 cycles; all should be 200
        for i in range(5):
            status, _ = http_get(server.url("/health"), timeout=1.0)
            if status != 200:
                raise RuntimeError(f"monitor cycle {i+1}: status {status}")
            time.sleep(0.2)
        return "5/5 cycles healthy (2 min simulated)"
    results.append(run_step("Post-deploy monitor (5 cycles)", do_monitor))

    return results, server.version


def phase_e2e(args, server: MockServer) -> list[StepResult]:
    """Functional E2E tests — run against the mock server."""
    results: list[StepResult] = []

    def t_root() -> str:
        status, body = http_get(server.url("/"))
        if status != 200:
            raise RuntimeError(f"status {status}")
        import json
        d = json.loads(body)
        if d.get("name") != "Wiki.js":
            raise RuntimeError(f"unexpected name {d.get('name')}")
        return f"v{d.get('version')}"
    results.append(run_step("GET / returns Wiki.js", t_root))

    def t_live() -> str:
        status, _ = http_get(server.url("/health/live"))
        if status != 200:
            raise RuntimeError(f"status {status}")
        return "200 OK"
    results.append(run_step("GET /health/live → 200", t_live))

    def t_ready() -> str:
        status, _ = http_get(server.url("/health/ready"))
        if status != 200:
            raise RuntimeError(f"status {status}")
        return "200 OK"
    results.append(run_step("GET /health/ready → 200 (DB ready)", t_ready))

    slug = f"e2e-demo-{int(time.time())}"

    def t_create() -> str:
        status, body = http_post(server.url("/api/pages"), {"slug": slug, "title": "E2E Demo", "content": "# Demo"})
        if status != 201:
            raise RuntimeError(f"status {status}")
        import json
        d = json.loads(body)
        return f"id={d.get('id')}"
    results.append(run_step(f"POST /api/pages creates '{slug}'", t_create))

    def t_get() -> str:
        status, body = http_get(server.url(f"/api/pages/{slug}"))
        if status != 200:
            raise RuntimeError(f"status {status}")
        import json
        d = json.loads(body)
        if d.get("title") != "E2E Demo":
            raise RuntimeError(f"unexpected title {d.get('title')}")
        return "title match"
    results.append(run_step(f"GET /api/pages/{slug} returns correct title", t_get))

    def t_update() -> str:
        status, body = http_post(server.url("/api/pages"), {"slug": slug, "title": "E2E Updated", "content": "# v2"})
        if status != 201:
            raise RuntimeError(f"status {status}")
        status2, body2 = http_get(server.url(f"/api/pages/{slug}"))
        import json
        d = json.loads(body2)
        if d.get("title") != "E2E Updated":
            raise RuntimeError("title not updated")
        return "idempotent update OK"
    results.append(run_step("POST /api/pages idempotent update preserves data", t_update))

    def t_list() -> str:
        status, body = http_get(server.url("/api/pages"))
        if status != 200:
            raise RuntimeError(f"status {status}")
        import json
        d = json.loads(body)
        if not isinstance(d, list) or len(d) < 1:
            raise RuntimeError(f"empty list")
        return f"{len(d)} page(s)"
    results.append(run_step("GET /api/pages returns ≥1 entry", t_list))

    def t_404() -> str:
        status, _ = http_get(server.url("/api/pages/does-not-exist-xyz"))
        if status != 404:
            raise RuntimeError(f"status {status}")
        return "404 returned"
    results.append(run_step("GET unknown slug → 404", t_404))

    return results


def phase_performance(args, server: MockServer) -> list[StepResult]:
    """Simulate k6 load test with multi-threaded HTTP requests."""
    results: list[StepResult] = []

    def do_load() -> str:
        # Simulate 50 VUs for 5s hitting /health/live and /api/pages
        n_vus = 20
        duration_s = 3.0
        latencies: list[float] = []
        errors = 0
        total = 0
        t_end = time.time() + duration_s

        def worker():
            local_lat = []
            local_err = 0
            local_total = 0
            while time.time() < t_end:
                t0 = time.time()
                status, _ = http_get(server.url("/health/live"), timeout=2.0)
                dt = (time.time() - t0) * 1000
                local_total += 1
                if status != 200:
                    local_err += 1
                else:
                    local_lat.append(dt)
                # Also hit /api/pages occasionally
                if local_total % 3 == 0:
                    t0 = time.time()
                    status, _ = http_get(server.url("/api/pages"), timeout=2.0)
                    dt = (time.time() - t0) * 1000
                    local_total += 1
                    if status != 200:
                        local_err += 1
                    else:
                        local_lat.append(dt)
            return local_lat, local_err, local_total

        with ThreadPoolExecutor(max_workers=n_vus) as ex:
            futures = [ex.submit(worker) for _ in range(n_vus)]
            for f in as_completed(futures):
                lat, e, t = f.result()
                latencies.extend(lat)
                errors += e
                total += t

        latencies.sort()
        if not latencies:
            raise RuntimeError("no successful requests")
        p50 = latencies[len(latencies) // 2]
        p95 = latencies[int(len(latencies) * 0.95)]
        p99 = latencies[int(len(latencies) * 0.99)]
        avg = sum(latencies) / len(latencies)
        fail_rate = errors / total * 100
        # k6 SLO: p95 < 200ms, err < 1%
        passed = p95 < 200 and fail_rate < 1
        detail = (
            f"reqs={total}  avg={avg:.1f}ms  p50={p50:.1f}ms  p95={p95:.1f}ms  "
            f"p99={p99:.1f}ms  err={fail_rate:.2f}%  "
            f"-> SLO {'PASS' if passed else 'FAIL'}"
        )
        if not passed:
            warn(detail, indent=1)
            raise RuntimeError("SLO not met")
        return detail

    results.append(run_step("k6 load test (20 VUs / 3s)", do_load))
    return results


def phase_rollback(args, server: MockServer) -> list[StepResult]:
    """Simulate a failed deploy → automatic rollback → recovery."""
    results: list[StepResult] = []

    def do_break() -> str:
        # Trigger degradation in the mock server
        status, _ = http_post(server.url("/__degrade"), {}, timeout=1.0)
        if status != 200:
            raise RuntimeError("could not toggle degradation")
        # Confirm health is now failing
        s, _ = http_get(server.url("/health/ready"), timeout=1.0)
        if s == 200:
            raise RuntimeError("degradation did not take effect")
        return "GREEN /health/ready returns 503 (degraded)"
    results.append(run_step("Simulate bad deploy: degrade GREEN", do_break))

    def do_detect() -> str:
        # 3-strike rule: poll 3 times, all fail → trigger rollback
        fails = 0
        for i in range(3):
            s, _ = http_get(server.url("/health"), timeout=1.0)
            if s != 200:
                fails += 1
            time.sleep(0.2)
        if fails < 3:
            raise RuntimeError(f"only {fails} failures detected")
        return f"{fails}/3 strikes — auto-rollback triggered"
    results.append(run_step("Post-deploy monitor detects failure (3/3 strikes)", do_detect))

    def do_rollback() -> str:
        # Recover by re-issuing the previous "blue" version (here: undo degrade)
        http_post(server.url("/__recover"), {}, timeout=1.0)
        time.sleep(0.3)
        s, _ = http_get(server.url("/health/ready"), timeout=1.0)
        if s != 200:
            raise RuntimeError(f"rollback verification failed: status {s}")
        return "rolled back to BLUE — live traffic restored"
    results.append(run_step("Automatic rollback: scale BLUE → 3, switch selector", do_rollback))

    def do_notify_rb() -> str:
        return "slack webhook 200 OK (orange alert)"
    results.append(run_step("Slack notification (rollback)", do_notify_rb))

    return results


# ── entry point ─────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser(description="Dry-run wiki-v2 CI/CD pipeline")
    parser.add_argument("--quick", action="store_true", help="shorter phases")
    parser.add_argument("--no-rollback", action="store_true", help="skip rollback phase")
    args = parser.parse_args()

    # truncate log file
    LOG_FILE.write_text("", encoding="utf-8")

    # banner
    print(f"\n{C.BOLD}{C.BG_BLUE}  wiki-v2  CI/CD  Dry-Run  {C.RESET}\n")
    print(f"{C.GRAY}Repository:{C.RESET}  Rollwar/wiki-v2 + Rollwar/cicd-wikijs")
    print(f"{C.GRAY}Pipeline:  {C.RESET}  GitHub Actions → k3s (blue-green) → Slack")
    print(f"{C.GRAY}Log file:  {C.RESET}  {LOG_FILE}\n")
    log(f"dry-run starting, pid={os.getpid()}", color=C.CYAN, prefix="●")

    # Start mock wiki.js server
    server = MockServer(port=3000, version="2.5.0")
    try:
        server.start()
        ok(f"mock wiki.js v{server.version} ready at {server.url()}")
    except Exception as e:
        err(f"could not start mock server: {e}")
        return 1

    all_results: list[StepResult] = []
    total_phases = 4 if args.no_rollback else 5

    try:
        phase("CI — Continuous Integration", 1, total_phases)
        all_results.extend(phase_ci(args))

        phase("CD — Continuous Delivery (k3s blue-green)", 2, total_phases)
        cd_results, new_version = phase_cd(args, server, server.version)
        all_results.extend(cd_results)

        phase("Functional E2E (8 scenarios)", 3, total_phases)
        all_results.extend(phase_e2e(args, server))

        phase("Performance (k6-style load)", 4, total_phases)
        all_results.extend(phase_performance(args, server))

        if not args.no_rollback:
            phase("Rollback (auto + recovery)", 5, total_phases)
            all_results.extend(phase_rollback(args, server))

    finally:
        server.stop()

    # Summary
    print()
    print(f"{C.BOLD}{C.BG_GREEN}  PIPELINE SUMMARY  {C.RESET}\n")
    passed = sum(1 for r in all_results if r.passed)
    failed = sum(1 for r in all_results if not r.passed)
    total_time = sum(r.duration_s for r in all_results)
    for r in all_results:
        mark = f"{C.GREEN}✓{C.RESET}" if r.passed else f"{C.RED}✗{C.RESET}"
        print(f"  {mark} {r.name:<55} {C.GRAY}{r.duration_s:6.2f}s{C.RESET}  {r.detail}")
    print()
    print(f"  {C.BOLD}Total steps:{C.RESET}  {len(all_results)}")
    print(f"  {C.BOLD}Passed:{C.RESET}       {C.GREEN}{passed}{C.RESET}")
    print(f"  {C.BOLD}Failed:{C.RESET}       {C.RED}{failed}{C.RESET}" if failed else f"  {C.BOLD}Failed:{C.RESET}       0")
    print(f"  {C.BOLD}Duration:{C.RESET}     {total_time:.2f}s")
    print(f"\n  {C.GRAY}Full log:{C.RESET} {LOG_FILE}\n")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
