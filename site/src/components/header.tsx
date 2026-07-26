"use client";

import { useState } from "react";
import Link from "next/link";
import { LogoMark, IconDownload } from "@/components/landing/icons";

const GITHUB_URL = "https://github.com/pungggi/remote_pi";

function HamburgerIcon({ open }: { open: boolean }) {
  return (
    <svg
      width="24"
      height="24"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      aria-hidden="true"
    >
      <line
        x1="4"
        y1="6"
        x2="20"
        y2="6"
        style={{
          transform: open ? "rotate(45deg) translate(0, 6px)" : "none",
          transformOrigin: "center",
          transition: "transform 0.25s ease",
        }}
      />
      <line
        x1="4"
        y1="12"
        x2="20"
        y2="12"
        style={{
          opacity: open ? 0 : 1,
          transition: "opacity 0.2s ease",
        }}
      />
      <line
        x1="4"
        y1="18"
        x2="20"
        y2="18"
        style={{
          transform: open ? "rotate(-45deg) translate(0, -6px)" : "none",
          transformOrigin: "center",
          transition: "transform 0.25s ease",
        }}
      />
    </svg>
  );
}

export function SiteHeader() {
  const [menuOpen, setMenuOpen] = useState(false);

  return (
    <header className="nav">
      <div className="wrap nav-inner">
        <Link className="brand" href="/" aria-label="Piper — home">
          <span className="mark">
            <LogoMark />
          </span>
          Piper
        </Link>

        {/* Desktop links */}
        <nav className="nav-links" aria-label="Primary">
          <Link className="lnk" href="/cockpit">
            Cockpit
          </Link>
          <Link className="lnk" href="/tutorials">
            Tutorials
          </Link>
          <Link className="lnk" href="/docs">
            Docs
          </Link>
          <Link className="lnk" href="/download">
            Download
          </Link>
          <a
            className="lnk"
            href={GITHUB_URL}
            target="_blank"
            rel="noopener noreferrer"
          >
            GitHub
          </a>
          <Link className="nav-cta" href="/#install">
            <IconDownload /> Install
          </Link>
        </nav>

        {/* Mobile menu toggle */}
        <button
          className="nav-toggle"
          onClick={() => setMenuOpen((s) => !s)}
          aria-expanded={menuOpen}
          aria-controls="mobile-menu"
          aria-label={menuOpen ? "Fechar menu" : "Abrir menu"}
          type="button"
        >
          <HamburgerIcon open={menuOpen} />
        </button>
      </div>

      {/* Mobile drawer */}
      {menuOpen && (
        <div
          id="mobile-menu"
          className="mobile-nav open"
          aria-hidden={false}
        >
          <div className="wrap mobile-nav-inner">
            <Link
              className="m-lnk"
              href="/cockpit"
              onClick={() => setMenuOpen(false)}
            >
              Cockpit
            </Link>
            <Link
              className="m-lnk"
              href="/tutorials"
              onClick={() => setMenuOpen(false)}
            >
              Tutorials
            </Link>
            <Link
              className="m-lnk"
              href="/docs"
              onClick={() => setMenuOpen(false)}
            >
              Docs
            </Link>
            <Link
              className="m-lnk"
              href="/download"
              onClick={() => setMenuOpen(false)}
            >
              Download
            </Link>
            <a
              className="m-lnk"
              href={GITHUB_URL}
              target="_blank"
              rel="noopener noreferrer"
              onClick={() => setMenuOpen(false)}
            >
              GitHub
            </a>
            <Link
              className="nav-cta m-cta"
              href="/#install"
              onClick={() => setMenuOpen(false)}
            >
              <IconDownload /> Install
            </Link>
          </div>
        </div>
      )}
    </header>
  );
}
