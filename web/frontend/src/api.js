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
