import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import "./globals.css";
import { AppShell } from "@/components/AppShell";

/*
 * Self-hosted fonts (committed woff2). next/font/google downloads at
 * build time and dies on flaky venue wifi; these load from the repo so
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
  themeColor: "#121212",
};

export const metadata: Metadata = {
  title: {
    default: "ZeroMargin — the crash settles in one transaction",
    template: "%s — ZeroMargin",
  },
  description:
    "A non-custodial margin engine that cross-margins a Uniswap v4 LP against an offsetting short hedge on one SPAN-style grid, nets the same book to a fraction of the collateral, and settles a flash crash in one transaction.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${display.variable} ${body.variable} ${data.variable} h-full antialiased`}
    >
      <body className="flex min-h-full flex-col">
        <div aria-hidden="true" className="noise-overlay" />
        <div aria-hidden="true" className="page-rails" />
        <AppShell>{children}</AppShell>
      </body>
    </html>
  );
}
