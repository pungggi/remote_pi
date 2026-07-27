/* Line icons + brand glyphs for the Piper landing. Ported from the
   Claude Design handoff bundle (claude.ai/design). Pure SVG — server-safe. */
import type { ReactNode } from "react";

const S = 2; // stroke width

function Ic({
  d,
  children,
  vb = 24,
  fill,
}: {
  d?: string;
  children?: ReactNode;
  vb?: number;
  fill?: string;
}) {
  return (
    <svg
      viewBox={`0 0 ${vb} ${vb}`}
      fill={fill || "none"}
      stroke="currentColor"
      strokeWidth={S}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {d ? <path d={d} /> : children}
    </svg>
  );
}

/* brand mark — Piper "P" logo (pipe-stem + data packet in the bowl) */
export function LogoMark() {
  return (
    <svg viewBox="0 0 1024 1024" fill="none" aria-hidden="true">
      <g fill="currentColor">
        <rect x="312" y="272" width="96" height="500" rx="18" />
        <rect x="312" y="272" width="400" height="96" rx="18" />
        <rect x="616" y="272" width="96" height="300" rx="18" />
        <rect x="400" y="476" width="312" height="96" rx="18" />
      </g>
      <circle cx="512" cy="422" r="46" fill="var(--green)" />
    </svg>
  );
}

/* pillar 1 — app gateway: phone with signal arrows */
export function IconGateway() {
  return (
    <Ic>
      <rect x="7" y="2.5" width="10" height="19" rx="2.6" />
      <path d="M11 18.5h2" />
      <path d="M3.5 9.5a6 6 0 0 1 0 5" opacity=".55" />
      <path d="M20.5 9.5a6 6 0 0 0 0 5" opacity=".55" />
    </Ic>
  );
}

/* pillar 2 — always on: clock / loop */
export function IconAlwaysOn() {
  return (
    <Ic>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 1.8" />
    </Ic>
  );
}

/* pillar 3 — one mesh: connected nodes */
export function IconMesh() {
  return (
    <Ic>
      <circle cx="5" cy="6" r="2.2" />
      <circle cx="19" cy="6" r="2.2" />
      <circle cx="12" cy="18" r="2.2" />
      <path d="M6.7 7.4 10.6 16M17.3 7.4 13.4 16M6.9 6h10.2" opacity=".7" />
    </Ic>
  );
}

export function IconMic() {
  return (
    <Ic>
      <rect x="9" y="2.5" width="6" height="11" rx="3" />
      <path d="M5.5 11a6.5 6.5 0 0 0 13 0" />
      <path d="M12 17.5V21" />
    </Ic>
  );
}

export function IconImage() {
  return (
    <Ic>
      <rect x="3" y="4" width="18" height="16" rx="2.5" />
      <circle cx="8.5" cy="9.5" r="1.6" />
      <path d="m4 17 5-4.5 4 3.2L17 11l3 3" />
    </Ic>
  );
}

export function IconOpenSource() {
  return (
    <Ic>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 3.5v6M9.4 14.6l-4.2 4.2M14.6 14.6l4.2 4.2" />
      <circle cx="12" cy="12" r="2.6" />
    </Ic>
  );
}

export function IconSelfHost() {
  return (
    <Ic>
      <rect x="3" y="4" width="18" height="6" rx="1.6" />
      <rect x="3" y="14" width="18" height="6" rx="1.6" />
      <path d="M7 7h.01M7 17h.01" />
    </Ic>
  );
}

export function IconArrow() {
  return <Ic d="M5 12h14M13 6l6 6-6 6" />;
}

export function IconCopy() {
  return (
    <Ic>
      <rect x="9" y="9" width="11" height="11" rx="2" />
      <path d="M5 15V5a2 2 0 0 1 2-2h8" />
    </Ic>
  );
}

export function IconCheck() {
  return <Ic d="M4 12.5 9 17.5 20 6.5" />;
}

export function IconStar() {
  return <Ic d="m12 3 2.6 5.3 5.8.8-4.2 4.1 1 5.8L12 16.8 6.8 19l1-5.8L3.6 9.1l5.8-.8L12 3Z" />;
}

export function IconGithub() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 2C6.48 2 2 6.58 2 12.25c0 4.53 2.87 8.37 6.84 9.73.5.1.68-.22.68-.49 0-.24-.01-.88-.01-1.73-2.78.62-3.37-1.37-3.37-1.37-.45-1.18-1.11-1.5-1.11-1.5-.91-.64.07-.62.07-.62 1 .07 1.53 1.06 1.53 1.06.89 1.56 2.34 1.11 2.91.85.09-.66.35-1.11.63-1.37-2.22-.26-4.55-1.14-4.55-5.07 0-1.12.39-2.03 1.03-2.75-.1-.26-.45-1.3.1-2.71 0 0 .84-.27 2.75 1.05a9.34 9.34 0 0 1 5 0c1.91-1.32 2.75-1.05 2.75-1.05.55 1.41.2 2.45.1 2.71.64.72 1.03 1.63 1.03 2.75 0 3.94-2.34 4.81-4.57 5.06.36.32.68.94.68 1.9 0 1.37-.01 2.48-.01 2.82 0 .27.18.6.69.49A10.02 10.02 0 0 0 22 12.25C22 6.58 17.52 2 12 2Z" />
    </svg>
  );
}

export function IconApple() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M16.37 12.78c-.02-2.13 1.74-3.15 1.82-3.2-.99-1.45-2.54-1.65-3.09-1.67-1.32-.13-2.57.77-3.24.77-.66 0-1.69-.75-2.78-.73-1.43.02-2.75.83-3.48 2.11-1.48 2.57-.38 6.38 1.06 8.47.7 1.02 1.54 2.17 2.64 2.13 1.06-.04 1.46-.69 2.74-.69 1.28 0 1.64.69 2.76.66 1.14-.02 1.86-1.04 2.56-2.07.81-1.19 1.14-2.34 1.16-2.4-.03-.01-2.22-.85-2.24-3.38ZM14.3 6.25c.58-.71.98-1.69.87-2.67-.84.03-1.86.56-2.47 1.26-.54.62-1.01 1.62-.89 2.57.94.08 1.9-.47 2.49-1.16Z" />
    </svg>
  );
}

/* Windows — classic four-pane flag */
export function IconWindows() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M3 4.6 10.7 3.5v7.8H3V4.6ZM11.6 3.37 21 2v9.3h-9.4V3.37ZM3 12.7h7.7v7.8L3 19.4v-6.7ZM11.6 12.7H21V22l-9.4-1.35V12.7Z" />
    </svg>
  );
}

/* Linux — penguin silhouette */
export function IconLinux() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 2.4c-2.1 0-3.5 1.7-3.5 4 0 .9.1 1.7.1 2.5 0 1-.7 1.7-1.6 3C6.1 13.2 5.2 14.4 5.2 15.8c0 .7.4 1.2 1.1 1.4-.1.3-.2.6-.2.9 0 1.4 2.6 2 5.9 2s5.9-.6 5.9-2c0-.3-.1-.6-.2-.9.7-.2 1.1-.7 1.1-1.4 0-1.4-.9-2.6-1.8-3.9-.9-1.3-1.6-2-1.6-3 0-.8.1-1.6.1-2.5 0-2.3-1.4-4-3.5-4Zm-1.6 3.2c.5 0 .9.5.9 1.1s-.4 1.1-.9 1.1-.9-.5-.9-1.1.4-1.1.9-1.1Zm3.2 0c.5 0 .9.5.9 1.1s-.4 1.1-.9 1.1-.9-.5-.9-1.1.4-1.1.9-1.1Z" />
    </svg>
  );
}

/* Android — robot front, line style */
export function IconAndroid() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={S}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M7 4.5 5.5 2.8M17 4.5l1.5-1.7" opacity=".7" />
      <path d="M5.5 11a6.5 6.5 0 0 1 13 0" />
      <path d="M5.5 11h13v6a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 17v-6Z" />
      <path d="M9 8h.01M15 8h.01" />
      <path d="M8.7 18.5V21M15.3 18.5V21" opacity=".7" />
    </svg>
  );
}

export function IconPlay() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M3.6 2.3 13.5 12 3.6 21.7c-.36-.18-.6-.55-.6-1V3.3c0-.45.24-.82.6-1Z" fill="#00ff41" />
      <path d="m16.8 8.7 3.1 1.7c.8.45.8 1.35 0 1.8l-3.1 1.7L13.5 12l3.3-3.3Z" fill="#00ff41" opacity=".8" />
      <path d="M3.6 2.3 13.5 12l-3.3 3.3L3.6 2.3Z" fill="#00ff41" opacity=".5" />
      <path d="M3.6 21.7 13.5 12l-3.3-3.3L3.6 21.7Z" fill="#00ff41" opacity=".65" />
    </svg>
  );
}

export function IconDownload() {
  return (
    <Ic>
      <path d="M12 3v12M7 11l5 5 5-5" />
      <path d="M4 20h16" />
    </Ic>
  );
}

export function IconChevronLeft() {
  return <Ic d="M15 5 8 12l7 7" />;
}

export function IconTerminal() {
  return (
    <Ic>
      <rect x="2.5" y="4" width="19" height="16" rx="3" />
      <path d="M7 9.5 10 12l-3 2.5M12.5 15H17" />
    </Ic>
  );
}

export function IconPaperclip() {
  return (
    <Ic d="M20.5 11.5 12 20a5 5 0 0 1-7-7l8.5-8.5a3.3 3.3 0 0 1 4.7 4.7l-8.5 8.5a1.7 1.7 0 0 1-2.4-2.4l7.8-7.8" />
  );
}

export function IconStop() {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <rect x="6.5" y="6.5" width="11" height="11" rx="2.4" />
    </svg>
  );
}
