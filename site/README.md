# Piper — Site

Landing page for [Piper](https://github.com/pungggi/remote_pi) — your coding
agents, in your pocket.

This package ships three static routes:

- `/` — landing (hero, features, quick start, GitHub CTA)
- `/terms` — Terms of Service
- `/privacy` — Privacy Policy

Source: <https://github.com/pungggi/remote_pi> (no dedicated deployment domain
in this fork yet).

## Stack

- Next.js 16 (App Router) + React 19
- TypeScript 5 (strict)
- Tailwind 4 (via `@tailwindcss/postcss`)
- ESLint 9
- Package manager: **pnpm**

Dark-only theme; visual identity lives in `../branding/`.

## Commands

```bash
pnpm install   # install deps
pnpm dev       # dev server at http://localhost:3000
pnpm build     # production build (SSG)
pnpm start     # serve the production build
pnpm lint      # ESLint
```

## Layout

```
src/
├── app/
│   ├── layout.tsx              # Root layout: header + main + footer, global metadata
│   ├── page.tsx                # Landing
│   ├── icon.svg                # Favicon (served as /icon.svg)
│   ├── opengraph-image.tsx     # Generated OG image (next/og)
│   ├── globals.css             # Tailwind + design tokens
│   ├── terms/page.tsx
│   └── privacy/page.tsx
└── components/
    ├── header.tsx              # Logo + nav
    ├── footer.tsx              # Terms/Privacy/GitHub + copyright
    ├── hero.tsx                # Landing hero
    ├── feature-card.tsx        # Reusable card
    ├── code-block.tsx          # Snippet block
    └── legal-shell.tsx         # Shared shell for legal pages
```

## Conventions

- **Server components by default** — only opt into `"use client"` when state, events, or hooks are needed.
- **No backend / API routes** in the MVP. The site is purely presentational.
- **No analytics, no tracking cookies.** Aligned with the project's privacy posture.
- **English only** in the MVP. PT-BR is a separate plan if demand appears.

## Deploy

No deployment for this fork yet. Next.js builds to static output (SSG), so any
static host (Vercel, GitHub Pages, a CDN) works; domain wiring is handled
outside this repo once a domain exists.
