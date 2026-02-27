"use client";

import { useState } from "react";

type Vertical =
  | "teaching"
  | "legal"
  | "tech"
  | "medical"
  | "finance"
  | "generic";

interface FormData {
  companyName: string;
  vertical: Vertical | "";
  contactName: string;
  contactEmail: string;
}

const VERTICAL_OPTIONS: { value: Vertical; label: string; description: string }[] = [
  { value: "teaching", label: "Teaching & Education", description: "SA educator recruitment with SACE gate" },
  { value: "legal",    label: "Legal & Law",           description: "LLB / BCom Law, admitted attorneys"   },
  { value: "tech",     label: "Technology",             description: "Software engineers, any stack"        },
  { value: "medical",  label: "Medical & Healthcare",   description: "HPCSA / SANC registered practitioners" },
  { value: "finance",  label: "Finance & Accounting",   description: "CA(SA), CIMA, ACCA, BCom"            },
  { value: "generic",  label: "General / Other",        description: "No hard qualification gates"          },
];

export default function OnboardPage() {
  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [form, setForm] = useState<FormData>({
    companyName: "",
    vertical: "",
    contactName: "",
    contactEmail: "",
  });
  const [errors, setErrors] = useState<Partial<Record<keyof FormData, string>>>({});

  // ---- Validation ----
  function validateStep1(): boolean {
    const newErrors: Partial<Record<keyof FormData, string>> = {};
    if (!form.companyName.trim()) newErrors.companyName = "Company name is required";
    if (!form.vertical) newErrors.vertical = "Please select a vertical";
    if (!form.contactName.trim()) newErrors.contactName = "Contact name is required";
    if (!form.contactEmail.trim()) {
      newErrors.contactEmail = "Contact email is required";
    } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.contactEmail)) {
      newErrors.contactEmail = "Enter a valid email address";
    }
    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }

  function handleNextStep() {
    if (step === 1 && validateStep1()) {
      setStep(2);
    }
  }

  // ---- Google OAuth redirect ----
  function handleConnectGmail() {
    // Encode form data as base64 JSON in the OAuth state parameter
    // so we can read it back in the callback route
    const statePayload = {
      companyName: form.companyName,
      vertical: form.vertical,
      contactName: form.contactName,
      contactEmail: form.contactEmail,
    };
    const stateB64 = btoa(JSON.stringify(statePayload));
    // Route to the server-side initiator which builds the full Google URL
    window.location.href = `/api/auth/google?state=${encodeURIComponent(stateB64)}`;
  }

  // ---- UI helpers ----
  function InputField({
    label,
    id,
    type = "text",
    value,
    onChange,
    error,
    placeholder,
  }: {
    label: string;
    id: keyof FormData;
    type?: string;
    value: string;
    onChange: (v: string) => void;
    error?: string;
    placeholder?: string;
  }) {
    return (
      <div>
        <label htmlFor={id} className="mb-1.5 block text-sm font-medium text-slate-300">
          {label}
        </label>
        <input
          id={id}
          type={type}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={placeholder}
          className={`w-full rounded-lg border bg-slate-800 px-4 py-2.5 text-slate-100 placeholder-slate-500 focus:outline-none focus:ring-2 focus:ring-sky-500 ${
            error ? "border-red-500" : "border-slate-700"
          }`}
        />
        {error && <p className="mt-1 text-xs text-red-400">{error}</p>}
      </div>
    );
  }

  // ---- Step renders ----
  function renderStep1() {
    return (
      <div className="space-y-5">
        <InputField
          label="Company / Agency name"
          id="companyName"
          value={form.companyName}
          onChange={(v) => setForm({ ...form, companyName: v })}
          error={errors.companyName}
          placeholder="Acme Recruitment"
        />

        <div>
          <label className="mb-1.5 block text-sm font-medium text-slate-300">
            Industry vertical
          </label>
          <div className="grid gap-2 sm:grid-cols-2">
            {VERTICAL_OPTIONS.map((opt) => (
              <button
                key={opt.value}
                type="button"
                onClick={() => setForm({ ...form, vertical: opt.value })}
                className={`rounded-lg border p-3 text-left transition ${
                  form.vertical === opt.value
                    ? "border-sky-500 bg-sky-500/10 text-sky-400"
                    : "border-slate-700 bg-slate-800 text-slate-300 hover:border-slate-600"
                }`}
              >
                <div className="text-sm font-medium">{opt.label}</div>
                <div className="mt-0.5 text-xs opacity-70">{opt.description}</div>
              </button>
            ))}
          </div>
          {errors.vertical && (
            <p className="mt-1 text-xs text-red-400">{errors.vertical}</p>
          )}
        </div>

        <InputField
          label="Contact person name"
          id="contactName"
          value={form.contactName}
          onChange={(v) => setForm({ ...form, contactName: v })}
          error={errors.contactName}
          placeholder="Jane Smith"
        />

        <InputField
          label="Contact email"
          id="contactEmail"
          type="email"
          value={form.contactEmail}
          onChange={(v) => setForm({ ...form, contactEmail: v })}
          error={errors.contactEmail}
          placeholder="jane@company.com"
        />

        <button
          type="button"
          onClick={handleNextStep}
          className="w-full rounded-lg bg-sky-500 px-6 py-3 font-semibold text-white transition hover:bg-sky-400 focus:outline-none focus:ring-2 focus:ring-sky-500 focus:ring-offset-2 focus:ring-offset-slate-900"
        >
          Next: Connect Gmail
        </button>
      </div>
    );
  }

  function renderStep2() {
    return (
      <div className="space-y-6 text-center">
        <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-full bg-slate-800">
          <svg viewBox="0 0 24 24" className="h-8 w-8" fill="none">
            <path d="M22 6c0-1.1-.9-2-2-2H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6z" fill="#4285F4"/>
            <path d="M22 6l-10 7L2 6" stroke="#fff" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>

        <div>
          <h2 className="text-xl font-semibold text-slate-100">Connect your Gmail inbox</h2>
          <p className="mt-2 text-sm text-slate-400">
            Shortlisted needs read access to your inbox to detect incoming CVs. We request
            only the minimum scopes required: read and label messages.
          </p>
        </div>

        <div className="rounded-lg border border-slate-700 bg-slate-800/50 p-4 text-left">
          <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
            Permissions requested
          </p>
          <ul className="space-y-1 text-sm text-slate-300">
            <li className="flex items-center gap-2">
              <span className="text-green-400">&#10003;</span>
              Read your email messages
            </li>
            <li className="flex items-center gap-2">
              <span className="text-green-400">&#10003;</span>
              Mark messages as read
            </li>
          </ul>
        </div>

        <div className="space-y-3">
          <button
            type="button"
            onClick={handleConnectGmail}
            className="w-full rounded-lg border border-slate-600 bg-white px-6 py-3 font-semibold text-slate-900 transition hover:bg-slate-100 focus:outline-none focus:ring-2 focus:ring-sky-500 focus:ring-offset-2 focus:ring-offset-slate-900"
          >
            <span className="flex items-center justify-center gap-3">
              <svg viewBox="0 0 24 24" className="h-5 w-5">
                <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" fill="#4285F4"/>
                <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853"/>
                <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l3.66-2.84z" fill="#FBBC05"/>
                <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335"/>
              </svg>
              Sign in with Google
            </span>
          </button>

          <button
            type="button"
            onClick={() => setStep(1)}
            className="w-full rounded-lg px-6 py-2.5 text-sm text-slate-500 transition hover:text-slate-300"
          >
            Go back
          </button>
        </div>
      </div>
    );
  }

  function renderStep3() {
    return (
      <div className="space-y-4 text-center">
        <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-full bg-green-500/20 text-4xl">
          &#10003;
        </div>
        <h2 className="text-xl font-semibold text-slate-100">Almost there!</h2>
        <p className="text-sm text-slate-400">
          Connecting to Google... you will be redirected automatically.
        </p>
      </div>
    );
  }

  const stepLabels = ["Company info", "Connect Gmail", "Done"];

  return (
    <main className="flex min-h-screen flex-col items-center justify-center px-6 py-16">
      <div className="w-full max-w-lg">
        {/* Header */}
        <div className="mb-8 text-center">
          <a href="/" className="inline-flex items-center gap-2 text-slate-400 transition hover:text-slate-200">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" className="h-4 w-4">
              <path fillRule="evenodd" d="M17 10a.75.75 0 01-.75.75H5.612l4.158 3.96a.75.75 0 11-1.04 1.08l-5.5-5.25a.75.75 0 010-1.08l5.5-5.25a.75.75 0 111.04 1.08L5.612 9.25H16.25A.75.75 0 0117 10z" clipRule="evenodd" />
            </svg>
            Shortlisted
          </a>
        </div>

        {/* Step indicator */}
        <div className="mb-8 flex items-center justify-between">
          {stepLabels.map((label, i) => {
            const stepNum = (i + 1) as 1 | 2 | 3;
            const isActive = step === stepNum;
            const isDone = step > stepNum;
            return (
              <div key={label} className="flex flex-1 items-center">
                <div className="flex flex-col items-center">
                  <div
                    className={`flex h-8 w-8 items-center justify-center rounded-full text-sm font-semibold ${
                      isDone
                        ? "bg-green-500 text-white"
                        : isActive
                        ? "bg-sky-500 text-white"
                        : "bg-slate-800 text-slate-500"
                    }`}
                  >
                    {isDone ? "\u2713" : stepNum}
                  </div>
                  <span
                    className={`mt-1 text-xs ${isActive ? "text-slate-200" : "text-slate-600"}`}
                  >
                    {label}
                  </span>
                </div>
                {i < stepLabels.length - 1 && (
                  <div
                    className={`mx-2 h-0.5 flex-1 ${step > stepNum ? "bg-green-500" : "bg-slate-800"}`}
                  />
                )}
              </div>
            );
          })}
        </div>

        {/* Card */}
        <div className="rounded-2xl border border-slate-800 bg-slate-900 p-8 shadow-2xl">
          {step === 1 && renderStep1()}
          {step === 2 && renderStep2()}
          {step === 3 && renderStep3()}
        </div>
      </div>
    </main>
  );
}
