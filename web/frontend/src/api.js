const FILTER_FIELDS = ['language', 'section', 'kind']

export async function search({ q, filters, top = 20, skip = 0 }) {
  const qs = new URLSearchParams()
  qs.set('q', q)
  qs.set('top', String(top))
  qs.set('skip', String(skip))
  FILTER_FIELDS.forEach((f) => {
    if (filters?.[f]) qs.set(f, filters[f])
  })
  const res = await fetch(`/api/search?${qs.toString()}`)
  if (!res.ok) throw new Error(`Search failed (${res.status})`)
  return res.json()
}

export function thumbnailUrl(sourceUrl) {
  return `/api/thumbnail?url=${encodeURIComponent(sourceUrl)}`
}

// GET /api/search/smart — LLM extracts keywords + filters, then runs the search.
export async function smartSearch({ q, top = 20, skip = 0 }) {
  const qs = new URLSearchParams({ q, top: String(top), skip: String(skip) })
  const res = await fetch(`/api/search/smart?${qs.toString()}`)
  if (!res.ok) throw new Error(`Smart search failed (${res.status})`)
  return res.json()
}

// POST /api/chat and parse the Server-Sent Events stream.
export async function streamChat(messages, { onSources, onToken, onDone, onError, signal } = {}) {
  const res = await fetch('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ messages }),
    signal,
  })
  if (!res.ok || !res.body) throw new Error(`Chat failed (${res.status})`)
  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  for (;;) {
    const { value, done } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    const blocks = buffer.split('\n\n')
    buffer = blocks.pop() ?? ''
    for (const block of blocks) {
      let event = 'message'
      let data = ''
      for (const line of block.split('\n')) {
        if (line.startsWith('event:')) event = line.slice(6).trim()
        else if (line.startsWith('data:')) data += line.slice(5).trim()
      }
      if (!data) continue
      let parsed
      try { parsed = JSON.parse(data) } catch { continue }
      if (event === 'sources') onSources?.(parsed.sources || [])
      else if (event === 'token') onToken?.(parsed.t || '')
      else if (event === 'done') onDone?.(parsed)
      else if (event === 'error') onError?.(parsed.message || 'error')
    }
  }
}
