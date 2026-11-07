/**
 * ZeroMargin brand marks.
 *
 * The glyph is the slashed zero (0̸) — the tabular-numeral zero the
 * engine displays everywhere, struck through by the gold netting line.
 * Ring = the book and its collateral. Slash = the margin being zeroed.
 * Two shapes, three sizes, one meaning: nothing sits trapped.
 */
export function ZmMark({
  className = "",
  slashClassName = "text-gold",
}: {
  className?: string;
  slashClassName?: string;
}) {
  return (
    <svg
      viewBox="0 0 32 32"
      fill="none"
      aria-hidden="true"
      className={className}
      xmlns="http://www.w3.org/2000/svg"
    >
      <circle
        cx="16"
        cy="16"
        r="10"
        stroke="currentColor"
        strokeWidth="4.6"
      />
      <line
        x1="22.6"
        y1="5.8"
        x2="9.4"
        y2="26.2"
        stroke="var(--gold)"
        strokeWidth="4"
        strokeLinecap="round"
        className={slashClassName}
      />
    </svg>
  );
}

/** Favicon-style tile: the mark set in an engraved dark square. */
export function ZmBadge({ className = "" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 32 32"
      fill="none"
      aria-hidden="true"
      className={className}
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect width="32" height="32" rx="7" fill="#121212" />
      <rect
        x="0.5"
        y="0.5"
        width="31"
        height="31"
        rx="6.5"
        stroke="#202020"
      />
      <circle cx="16" cy="16" r="10" stroke="#E8E8E8" strokeWidth="4.6" />
      <line
        x1="22.6"
        y1="5.8"
        x2="9.4"
        y2="26.2"
        stroke="var(--gold)"
        strokeWidth="4"
        strokeLinecap="round"
      />
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
      <ZmMark className="size-6 shrink-0" />
      <span className="text-lg font-semibold tracking-[-0.02em]">
        ZeroMargin
      </span>
    </>
  );
  if (href) {
    return (
      <a
        href={href}
        className={`flex shrink-0 items-center gap-2.5 text-foreground transition-opacity duration-200 hover:opacity-80 ${className}`}
      >
        {inner}
      </a>
    );
  }
  return <span className={`flex items-center gap-2.5 ${className}`}>{inner}</span>;
}
