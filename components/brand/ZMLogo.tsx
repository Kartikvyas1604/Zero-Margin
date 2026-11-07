/**
 * ZeroMargin brand marks.
 *
 * Glyph: a bold zero crossed by a precise netting slash — collateral
 * ring + margin zeroed. The slash carries the accent signal.
 */
export function ZmMark({
  className = "",
  accent = "var(--signal, #EFA94A)",
}: {
  className?: string;
  accent?: string;
}) {
  return (
    <svg
      viewBox="0 0 32 32"
      fill="none"
      aria-hidden="true"
      className={className}
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient id="zm-slash" x1="23" y1="5" x2="9" y2="27" gradientUnits="userSpaceOnUse">
          <stop offset="0" stopColor={accent} stopOpacity="1" />
          <stop offset="1" stopColor={accent} stopOpacity="0.72" />
        </linearGradient>
      </defs>
      <circle cx="16" cy="16" r="10.25" stroke="currentColor" strokeWidth="3.5" />
      <rect
        x="14.35"
        y="3.2"
        width="3.3"
        height="25.6"
        rx="1.65"
        transform="rotate(33 16 16)"
        fill="url(#zm-slash)"
      />
      <circle cx="16" cy="16" r="10.25" stroke="currentColor" strokeWidth="3.5" strokeOpacity="0.18" />
    </svg>
  );
}

/** App icon / badge: mark on a deep console tile. */
export function ZmBadge({ className = "", size = 32 }: { className?: string; size?: number }) {
  const r = Math.round(size * 0.22);
  return (
    <svg
      viewBox="0 0 32 32"
      width={size}
      height={size}
      fill="none"
      aria-hidden="true"
      className={className}
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect width="32" height="32" rx={r} fill="#0A0B0D" />
      <rect x="0.5" y="0.5" width="31" height="31" rx={r - 0.5} stroke="#23262B" />
      <circle cx="16" cy="16" r="9.5" stroke="#E8EAEC" strokeWidth="3.2" />
      <rect
        x="14.5"
        y="4.4"
        width="3"
        height="23.2"
        rx="1.5"
        transform="rotate(33 16 16)"
        fill="#EFA94A"
      />
      <circle cx="16" cy="16" r="9.5" stroke="#E8EAEC" strokeWidth="3.2" strokeOpacity="0.12" />
    </svg>
  );
}

/** Mark + wordmark lockup for header and footer. */
export function ZmLockup({
  className = "",
  href,
}: {
  className?: string;
  href?: string;
}) {
  const inner = (
    <>
      <ZmMark className="size-[26px] shrink-0" />
      <span className="text-[17px] font-semibold tracking-[-0.025em] text-foreground">
        ZeroMargin
      </span>
    </>
  );
  const cls = `inline-flex items-center gap-2.5 transition-opacity duration-150 hover:opacity-80 ${className}`;
  if (href) {
    return (
      <a href={href} className={cls}>
        {inner}
      </a>
    );
  }
  return <span className={cls}>{inner}</span>;
}

export function ZmWordmark({ className = "" }: { className?: string }) {
  return (
    <span className={`inline-flex items-baseline gap-0 font-semibold tracking-[-0.03em] ${className}`}>
      <span className="text-foreground">Zero</span>
      <span style={{ color: "var(--signal, #EFA94A)" }}>Margin</span>
    </span>
  );
}
