import { useRef, useState } from 'react'
import { streamChat } from './api'

const isArabic = (s) => /[\u0600-\u06FF]/.test(s || '')

// Render [n] citation markers as superscript chips (React escapes text -> XSS-safe).
function renderAnswer(text) {
  return String(text)
    .split(/(\[\d+\])/g)
    .map((part, i) => (/^\[\d+\]$/.test(part) ? <sup key={i} className="cite">{part}</sup> : part))
}

export default function Chat() {
  const [messages, setMessages] = useState([])
  const [input, setInput] = useState('')
  const [busy, setBusy] = useState(false)
  const listRef = useRef(null)

  function patchLast(fn) {
    setMessages((msgs) => {
      const copy = msgs.slice()
      copy[copy.length - 1] = fn(copy[copy.length - 1])
      return copy
    })
    requestAnimationFrame(() => {
      if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight
    })
  }

  async function send(text) {
    const q = (text ?? input).trim()
    if (!q || busy) return
    setInput('')
    const history = [...messages, { role: 'user', content: q }]
    setMessages([...history, { role: 'assistant', content: '', sources: [], streaming: true }])
    setBusy(true)
    try {
      await streamChat(
        history.map(({ role, content }) => ({ role, content })),
        {
          onSources: (sources) => patchLast((m) => ({ ...m, sources })),
          onToken: (t) => patchLast((m) => ({ ...m, content: m.content + t })),
          onDone: (d) => patchLast((m) => ({ ...m, citations: d.citations, followups: d.followups, streaming: false })),
          onError: (msg) => patchLast((m) => ({ ...m, content: m.content || `\u26a0\ufe0f ${msg}`, streaming: false })),
        },
      )
    } catch (err) {
      patchLast((m) => ({ ...m, content: m.content || `\u26a0\ufe0f ${err.message}`, streaming: false }))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="app chat-app">
      <div className="chat-list" ref={listRef}>
        {messages.length === 0 && (
          <p className="hint">Ask a question about the crawled content — answers are grounded in the indexed sources.</p>
        )}
        {messages.map((m, i) => (
          <div key={i} className={`bubble ${m.role}`} dir={isArabic(m.content) ? 'rtl' : 'ltr'}>
            {m.role === 'assistant' ? (
              <>
                <div className="answer-text">
                  {renderAnswer(m.content)}
                  {m.streaming && <span className="cursor">▋</span>}
                </div>
                {m.sources?.length > 0 && (
                  <details className="chat-sources">
                    <summary>{m.sources.length} sources</summary>
                    <ol>
                      {m.sources.map((s) => (
                        <li key={s.n}>
                          <a href={s.sourceUrl} target="_blank" rel="noreferrer">{s.title}</a>
                          {s.kind && <span className="badge muted">{s.kind}</span>}
                        </li>
                      ))}
                    </ol>
                  </details>
                )}
                {m.followups?.length > 0 && (
                  <div className="followups">
                    {m.followups.map((f, k) => (
                      <button key={k} onClick={() => send(f)} disabled={busy}>{f}</button>
                    ))}
                  </div>
                )}
              </>
            ) : (
              <p>{m.content}</p>
            )}
          </div>
        ))}
      </div>

      <form
        className="chat-input"
        onSubmit={(e) => {
          e.preventDefault()
          send()
        }}
        dir={isArabic(input) ? 'rtl' : 'ltr'}
      >
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Ask about the site…"
          aria-label="Ask a question"
          disabled={busy}
          autoFocus
        />
        <button type="submit" disabled={busy || !input.trim()}>{busy ? '…' : 'Send'}</button>
      </form>
    </div>
  )
}
