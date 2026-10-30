/**
 * tests/performance/parse-results.js — parses k6 summary JSON,
 * emits a markdown report, prints pass/fail decision.
 * Usage: node parse-results.js /tmp/k6-summary.json
 */
'use strict'

const fs = require('fs')

const file = process.argv[2]
if (!file || !fs.existsSync(file)) {
  console.error('Usage: node parse-results.js <k6-summary.json>')
  process.exit(2)
}

const data = JSON.parse(fs.readFileSync(file, 'utf8'))
const m = data.metrics || {}

const reqs = m.http_reqs?.values?.count || 0
const dur = m.http_req_duration?.values || {}
const failed = m.http_req_failed?.values || {}
const checks = m.checks?.values || {}

const p95 = dur['p(95)'] ?? 0
const p99 = dur['p(99)'] ?? 0
const avg = dur.avg ?? 0
const failRate = (failed.rate ?? 0) * 100

const SLO_P95_MS = 200
const SLO_FAIL_RATE = 1.0

const passed = p95 < SLO_P95_MS && failRate < SLO_FAIL_RATE

const md = `# k6 Performance Report

**Generated:** ${new Date().toISOString()}
**Duration:** ${data.state?.testRunDurationMs ?? 'n/a'} ms
**Total requests:** ${reqs}

## Latency

| Metric | Value |
|--------|-------|
| avg   | ${avg.toFixed(2)} ms |
| p(50) | ${(dur['p(50)'] ?? 0).toFixed(2)} ms |
| p(95) | ${p95.toFixed(2)} ms |
| p(99) | ${p99.toFixed(2)} ms |

## Errors & Checks

| Metric | Value |
|--------|-------|
| http_req_failed | ${failRate.toFixed(2)} % |
| checks passed   | ${checks.passes ?? 0} / ${(checks.passes ?? 0) + (checks.fails ?? 0)} |

## SLO Thresholds

| SLO | Threshold | Actual | Result |
|-----|-----------|--------|--------|
| p(95) latency | < ${SLO_P95_MS} ms | ${p95.toFixed(2)} ms | ${p95 < SLO_P95_MS ? 'PASS' : 'FAIL'} |
| error rate    | < ${SLO_FAIL_RATE}% | ${failRate.toFixed(2)}% | ${failRate < SLO_FAIL_RATE ? 'PASS' : 'FAIL'} |

**Overall:** ${passed ? 'PASS' : 'FAIL'}
`

console.log(md)
process.exit(passed ? 0 : 1)
