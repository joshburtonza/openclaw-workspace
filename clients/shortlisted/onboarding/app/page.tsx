import Link from "next/link";

export default function LandingPage() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center px-6">
      <div className="mx-auto max-w-2xl text-center">
        {/* Logo / wordmark */}
        <div className="mb-8 flex items-center justify-center gap-3">
          <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-sky-500 text-xl font-bold text-white">
            S
          </div>
          <span className="text-2xl font-semibold tracking-tight text-slate-100">
            Shortlisted
          </span>
        </div>

        {/* Headline */}
        <h1 className="mb-4 text-5xl font-bold leading-tight tracking-tight text-slate-50">
          Screen candidates on autopilot
        </h1>

        <p className="mb-10 text-lg text-slate-400">
          Connect your Gmail inbox and Shortlisted will automatically read incoming CVs,
          extract candidate details, and flag the best applicants using AI built for your
          industry.
        </p>

        {/* CTA */}
        <Link
          href="/onboard"
          className="inline-flex items-center gap-2 rounded-lg bg-sky-500 px-8 py-4 text-base font-semibold text-white shadow-lg transition hover:bg-sky-400 focus:outline-none focus:ring-2 focus:ring-sky-500 focus:ring-offset-2 focus:ring-offset-slate-900"
        >
          Get Shortlisted
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" className="h-5 w-5">
            <path fillRule="evenodd" d="M3 10a.75.75 0 01.75-.75h10.638L10.23 5.29a.75.75 0 111.04-1.08l5.5 5.25a.75.75 0 010 1.08l-5.5 5.25a.75.75 0 11-1.04-1.08l4.158-3.96H3.75A.75.75 0 013 10z" clipRule="evenodd" />
          </svg>
        </Link>

        {/* Feature pills */}
        <div className="mt-16 flex flex-wrap justify-center gap-3 text-sm text-slate-500">
          {["Teaching", "Legal", "Tech", "Medical", "Finance"].map((v) => (
            <span
              key={v}
              className="rounded-full border border-slate-700 bg-slate-800 px-4 py-1.5"
            >
              {v}
            </span>
          ))}
        </div>
        <p className="mt-4 text-xs text-slate-600">Six industry verticals. More coming.</p>
      </div>
    </main>
  );
}
