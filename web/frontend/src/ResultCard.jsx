import { thumbnailUrl } from './api'

const isArabic = (s) => /[\u0600-\u06FF]/.test(s || '')

export default function ResultCard({ r }) {
  return (
    <article className="card" dir={r.language === 'ar' ? 'rtl' : 'ltr'}>
      {r.sourceUrl && (
        <img
          className="thumb"
          src={thumbnailUrl(r.sourceUrl)}
          alt=""
          loading="lazy"
          onError={(e) => {
            e.currentTarget.style.display = 'none'
          }}
        />
      )}
      <div className="card-body">
        <a className="title" href={r.sourceUrl} target="_blank" rel="noreferrer">
          {r.title}
        </a>
        <div className="meta">
          {r.kind && <span className="badge">{r.kind}</span>}
          {r.section && <span className="badge muted">{r.section}</span>}
          {r.language && <span className="badge muted">{r.language}</span>}
          {typeof r.reranker === 'number' && (
            <span className="score">rerank {r.reranker.toFixed(2)}</span>
          )}
        </div>
        {(r.caption || r.snippet) && <p className="snippet">{r.caption || r.snippet}</p>}
        {r.sourceUrl && (
          <a className="url" href={r.sourceUrl} target="_blank" rel="noreferrer">
            {r.sourceUrl}
          </a>
        )}
      </div>
    </article>
  )
}

export { isArabic }
