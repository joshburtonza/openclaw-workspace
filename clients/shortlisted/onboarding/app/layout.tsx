import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Shortlisted — AI Recruitment Screening",
  description: "Connect your Gmail inbox and let Shortlisted screen candidates automatically.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-slate-900 text-slate-100 antialiased">
        {children}
      </body>
    </html>
  );
}
