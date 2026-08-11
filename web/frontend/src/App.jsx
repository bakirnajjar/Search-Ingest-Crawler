import { useState } from 'react'
import { search } from './api'
import Chat from './Chat'
import SmartSearch from './SmartSearch'
import ResultCard, { isArabic } from './ResultCard'

const FILTER_FIELDS = ['language', 'section', 'kind']

export default function App() {
  const [mode, setMode] = useState('search')
  return (
    <>
      <nav className="topnav">
        <span className="brand">Site Search</span>
        <div className="tabs">
          <button className={mode === 'search' ? 'active' : ''} onClick={() => setMode('search')}>Search</button>
          <button className={mode === 'smart' ? 'active' : ''} onClick={() => setMode('smart')}>Smart Search</button>
          <button className={mode === 'chat' ? 'active' : ''} onClick={() => setMode('chat')}>Ask AI</button>
        </div>
      </nav>
      {mode === 'search' && <SearchView />}
      {mode === 'smart' && <SmartSearch />}
      {mode === 'chat' && <Chat />}
    </>
  )
}

function SearchView() {
  const [q, setQ] = useState('')
  const [filters, setFilters] = useState({ language: '', section: '', kind: '' })
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [searched, setSearched] = useState(false)

  async function run(overrideFilters) {
    const query = q.trim()
    if (!query) return
    setLoading(true)
    setError('')
    setSearched(true)
    try {
      const res = await search({ q: query, filters: overrideFilters ?? filters, top: 20 })
      setData(res)
    } catch (err) {
      setError(err.message)
      setData(null)
    } finally {
      setLoading(false)
    }
  }

  function onSubmit(e) {
    e.preventDefault()
    run()
  }

  function toggleFacet(field, value) {
    const next = { ...filters, [field]: filters[field] === value ? '' : value }
    setFilters(next)
    run(next)
  }

  const rtl = isArabic(q)
  const answer = data?.answers?.[0]
  const hasFacets = data && FILTER_FIELDS.some((f) => data.facets?.[f]?.length)

  return (
    <div className="app">
      <header className="hero">
        <h1>Site Search</h1>
        <p className="sub">Hybrid + semantic + vector search over crawled content.</p>
        <form onSubmit={onSubmit} className="searchbar" dir={rtl ? 'rtl' : 'ltr'}>
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search pages, documents, images, snapshots…"
            aria-label="Search query"
            autoFocus
          />
          <button type="submit" disabled={loading || !q.trim()}>
            {loading ? '…' : 'Search'}
          </button>
        </form>
      </header>

      {error && <p className="error" role="alert">{error}</p>}

      {data && (
        <div className="layout">
          {hasFacets && (
            <aside className="facets" aria-label="Filters">
              {FILTER_FIELDS.map((field) =>
                data.facets?.[field]?.length ? (
                  <div key={field} className="facet-group">
                    <h3>{field}</h3>
                    {data.facets[field].map((f) => (
                      <label
                        key={f.value}
                        className={filters[field] === f.value ? 'active' : ''}
                      >
                        <input
                          type="checkbox"
                          checked={filters[field] === f.value}
                          onChange={() => toggleFacet(field, f.value)}
                        />
                        <span className="facet-value">{f.value}</span>
                        <span className="count">{f.count}</span>
                      </label>
                    ))}
                  </div>
                ) : null,
              )}
            </aside>
          )}

          <main className="results">
            {answer && (
              <div className="answer" dir={isArabic(answer.text) ? 'rtl' : 'ltr'}>
                <span className="answer-label">Answer</span>
                <p>{answer.text}</p>
              </div>
            )}

            {searched && !loading && data.results.length === 0 && (
              <p className="empty">No results found.</p>
            )}

            {data.results.map((r, i) => (
              <ResultCard key={r.parentId || r.sourceUrl || i} r={r} />
            ))}
          </main>
        </div>
      )}

      {!data && !loading && (
        <p className="hint">Type a query to search crawled pages, documents, images, and snapshots.</p>
      )}
    </div>
  )
}
