import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import "./globals.css";
import { AppShell } from "@/components/AppShell";

/*
 * Self-hosted fonts (committed woff2). next/font loads from the repo so
 * a clean build never touches the network for type.
 *
 * Clash Grotesk carries display type; Plus Jakarta Sans (variable)
 * carries body copy; Geist Mono carries every number.
 */
const display = localFont({
  src: [
    { path: "./fonts/clash-grotesk-400.woff2", weight: "400" },
    { path: "./fonts/clash-grotesk-500.woff2", weight: "500" },
    { path: "./fonts/clash-grotesk-600.woff2", weight: "600" },
  ],
  variable: "--font-clash",
  display: "swap",
});

const body = localFont({
  src: "./fonts/plus-jakarta-sans-var.woff2",
  variable: "--font-body",
  weight: "400 800",
  display: "swap",
});

const data = localFont({
  src: "./fonts/geist-mono.woff2",
  variable: "--font-data",
  weight: "400 500",
  display: "swap",
});

export const viewport: Viewport = {
  themeColor: "#0a0b0d",
  colorScheme: "dark",
};

export const metadata: Metadata = {
  title: {
    default: "ZeroMargin — the crash settles in one transaction",
    template: "%s — ZeroMargin",
  },
  description:
    "A non-custodial margin engine that cross-margins a Uniswap v4 LP against an offsetting short hedge on one SPAN-style grid, nets the same book to a fraction of the collateral, and settles a flash crash in one transaction.",
  applicationName: "ZeroMargin",
  icons: {
    icon: [{ url: "/icon.svg", type: "image/svg+xml" }, { url: "/favicon.ico", sizes: "any" }],
    apple: [{ url: "/apple-icon.png", type: "image/png" }],
  },
  openGraph: {
    title: "ZeroMargin — cross-venue margin engine",
    description:
      "Net LP risk against an offsetting hedge on one SPAN-style grid. Settle shocks in one transaction.",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "ZeroMargin",
    description: "Cross-venue margin netting and atomic crash settlement.",
  },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${display.variable} ${body.variable} ${data.variable} h-full antialiased`}
    >
      <body className="flex min-h-full flex-col bg-background text-text">
        <div aria-hidden="true" className="noise-overlay" />
        <div aria-hidden="true" className="page-rails" />
        <AppShell>{children}</AppShell>
      </body>
    </html>
  );
}
