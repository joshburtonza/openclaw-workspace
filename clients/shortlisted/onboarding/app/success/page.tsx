import Link from "next/link";

interface SuccessPageProps {
  searchParams: { org?: string };
}

export default function SuccessPage({ searchParams }: SuccessPageProps) {
  const orgSlug = searchParams.org ?? "";

  return (
    <main className="flex min-h-screen flex-col items-center justify-center px-6">
      <div className="w-full max-w-lg text-center">
        {/* Success icon */}
        <div className="mx-auto mb-6 flex h-20 w-20 items-center justify-center rounded-full bg-green-500/20">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="none"
            className="h-10 w-10 text-green-400"
          >
            <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="1.5" />
            <path
              d="M7.5 12l3 3 6-6"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        </div>

        <h1 className="mb-3 text-3xl font-bold text-slate-50">You are live!</h1>

        <p className="mb-8 text-slate-400">
          Shortlisted is now watching your inbox. When candidates send CVs to your Gmail
          address, they will be screened automatically and added to your dashboard.
        </p>

        {/* What happens next */}
        <div className="mb-10 rounded-xl border border-slate-800 bg-slate-900 p-6 text-left">
          <h2 className="mb-4 text-sm font-semibold uppercase tracking-wide text-slate-500">
            What happens next
          </h2>
          <ul className="space-y-3">
            {[
              {
                step: "1",
                title: "Candidates email their CVs",
                desc: "Share your Gmail address with job seekers as normal.",
              },
              {
                step: "2",
                title: "Shortlisted screens automatically",
                desc: "Every incoming email is read, extracted, and scored by AI within minutes.",
              },
              {
                step: "3",
                title: "Review your shortlist",
                desc: "Only qualified candidates make it through. Flagged ones are surfaced for your review.",
              },
            ].map(({ step, title, desc }) => (
              <li key={step} className="flex gap-4">
                <div className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full bg-sky-500/20 text-sm font-semibold text-sky-400">
                  {step}
                </div>
                <div>
                  <p className="font-medium text-slate-200">{title}</p>
                  <p className="text-sm text-slate-500">{desc}</p>
                </div>
              </li>
            ))}
          </ul>
        </div>

        {/* CTA */}
        <div className="flex flex-col gap-3 sm:flex-row sm:justify-center">
          <a
            href={`mailto:support@shortlisted.co.za?subject=Onboarding%20complete%20%E2%80%94%20${encodeURIComponent(orgSlug)}`}
            className="rounded-lg border border-slate-700 bg-slate-800 px-6 py-3 text-sm font-medium text-slate-300 transition hover:bg-slate-700"
          >
            Contact support
          </a>
          <Link
            href="/"
            className="rounded-lg bg-sky-500 px-6 py-3 text-sm font-semibold text-white transition hover:bg-sky-400"
          >
            Back to home
          </Link>
        </div>

        {orgSlug && (
          <p className="mt-8 text-xs text-slate-600">
            Organisation ID: <span className="font-mono">{orgSlug}</span>
          </p>
        )}
      </div>
    </main>
  );
}
