"use client";

import { useState } from "react";
import { CodeBlock } from "./code-block";

const CURL = "curl -fsSL https://raw.githubusercontent.com/pungggi/remote_pi/main/pi-extension/install.sh | bash";
const HAVE_PI = `pi install npm:remote-pi
/remote-pi
/remote-pi pair`;

type Tab = {
  label: string;
  code: string;
  note: string;
  prompt: boolean;
  disabled?: boolean;
};

type InstallTabsProps = {
  /**
   * Controls the "No Pi yet" curl tab. Defaults to `true` now that the
   * installer ships and the site serves install.sh at the canonical domain.
   * Pass `false` to disable it with a "Coming soon" hint.
   */
  curlReady?: boolean;
};

/**
 * Two-tab install block for the Getting started tutorial, styled to match the
 * home install terminal. "No Pi yet" runs the curl installer; "Already have
 * Pi" adds the plugin to an existing Pi.
 */
export function InstallTabs({ curlReady = true }: InstallTabsProps) {
  const tabs: Record<string, Tab> = {
    "No Pi yet": {
      label: "bash — one command",
      code: CURL,
      prompt: true,
      disabled: !curlReady,
      note: "Installs Pi, the Piper plugin, and the always-on supervisor, then prints the pairing step. No sudo — everything lands in your home directory.",
    },
    "Already have Pi": {
      label: "pi — three commands",
      code: HAVE_PI,
      prompt: false,
      note: "Run them in order: install the plugin, run the setup wizard, then show the pairing QR. Each is explained below.",
    },
  };
  const keys = Object.keys(tabs);
  const [active, setActive] = useState(
    keys.find((k) => !tabs[k].disabled) ?? keys[0],
  );
  const d = tabs[active];

  return (
    <div className="install-card" style={{ marginTop: 22 }}>
      <div className="tabs" role="tablist" aria-label="Install Piper">
        {keys.map((t) => (
          <button
            key={t}
            type="button"
            role="tab"
            aria-selected={t === active}
            aria-disabled={tabs[t].disabled || undefined}
            disabled={tabs[t].disabled}
            className={`tab ${t === active ? "active" : ""}`}
            onClick={() => !tabs[t].disabled && setActive(t)}
          >
            {t}
            {tabs[t].disabled ? " · soon" : ""}
          </button>
        ))}
      </div>
      <CodeBlock label={d.label} code={d.code} prompt={d.prompt} />
      <p className="term-note" style={{ padding: "2px 4px 4px", margin: 0 }}>
        {d.note}
      </p>
    </div>
  );
}
