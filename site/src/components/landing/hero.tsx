"use client";

import { useEffect, useMemo, useState, Fragment } from "react";
import {
  IconDownload,
  IconGithub,
  IconChevronLeft,
  IconTerminal,
  IconPaperclip,
  IconStop,
} from "@/components/landing/icons";

const GITHUB_URL = "https://github.com/pungggi/remote_pi";

/* ---------- living mesh background ---------- */
function HeroMesh() {
  // node positions in a 1000x700 viewBox
  const nodes = [
    { x: 120, y: 110 },
    { x: 300, y: 70 },
    { x: 80, y: 320 },
    { x: 250, y: 430 },
    { x: 470, y: 250 },
    { x: 430, y: 540 },
    { x: 640, y: 130 },
    { x: 760, y: 360 },
    { x: 900, y: 200 },
    { x: 870, y: 500 },
    { x: 600, y: 420 },
  ];
  const links: [number, number][] = [
    [0, 1], [0, 2], [1, 4], [2, 3], [3, 5], [4, 6], [4, 10],
    [6, 8], [7, 8], [7, 9], [10, 7], [5, 10], [1, 6], [3, 4],
  ];
  return (
    <div className="hero-mesh" aria-hidden="true">
      <svg viewBox="0 0 1000 700" preserveAspectRatio="xMidYMid slice">
        <g stroke="rgba(0, 255, 65,0.16)" fill="none">
          {links.map(([a, b], i) => (
            <line
              key={i}
              x1={nodes[a].x}
              y1={nodes[a].y}
              x2={nodes[b].x}
              y2={nodes[b].y}
              strokeWidth="1.2"
              strokeDasharray="5 9"
              style={{ animation: `dash ${14 + (i % 6) * 3}s linear infinite`, opacity: 0.8 }}
            />
          ))}
        </g>
        {nodes.map((n, i) => (
          <g key={i}>
            <circle cx={n.x} cy={n.y} r="14" fill="rgba(0, 255, 65,0.05)" />
            <circle
              cx={n.x}
              cy={n.y}
              r="3.4"
              fill="#00ff41"
              style={{ animation: `pulseNode ${3 + (i % 5) * 0.6}s ease-in-out ${i * 0.4}s infinite` }}
            />
          </g>
        ))}
      </svg>
    </div>
  );
}

/* ---------- animated phone driving an agent ---------- */
type ChatItem =
  | { type: "user"; text: string }
  | { type: "tool"; kind: string; cmd: string }
  | { type: "md"; text: string };

const CHAT_ITEMS: ChatItem[] = [
  { type: "user", text: "hello" },
  { type: "tool", kind: "READ", cmd: "$ path=~/.pi/skills/agent-network/SKILL.md" },
  { type: "tool", kind: "BASH", cmd: '$ find ~/.pi -name "pair*" -o -name "join*" | head -20' },
  {
    type: "md",
    text: "This is a Pi Agent Network pairing code. `Frontend` is asking to connect to this machine — processing the link now.",
  },
];

function parseSegs(text: string) {
  return text
    .split(/(`[^`]+`)/g)
    .filter(Boolean)
    .map((p) =>
      p.startsWith("`") && p.endsWith("`")
        ? { code: true, str: p.slice(1, -1) }
        : { code: false, str: p },
    );
}

function TypedMd({ text }: { text: string }) {
  const segs = useMemo(() => parseSegs(text), [text]);
  const total = segs.reduce((a, s) => a + s.str.length, 0);
  const [n, setN] = useState(0);
  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let i = 0;
    const id = setInterval(
      () => {
        i = reduce ? total : i + 1;
        setN(i);
        if (i >= total) clearInterval(id);
      },
      reduce ? 0 : 24,
    );
    return () => clearInterval(id);
  }, [text, total]);

  let left = n;
  const out: React.ReactNode[] = [];
  segs.forEach((s, i) => {
    if (left <= 0) return;
    const take = Math.min(left, s.str.length);
    const piece = s.str.slice(0, take);
    left -= take;
    out.push(s.code ? <code key={i}>{piece}</code> : <Fragment key={i}>{piece}</Fragment>);
  });
  return (
    <div className="md-response">
      {out}
      <span className="caret" />
    </div>
  );
}

function ToolCard({ kind, cmd }: { kind: string; cmd: string }) {
  return (
    <div className="tool">
      <div className="tool-head">
        <span className="l">
          <span className="ticon">
            <IconTerminal />
          </span>
          {kind}
        </span>
        <span className="status">DONE</span>
      </div>
      <div className="tool-code">{cmd}</div>
      <div className="tool-done">✓ Done</div>
    </div>
  );
}

function PhoneHero() {
  const [step, setStep] = useState(1);
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      const id = setTimeout(() => setStep(CHAT_ITEMS.length), 0);
      return () => clearTimeout(id);
    }
    let timer: ReturnType<typeof setTimeout>;
    let s = 1;
    const durFor = (idx: number) => {
      const it = CHAT_ITEMS[idx];
      if (!it) return 1400;
      if (it.type === "md") return it.text.length * 24 + 2600;
      if (it.type === "tool") return 1300;
      return 1100;
    };
    const advance = () => {
      timer = setTimeout(() => {
        if (s >= CHAT_ITEMS.length) {
          s = 1;
          setStep(1);
        } else {
          s += 1;
          setStep(s);
        }
        advance();
      }, durFor(s - 1));
    };
    advance();
    return () => clearTimeout(timer);
  }, []);

  const shown = CHAT_ITEMS.slice(0, step);

  return (
    <div className="phone-stage">
      <div className="float-chip c1">
        <span className="led" /> 4 agents · 1 mesh
      </div>
      <div className="float-chip c3">
        <span className="led" /> daemon · answers at 3am
      </div>

      <div className="phone">
        <div className="phone-screen">
          <div className="phone-statusbar">
            <span>9:21</span>
            <span className="dots">
              <i />
              <i />
              <i />
            </span>
          </div>

          <div className="app-bar">
            <span className="back">
              <IconChevronLeft />
            </span>
            <div className="ab-title">
              <div className="t">Frontend</div>
              <div className="sub">
                <span className="host">MacBook</span>
                <span className="dot" />
                <span className="state">working…</span>
              </div>
            </div>
          </div>

          <div className="chat-body">
            {shown.map((m, i) => {
              if (m.type === "user") return <div key={i} className="bubble me">{m.text}</div>;
              if (m.type === "tool") return <ToolCard key={i} kind={m.kind} cmd={m.cmd} />;
              return <TypedMd key={"md" + step} text={m.text} />;
            })}
          </div>

          <div className="app-input">
            <span className="clip">
              <IconPaperclip />
            </span>
            <span className="field">Waiting for response…</span>
            <span className="stop">
              <IconStop />
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}

export function Hero() {
  return (
    <section className="hero">
      <HeroMesh />
      <div className="wrap">
        <div className="hero-grid">
          <div className="hero-copy">
            <span className="eyebrow">Open source · self-hostable</span>
            <h1>
              Your agents,
              <br />
              in your <span className="pocket">pocket.</span>
            </h1>
            <p className="hero-sub">
              Pair your phone once — then drive any agent, keep a fleet running
              24/7, and link every machine into one mesh.
            </p>
            <div className="hero-cta">
              <a className="btn btn-primary" href="#install">
                <IconDownload /> Install
              </a>
              <a
                className="btn btn-ghost"
                href={GITHUB_URL}
                target="_blank"
                rel="noopener noreferrer"
              >
                <IconGithub /> GitHub
              </a>
            </div>
            <div className="hero-meta">
              <span>one command to install</span>
              <span>no accounts</span>
              <span>MIT licensed</span>
            </div>
          </div>
          <PhoneHero />
        </div>
      </div>
    </section>
  );
}
