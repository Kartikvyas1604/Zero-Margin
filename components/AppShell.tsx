"use client";

import { useEffect, useState, type ReactNode } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/cn";
import { ZmLockup } from "@/components/brand/ZMLogo";

const nav = [
  { href: "/dashboard", label: "Overview", icon: IconDashboard },
  { href: "/positions", label: "Positions", icon: IconRows },
  { href: "/terminal", label: "Terminal", icon: IconTerminal },
  { href: "/replay", label: "Replay", icon: IconClock },
  { href: "/arkiv", label: "Attestations", icon: IconShield },
  { href: "/proof", label: "Proof", icon: IconCheck },
] as const;

interface Health {
  status: string;
  mode: string;
  chainId: number;
  problems: string[];
}

/** The mode chip is the product's honesty layer: it names what is live. */
function ModeChip() {
  const [health, setHealth] = useState<Health | null>(null);

  useEffect(() => {
    let alive = true;
    const load = () => {
      fetch("/api/health")
        .then(async (res) => {
          if (!res.ok) throw new Error(`api ${res.status}`);
          const body = await res.json();
          if (!alive) return;
          setHealth(body as Health);
        })
        .catch(() => {
          if (alive) setHealth(null);
        });
    };
    load();
    const timer = setInterval(load, 30_000);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, []);

  const mode = health?.mode ?? "SELF";
  const title =
    health === null
      ? "SELF — the API layer has not answered yet; the page runs figures from the local deterministic engine."
      : health.problems.length > 0
        ? `DEGRADED — ${health.problems.join("; ")}`
        : `${mode} — every figure is computed from the deterministic span engine in this deployment; chain id ${health.chainId}. No node is connected in this mode.`;

  return (
    <span
      title={title}
      className={cn(
        "hidden cursor-help items-center gap-1.5 rounded-full border border-border bg-secondary px-3 py-1 font-mono text-xs font-medium text-muted-foreground sm:inline-flex",
        health === null && "border-line text-dim",
        health !== null && health.problems.length > 0 && "border-down/30 bg-down/10 text-down",
      )}
    >
      <span
        aria-hidden="true"
        className={cn(
          "size-1.5 rounded-full",
          health === null ? "bg-muted-foreground" : health.problems.length > 0 ? "bg-down" : "bg-up",
        )}
      />
      <span className="uppercase tracking-[-0.01em]">{mode}</span>
    </span>
  );
}

function NavLink({
  item,
  active,
}: {
  item: (typeof nav)[number];
  active: boolean;
}) {
  const Icon = item.icon;
  return (
    <Link
      href={item.href}
      aria-current={active ? "page" : undefined}
      className={cn(
        "relative flex items-center gap-1.5 rounded-md px-2 py-2.5 text-sm transition-colors duration-150 sm:px-3",
        active
          ? "text-foreground"
          : "text-muted-foreground hover:bg-secondary hover:text-foreground",
      )}
    >
      <Icon />
      {item.label}
      <span
        aria-hidden="true"
        className={cn(
          "absolute inset-x-2 -bottom-px h-0.5 rounded-full bg-foreground transition-opacity duration-200 sm:inset-x-3",
          active ? "opacity-100" : "opacity-0",
        )}
      />
    </Link>
  );
}

/**
 * One header row: brand, icon nav with underline tells, engine mode
 * chip, one action. Mobile gets an expanding panel over the strip.
 */
export function AppShell({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);

  useEffect(() => setOpen(false), [pathname]);

  return (
    <div className="flex min-h-dvh flex-col bg-background text-foreground">
      <header className="sticky top-0 z-50 border-b border-border bg-background/90 backdrop-blur-md">
        <div className="mx-auto flex h-16 w-full max-w-[1332px] items-center justify-between gap-3 px-4 pt-[env(safe-area-inset-top)] sm:px-6 lg:px-8">
          <ZmLockup href="/" />

          <nav
            aria-label="Primary"
            className="hidden items-center gap-0.5 text-sm md:flex"
          >
            {nav.map((item) => (
              <NavLink
                key={item.href}
                item={item}
                active={pathname === item.href}
              />
            ))}
          </nav>

          <div className="flex items-center gap-2">
            <ModeChip />
            <Link
              href="/dashboard"
              className="btn-light hover-opacity hidden h-10 items-center gap-1.5 rounded-full px-4 text-sm font-semibold sm:inline-flex"
            >
              Open the desk
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="h-3.5 w-3.5"
                aria-hidden="true"
              >
                <path d="M7 7h10v10" />
                <path d="M7 17 17 7" />
              </svg>
            </Link>
            <button
              type="button"
              aria-expanded={open}
              aria-controls="mobile-nav"
              aria-label={open ? "Close menu" : "Open menu"}
              onClick={() => setOpen((v) => !v)}
              className="inline-flex h-10 w-10 items-center justify-center rounded-md border border-border text-muted-foreground transition-colors hover:text-foreground md:hidden"
            >
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                className="h-5 w-5"
                aria-hidden="true"
              >
                {open ? <path d="M6 6l12 12M18 6 6 18" /> : <path d="M4 5h16M4 12h16M4 19h16" />}
              </svg>
            </button>
          </div>
        </div>

        {/* mobile: expanding panel of the same routes */}
        {open && (
          <nav
            id="mobile-nav"
            aria-label="Primary"
            className="grid grid-cols-2 gap-1 border-t border-border px-4 pb-3 pt-2 md:hidden"
          >
            {nav.map((item) => {
              const active = pathname === item.href;
              const Icon = item.icon;
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  aria-current={active ? "page" : undefined}
                  className={cn(
                    "flex items-center gap-2 rounded-md px-3 py-2.5 text-sm",
                    active
                      ? "bg-secondary text-foreground"
                      : "text-muted-foreground hover:text-foreground",
                  )}
                >
                  <Icon />
                  {item.label}
                </Link>
              );
            })}
            <Link
              href="/dashboard"
              className="btn-light col-span-2 mt-1 flex h-10 items-center justify-center rounded-md text-sm font-semibold"
            >
              Open the desk
            </Link>
          </nav>
        )}
      </header>

      <main className="min-w-0 flex-1">{children}</main>

      <footer className="border-t border-border">
        <div className="mx-auto w-full max-w-[1332px] px-4 pb-[calc(3rem+env(safe-area-inset-bottom))] pt-12 sm:px-6 lg:px-8">
          <div className="flex flex-wrap items-center justify-between gap-6">
            <ZmLockup className="text-foreground" />
            <p className="font-mono text-xs text-muted-foreground">
              SPAN-style netting · Uniswap v4 hook · one-transaction unwind —{" "}
              <code className="font-mono text-foreground">1e6</code> USDC base
              units, 1e6 = $1.00
            </p>
          </div>
          <div className="mt-8 flex flex-col justify-between gap-4 border-t border-border pt-6 text-xs leading-relaxed text-muted-foreground md:flex-row md:items-center">
            <p className="max-w-3xl">
              A hackathon prototype; the code is tested, not audited. The
              short leg settles against a pre-funded demo adapter, and every
              figure on screen is computed locally by the deterministic span
              engine — never stored as display strings.
            </p>
            <div className="flex shrink-0 gap-4 font-mono text-xs">
              {[
                { href: "/terminal", label: "Terminal" },
                { href: "/replay", label: "Replay" },
                { href: "/proof", label: "Proof" },
              ].map((l) => (
                <Link
                  key={l.href}
                  href={l.href}
                  className="transition-colors duration-150 hover:text-foreground"
                >
                  {l.label}
                </Link>
              ))}
            </div>
          </div>
        </div>
      </footer>
    </div>
  );
}

/* ── nav icons (16px stroke = lucide weight, drawn inline) ───────── */

function IconBase({ children }: { children: ReactNode }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="h-3.5 w-3.5"
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

function IconDashboard() {
  return (
    <IconBase>
      <rect width="7" height="9" x="3" y="3" rx="1" />
      <rect width="7" height="5" x="14" y="3" rx="1" />
      <rect width="7" height="9" x="14" y="12" rx="1" />
      <rect width="7" height="5" x="3" y="16" rx="1" />
    </IconBase>
  );
}

function IconRows() {
  return (
    <IconBase>
      <rect width="18" height="18" x="3" y="3" rx="2" />
      <path d="M3 9h18M3 15h18M9 3v18" />
    </IconBase>
  );
}

function IconTerminal() {
  return (
    <IconBase>
      <path d="m4 17 6-6-6-6" />
      <path d="M12 19h8" />
    </IconBase>
  );
}

function IconClock() {
  return (
    <IconBase>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3 2" />
    </IconBase>
  );
}

function IconShield() {
  return (
    <IconBase>
      <path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" />
      <path d="m9 12 2 2 4-4" />
    </IconBase>
  );
}

function IconCheck() {
  return (
    <IconBase>
      <path d="M20 6 9 17l-5-5" />
    </IconBase>
  );
}
