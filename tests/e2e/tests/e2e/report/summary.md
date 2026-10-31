# E2E Test Report

**Target:** `http://wiki.k8s-3.sa/`
**Date:** 2026-10-31T16:19:56Z
**Total:** 8  |  **Passed:** 2  |  **Failed:** 6

## Results

-   ✗ GET / name match — got ''
-   ✓ GET /health/live → 200
-   ✓ GET /health/ready → 200
-   ✗ POST /api/pages → 201 — status=404
-   ✗ GET page title matches — got ''
-   ✗ POST /api/pages → 201 (update) — status=404
-   ✗ GET /api/pages returns entries — count=0
-   ✗ GET unknown slug → 404 — status=200
