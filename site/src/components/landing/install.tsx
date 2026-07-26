"use client";

import { useState, type ReactNode } from "react";
import { IconCopy, IconCheck } from "@/components/landing/icons";

type TermLine = { p: string; c: string };
type InstallTab = {
  label: string;
  lines: TermLine[];
  copy: string;
  note: ReactNode;
};

const CURL = "curl -fsSL https://raw.githubusercontent.com/pungggi/remote_pi/main/pi-extension/install.sh | bash";

const INSTALL_TABS: Record<string, InstallTab> = {
  "No Pi yet": {
    label: "bash — fresh machine",
    lines: [{ p: "$", c: CURL }],
    copy: CURL,
    note: (
      <>
        Installs <b>Pi</b>, the Remote&nbsp;Pi plugin, and the always-on
        supervisor — then prints the pairing step. No sudo; everything lands in
        your home directory.
      </>
    ),
  },
  "Already have Pi": {
    label: "bash + Pi",
    lines: [
      { p: "$", c: "pi install npm:remote-pi" },
      { p: "›", c: "/remote-pi" },
      { p: "›", c: "/remote-pi pair" },
    ],
    copy: "pi install npm:remote-pi",
    note: (
      <>
        Run the first line in your shell; the <code>/remote-pi</code> lines run
        inside <b>Pi</b>. The first <code>/remote-pi</code> is a quick setup
        wizard (name + relay), then <b>pair</b> shows a QR you scan with the app.
      </>
    ),
  },
};

export function Install() {
  const tabs = Object.keys(INSTALL_TABS);
  const [active, setActive] = useState(tabs[0]);
  const [copied, setCopied] = useState(false);
  const data = INSTALL_TABS[active];

  const copy = () => {
    if (navigator.clipboard) navigator.clipboard.writeText(data.copy);
    setCopied(true);
    setTimeout(() => setCopied(false), 1600);
  };

  return (
    <section className="section" id="install">
      <div className="wrap">
        <div className="section-head reveal">
          <span className="eyebrow">Install</span>
          <h2>One command, then scan a QR.</h2>
          <p>
            No accounts, no sign-up. Add the plugin to Pi, pair your phone once,
            and you&apos;re driving every agent from your pocket.
          </p>
        </div>

        <div className="install-card reveal">
          <div className="tabs" role="tablist" aria-label="Install Piper">
            {tabs.map((t) => (
              <button
                key={t}
                type="button"
                role="tab"
                aria-selected={t === active}
                className={`tab ${t === active ? "active" : ""}`}
                onClick={() => {
                  setActive(t);
                  setCopied(false);
                }}
              >
                {t}
              </button>
            ))}
          </div>

          <div className="terminal">
            <div className="term-bar">
              <span className="lights">
                <i />
                <i />
                <i />
              </span>
              <span className="tlabel">{data.label}</span>
              <button
                type="button"
                className={`copy-btn ${copied ? "copied" : ""}`}
                onClick={copy}
              >
                {copied ? <IconCheck /> : <IconCopy />} {copied ? "Copied" : "Copy"}
              </button>
            </div>
            <div className="term-body">
              {data.lines.map((line, i) => (
                <div className="term-line" key={i}>
                  <span className="pr">{line.p}</span>
                  <span className="cmd">{line.c}</span>
                </div>
              ))}
            </div>
            <p className="term-note">{data.note}</p>
          </div>
        </div>
      </div>
    </section>
  );
}
