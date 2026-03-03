/**
 * BillingGate.tsx
 * Amalfi AI billing kill switch — add to any client app.
 *
 * Checks AOS Supabase on every app load.
 * If the client's status is 'paused', shows a maintenance page instead of the app.
 * Fails open — if the network call fails, the app loads normally.
 *
 * Usage in App.tsx:
 *   import BillingGate from './components/BillingGate'
 *   <BillingGate slug="ascend_lc"><YourApp /></BillingGate>
 *
 * To remove when client is handed over:
 *   Delete this file + remove the wrapper from App.tsx. No env vars to clean up.
 */

import { useEffect, useState, ReactNode } from 'react'

// AOS Supabase — anon key is public (read-only, Supabase-standard for client-side use)
const AOS_URL = 'https://afmpbtynucpbglwtbfuz.supabase.co'
const AOS_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ'

type BillingStatus = 'active' | 'paused' | 'stopped' | 'loading' | 'unknown'

interface BillingGateProps {
  children: ReactNode
  slug: string  // client slug: 'ascend_lc' | 'race_technik' | 'favorite_logistics' | etc.
}

export default function BillingGate({ children, slug }: BillingGateProps) {
  const [status, setStatus]   = useState<BillingStatus>('loading')
  const [message, setMessage] = useState<string>('')

  useEffect(() => {
    if (!slug) {
      setStatus('active')
      return
    }

    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 6000)

    fetch(
      `${AOS_URL}/rest/v1/clients?slug=eq.${slug}&select=status,notes`,
      {
        headers: { apikey: AOS_KEY, Authorization: `Bearer ${AOS_KEY}` },
        signal: controller.signal,
      }
    )
      .then(r => r.json())
      .then((rows: Array<{ status: string; notes: string | null }>) => {
        clearTimeout(timeout)
        if (!rows || rows.length === 0) {
          setStatus('active') // not in registry — fail open
          return
        }
        const row = rows[0]
        const isPaused = row.status === 'paused' || row.status === 'stopped'
        setStatus(isPaused ? (row.status as BillingStatus) : 'active')
        // Extract pause message from notes field (stored as "PAUSE_MSG:..." prefix)
        const notes = row.notes || ''
        const msgLine = notes.split('\n').find(l => l.startsWith('PAUSE_MSG:'))
        setMessage(msgLine ? msgLine.replace('PAUSE_MSG:', '').trim() : 'Service temporarily unavailable.')
      })
      .catch(() => {
        clearTimeout(timeout)
        setStatus('active') // network error — fail open
      })

    return () => {
      clearTimeout(timeout)
      controller.abort()
    }
  }, [])

  if (status === 'loading') {
    // Brief invisible loading state — resolves in <1s
    return null
  }

  if (status === 'paused' || status === 'stopped') {
    return <MaintenancePage status={status} message={message} />
  }

  return <>{children}</>
}

// ── Maintenance Page ──────────────────────────────────────────────────────────

function MaintenancePage({ status, message }: { status: BillingStatus; message: string }) {
  const isStopped = status === 'stopped'

  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        background: '#0a0a0a',
        color: '#e2e8f0',
        fontFamily: "'Inter', system-ui, sans-serif",
        padding: '2rem',
        textAlign: 'center',
      }}
    >
      {/* Icon */}
      <div
        style={{
          width: 64,
          height: 64,
          borderRadius: 16,
          background: isStopped ? '#1a0a0a' : '#0a1a2a',
          border: `1px solid ${isStopped ? '#7f1d1d' : '#1e3a5f'}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          marginBottom: 24,
          fontSize: 28,
        }}
      >
        {isStopped ? '🛑' : '⏸'}
      </div>

      {/* Heading */}
      <h1
        style={{
          fontSize: '1.5rem',
          fontWeight: 700,
          marginBottom: 8,
          color: isStopped ? '#fca5a5' : '#93c5fd',
          letterSpacing: '-0.02em',
        }}
      >
        {isStopped ? 'Service Suspended' : 'Service Temporarily Paused'}
      </h1>

      {/* Message */}
      <p
        style={{
          maxWidth: 400,
          color: '#94a3b8',
          lineHeight: 1.6,
          marginBottom: 32,
          fontSize: '0.95rem',
        }}
      >
        {message}
      </p>

      {/* Contact */}
      <a
        href="mailto:josh@amalfiai.com"
        style={{
          padding: '10px 24px',
          borderRadius: 8,
          background: 'transparent',
          border: `1px solid ${isStopped ? '#7f1d1d' : '#1e3a5f'}`,
          color: isStopped ? '#fca5a5' : '#93c5fd',
          textDecoration: 'none',
          fontSize: '0.875rem',
          fontWeight: 500,
        }}
      >
        Contact Support
      </a>

      {/* Footer */}
      <p style={{ position: 'absolute', bottom: 24, fontSize: '0.75rem', color: '#334155' }}>
        Powered by Amalfi AI
      </p>
    </div>
  )
}
