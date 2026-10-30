/**
 * demo/mock-wiki-server.js — tiny in-memory stand-in for wiki.js used by the
 * dry-run demo. Mirrors the same HTTP contract as wiki-v2/server.js so the
 * same E2E / smoke / k6 tests can run against it.
 *
 * Usage: node mock-wiki-server.js [port]
 *   default port: 3000
 */
'use strict'

const http = require('http')

const PORT = parseInt(process.argv[2] || '3000', 10)
const VERSION = process.env.APP_VERSION || '2.5.0'

const pages = new Map()
let startedAt = Date.now()
let degrade = false // when true, /health/ready returns 503 (simulates a broken deploy)

function send(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers })
  res.end(typeof body === 'string' ? body : JSON.stringify(body))
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`)

  if (req.method === 'GET' && url.pathname === '/') {
    return send(res, 200, { name: 'Wiki.js', version: VERSION })
  }
  if (req.method === 'GET' && url.pathname === '/health/live') {
    return send(res, 200, { status: 'alive', uptime: (Date.now() - startedAt) / 1000 })
  }
  if (req.method === 'GET' && url.pathname === '/health/ready') {
    if (degrade) return send(res, 503, { status: 'not ready', error: 'simulated degradation' })
    return send(res, 200, { status: 'ready' })
  }
  if (req.method === 'GET' && url.pathname === '/health') {
    if (degrade) return send(res, 503, { status: 'unhealthy', error: 'simulated' })
    return send(res, 200, { status: 'ok', uptime: (Date.now() - startedAt) / 1000 })
  }
  if (req.method === 'GET' && url.pathname === '/api/pages') {
    const list = Array.from(pages.values()).map((p) => ({
      id: p.id,
      slug: p.slug,
      title: p.title,
      updated_at: p.updated_at
    }))
    return send(res, 200, list)
  }
  if (req.method === 'GET' && url.pathname.startsWith('/api/pages/')) {
    const slug = url.pathname.split('/').pop()
    const page = pages.get(slug)
    if (!page) return send(res, 404, { error: 'Page not found' })
    return send(res, 200, page)
  }
  if (req.method === 'POST' && url.pathname === '/api/pages') {
    let buf = ''
    req.on('data', (c) => (buf += c))
    req.on('end', () => {
      try {
        const { slug, title, content } = JSON.parse(buf)
        if (!slug || !title || !content) return send(res, 400, { error: 'slug, title, content required' })
        const existing = pages.get(slug)
        const id = existing ? existing.id : pages.size + 1
        const page = { id, slug, title, content, updated_at: new Date().toISOString() }
        pages.set(slug, page)
        return send(res, 201, { id, slug, title })
      } catch (e) {
        return send(res, 400, { error: 'invalid json' })
      }
    })
    return
  }
  // Hidden endpoint to toggle degradation — used by demo to show auto-rollback
  if (req.method === 'POST' && url.pathname === '/__degrade') {
    degrade = true
    return send(res, 200, { degraded: true })
  }
  if (req.method === 'POST' && url.pathname === '/__recover') {
    degrade = false
    return send(res, 200, { degraded: false })
  }
  send(res, 404, { error: 'not found', path: url.pathname })
})

server.listen(PORT, '127.0.0.1', () => {
  // eslint-disable-next-line no-console
  console.log(`[mock-wiki] v${VERSION} listening on http://127.0.0.1:${PORT}`)
})

process.on('SIGTERM', () => server.close(() => process.exit(0)))
process.on('SIGINT', () => server.close(() => process.exit(0)))
