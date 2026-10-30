/**
 * tests/e2e/e2e.test.js — Jest wrapper around the same scenarios as run.sh.
 * Useful for IDE / local `npm test`.
 * Standalone: does not require Jest; can be run with `node tests/e2e/e2e.test.js`.
 */
'use strict'

const http = require('http')
const assert = require('assert')

const WIKI_URL = process.env.WIKI_URL || 'http://localhost:3000'

function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, WIKI_URL)
    const data = body ? JSON.stringify(body) : null
    const req = http.request(
      {
        method,
        hostname: url.hostname,
        port: url.port,
        path: url.pathname,
        headers: data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}
      },
      (res) => {
        let buf = ''
        res.on('data', (c) => (buf += c))
        res.on('end', () => resolve({ status: res.statusCode, body: buf }))
      }
    )
    req.on('error', reject)
    if (data) req.write(data)
    req.end()
  })
}

async function run() {
  const results = { pass: 0, fail: 0, items: [] }
  const check = async (name, fn) => {
    try {
      await fn()
      results.pass++
      results.items.push(`✓ ${name}`)
    } catch (e) {
      results.fail++
      results.items.push(`✗ ${name} — ${e.message}`)
    }
  }

  await check('GET / returns Wiki.js', async () => {
    const r = await request('GET', '/')
    assert.strictEqual(r.status, 200)
    assert.strictEqual(JSON.parse(r.body).name, 'Wiki.js')
  })

  await check('GET /health/live → 200', async () => {
    const r = await request('GET', '/health/live')
    assert.strictEqual(r.status, 200)
  })

  await check('GET /health/ready → 200', async () => {
    const r = await request('GET', '/health/ready')
    assert.strictEqual(r.status, 200)
  })

  const slug = `jest-${Date.now()}`
  await check(`POST /api/pages creates "${slug}"`, async () => {
    const r = await request('POST', '/api/pages', { slug, title: 'Jest Page', content: '# Jest' })
    assert.strictEqual(r.status, 201)
  })

  await check(`GET /api/pages/${slug} returns the page`, async () => {
    const r = await request('GET', `/api/pages/${slug}`)
    assert.strictEqual(r.status, 200)
    assert.strictEqual(JSON.parse(r.body).title, 'Jest Page')
  })

  await check('Idempotent update preserves id', async () => {
    const r = await request('POST', '/api/pages', { slug, title: 'Jest v2', content: '# v2' })
    assert.strictEqual(r.status, 201)
    const g = await request('GET', `/api/pages/${slug}`)
    assert.strictEqual(JSON.parse(g.body).title, 'Jest v2')
  })

  await check('GET unknown slug → 404', async () => {
    const r = await request('GET', '/api/pages/definitely-not-real-xyz')
    assert.strictEqual(r.status, 404)
  })

  console.log('\n═══ E2E TEST RESULTS ═══')
  results.items.forEach((i) => console.log(i))
  console.log('────────────────────────')
  console.log(`Passed: ${results.pass}  Failed: ${results.fail}`)
  process.exit(results.fail > 0 ? 1 : 0)
}

run().catch((e) => {
  console.error(e)
  process.exit(1)
})
