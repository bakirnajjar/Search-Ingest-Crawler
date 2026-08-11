import { useState } from 'react'
import { smartSearch, search } from './api'
import ResultCard, { isArabic } from './ResultCard'

const FILTER_FIELDS = ['language', 'section', 'kind']

export default function SmartSearch() {
  const [input, setInput] = useState('')
  const [interpreted, setInterpreted] = useState(null)
  const [filters, setFilters] = useState({})
  const [view, setView] = useState(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [searched, setSearched] = useState(false)

  async function runSmart(e) {
    e?.preventDefault()
    const q = input.trim()
    if (!q) return
    setLoading(true)
    setError('')
    setSearched(true)
    try {
      const res = await smartSearch({ q, top: 20 })
      setInterpreted(res.interpreted)
      setFilters(res.interpreted.filters || {})
      setView({ answers: res.answers, results: res.results })
    } catch (err) {
      setError(err.message)
      setInterpreted(null)
      setView(null)
    } finally {
      setLoading(false)
    }
  }

  // Refine locally without another LLM call: re-run the plain search with fewer filters.
  async function removeFilter(field) {
    const next = { ...filters }
    delete next[field]
    setFilters(next)
    setLoading(true)
    setError('')
    try {
      const res = await search({ q: interpreted.keywords, filters: next, top: 20 })
      setView({ answers: res.answers, results: res.results })
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const rtl = isArabic(input)
  const answer = view?.answers?.[0]
  const activeFilters = FILTER_FIELDS.filter((f) => filters[f])

  return (
    <div className="app">
      <header className="hero">
        <h1>Smart Search</h1>
        <p className="sub">Ask in plain language — keywords and filters are extracted for you.</p>
        <form onSubmit={runSmart} className="searchbar" dir={rtl ? 'rtl' : 'ltr'}>
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder="e.g. arabic pdf about roaming packs"
            aria-label="Smart search query"
            autoFocus
          />
          <button type="submit" disabled={loading || !input.trim()}>
            {loading ? '…' : 'Search'}
          </button>
        </form>
      </header>

      {error && <p className="error" role="alert">{error}</p>}

      {interpreted && (
        <div className="interpreted" dir={isArabic(interpreted.keywords) ? 'rtl' : 'ltr'}>
          <div className="interpreted-row">
            <span className="interpreted-label">Keywords</span>
            <span className="interpreted-keywords">{interpreted.keywords || '—'}</span>
          </div>
          {activeFilters.length > 0 && (
            <div className="interpreted-row">
              <span className="interpreted-label">Filters</span>
              <div className="chips">
                {activeFilters.map((f) => (
                  <button
                    key={f}
                    className="chip"
                    onClick={() => removeFilter(f)}
                    title="Remove filter"
                  >
                    {f}: {filters[f]} <span className="chip-x">✕</span>
                  </button>
                ))}
              </div>
            </div>
          )}
          {interpreted.notes && <p className="interpreted-notes">{interpreted.notes}</p>}
        </div>
      )}

      {view && (
        <main className="results">
          {answer && (
            <div className="answer" dir={isArabic(answer.text) ? 'rtl' : 'ltr'}>
              <span className="answer-label">Answer</span>
              <p>{answer.text}</p>
            </div>
          )}

          {searched && !loading && view.results.length === 0 && (
            <p className="empty">No results found.</p>
          )}

          {view.results.map((r, i) => (
            <ResultCard key={r.parentId || r.sourceUrl || i} r={r} />
          ))}
        </main>
      )}

      {!view && !loading && (
        <p className="hint">Describe what you're looking for and let the model build the query.</p>
      )}
    </div>
  )
}
