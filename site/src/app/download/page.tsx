import type { Metadata } from "next";
import type { ReactNode } from "react";
import Link from "next/link";
import { Callout } from "@/components/callout";
import { CodeBlock } from "@/components/code-block";
import { RevealController } from "@/components/landing/reveal-controller";
import {
  IconWindows,
  IconLinux,
} from "@/components/landing/icons";
import {
  DownloadCard,
  ReleaseNotes,
} from "@/components/download/download-card";
import { PlatformPicker } from "@/components/download/platform-picker";
import {
  loadCockpitManifest,
  ARCH_LABEL,
  type CockpitArtifact,
  type CockpitManifest,
} from "@/lib/cockpit-release";

export const metadata: Metadata = {
  title: "Download",
  description:
    "Download Piper Cockpit for Windows and Linux, plus the one-line cockpit-server installer for a Linux host.",
};

const GITHUB_RELEASES =
  "https://github.com/pungggi/remote_pi/releases/tag/cockpit-v";
const GITHUB_RELEASE_DOWNLOAD =
  "https://github.com/pungggi/remote_pi/releases/download/cockpit-v";
const INSTALL_SCRIPT_URL =
  "https://raw.githubusercontent.com/pungggi/remote_pi/main/cockpit/install-server.sh";
const INSTALL_SCRIPT_RAW = INSTALL_SCRIPT_URL;

/* Order Linux packages deb-then-rpm, x64-then-arm64 for a stable card grid. */
const LINUX_ORDER: Record<string, number> = {
  "deb:x64": 0,
  "deb:arm64": 1,
  "rpm:x64": 2,
  "rpm:arm64": 3,
};

function linuxSort(a: CockpitArtifact, b: CockpitArtifact): number {
  const ka = LINUX_ORDER[`${a.format}:${a.arch}`] ?? 99;
  const kb = LINUX_ORDER[`${b.format}:${b.arch}`] ?? 99;
  return ka - kb;
}

type OsGroup = {
  id: string;
  name: string;
  icon: ReactNode;
  tagline: string;
  select: (m: CockpitManifest) => CockpitArtifact[];
  instructions: (m: CockpitManifest) => ReactNode;
  /** Card label for an artifact, when the plain architecture name is not enough. */
  archLabel?: (a: CockpitArtifact) => string;
  /** Minimum system this build runs on, shown next to the cards. */
  requirements: string;
};

const OS_GROUPS: OsGroup[] = [
  {
    id: "windows",
    name: "Windows",
    icon: <IconWindows />,
    tagline: "Installer for Windows 10 and 11 on x64.",
    requirements: "Windows 10 or 11, x64. There is no native arm64 build.",
    select: (m) => m.artifacts.filter((a) => a.platform === "windows"),
    instructions: () => (
      <Callout variant="warning" title="SmartScreen notice">
        <p>
          This build isn&apos;t code-signed yet, so Windows SmartScreen may warn
          that the publisher is unknown. To continue:
        </p>
        <p>
          Click <strong>More info</strong>, then <strong>Run anyway</strong> —
          and follow the installer.
        </p>
      </Callout>
    ),
  },
  {
    id: "linux",
    name: "Linux",
    icon: <IconLinux />,
    tagline: ".deb and .rpm packages for x86_64 and arm64.",
    requirements:
      "GTK3 with libmpv, libsecret and ALSA, on x86_64 or arm64. Built and tested on Ubuntu 24.04 and Fedora 40.",
    select: (m) =>
      m.artifacts.filter((a) => a.platform === "linux").sort(linuxSort),
    instructions: (m) => (
      <div className="dl-note">
        <p>Download the package for your architecture, then install it:</p>
        <CodeBlock
          label="Debian / Ubuntu — .deb"
          code={`sudo dpkg -i remote-pi-cockpit_${m.version}_amd64.deb\nsudo apt-get install -f   # pull in any missing dependencies`}
        />
        <CodeBlock
          label="Fedora / RHEL — .rpm"
          code={`sudo dnf install ./remote-pi-cockpit-${m.version}.x86_64.rpm`}
        />
        <p className="dl-note-foot">
          Swap <code>amd64</code>/<code>x86_64</code> for <code>arm64</code>/
          <code>aarch64</code> on ARM machines. The app then appears in your
          applications menu.
        </p>
        <Callout variant="warning" title="Close Cockpit before updating">
          <p>
            Installing a package over a running Cockpit replaces files the app
            has open. Quit it first, then install, then start it again.
          </p>
        </Callout>
      </div>
    ),
  },
];

export default async function DownloadPage() {
  const cockpit = await loadCockpitManifest();

  return (
    <div className="page">
      <div className="page-body">
        <div className="wrap">
          <header className="page-head reveal" style={{ maxWidth: 760 }}>
            <span className="eyebrow">Download</span>
            <h1>Download Piper Cockpit</h1>
            <p className="lede">
              Built straight from CI, with a published SHA-256 for every file.
              Take the Windows or Linux desktop app, or install cockpit-server
              on a Linux host you want to reach over SSH.
            </p>
          </header>

          <div className="reveal">
            <PlatformPicker
              artifacts={cockpit.manifest.artifacts.filter(
                (a) => a.platform === "windows" || a.platform === "linux",
              )}
              live={cockpit.live}
              version={cockpit.manifest.version}
            />
          </div>

          {/* ---------- Cockpit (desktop) ---------- */}
          <section className="dl-product reveal" id="cockpit">
            <div className="section-head">
              <span className="eyebrow">Desktop · Cockpit</span>
              <h2>Piper Cockpit</h2>
              <p>
                A multiplexed terminal where an IDE grows around your agents:
                viewer, diagnostics, git, worktrees and databases, on your own
                machine or on any host you reach over SSH.
              </p>
            </div>
            <div className="dl-meta">
              <span>Version {cockpit.manifest.version}</span>
              <span>Released {cockpit.manifest.date}</span>
              <span>Windows and Linux packages</span>
            </div>

            <ReleaseNotes
              version={cockpit.manifest.version}
              notes={cockpit.manifest.notes}
              live={cockpit.live}
              releaseUrl={`${GITHUB_RELEASES}${cockpit.manifest.version}`}
            />

            <div id="platforms">
              {OS_GROUPS.map((group) => {
              const artifacts = group.select(cockpit.manifest);
              if (artifacts.length === 0) return null;
              return (
                <section className="dl-os" key={group.id} id={group.id}>
                  <div className="dl-os-head">
                    <span className="dl-os-icon">{group.icon}</span>
                    <div className="dl-os-titles">
                      <h3>{group.name}</h3>
                      <p>{group.tagline}</p>
                      <p className="dl-req">
                        <span>Requires</span> {group.requirements}
                      </p>
                    </div>
                  </div>
                  <div className="dl-cards">
                    {artifacts.map((a) => (
                      <DownloadCard
                        key={`${a.format}-${a.arch}`}
                        artifact={a}
                        live={cockpit.live}
                        archLabel={
                          group.archLabel
                            ? group.archLabel(a)
                            : ARCH_LABEL[a.arch]
                        }
                      />
                    ))}
                  </div>
                  <div className="dl-os-help">
                    {group.instructions(cockpit.manifest)}
                  </div>
                </section>
              );
              })}
            </div>

            {/* ---------- updates + checksums ---------- */}
            <section className="dl-os dl-os-bare" id="updates">
              <div className="dl-os-head">
                <div className="dl-os-titles">
                  <h3>Updates</h3>
                  <p>How each platform gets the next version.</p>
                </div>
              </div>
              <div className="dl-os-help">
                <div className="dl-note">
                  <p>
                    On <strong>Windows</strong>, Cockpit updates itself: it
                    checks a signed appcast (WinSparkle), downloads the new
                    build and restarts into it. You can keep the installer you
                    downloaded once and never come back here.
                  </p>
                  <p>
                    On <strong>Linux</strong> there is no self-update. The app
                    tells you when a release is out, and you install the new{" "}
                    <code>.deb</code> or <code>.rpm</code> yourself, with
                    Cockpit closed.
                  </p>
                  <p className="dl-note-foot">
                    A remote host is separate: its{" "}
                    <code>cockpit-server</code> has to run the same version as
                    the app, so update it by re-running the installer. See{" "}
                    <a href="#vps">the section below</a>.
                  </p>
                </div>
              </div>
            </section>

            <section className="dl-os dl-os-bare" id="verify">
              <div className="dl-os-head">
                <div className="dl-os-titles">
                  <h3>Verify your download</h3>
                  <p>
                    Every card above carries the SHA-256 of that exact file.
                    Compare it with the one your machine computes.
                  </p>
                </div>
              </div>
              <div className="dl-os-help">
                <div className="dl-note">
                  <CodeBlock
                    label="Windows · PowerShell"
                    code={`Get-FileHash .\\RemotePiCockpit-Setup-${cockpit.manifest.version}-windows-x64.exe -Algorithm SHA256`}
                  />
                  <CodeBlock
                    label="Linux"
                    prompt
                    code={`sha256sum remote-pi-cockpit_${cockpit.manifest.version}_amd64.deb`}
                  />
                  <p className="dl-note-foot">
                    The full list for this release, every platform in one file,
                    is published as{" "}
                    <a
                      href={`${GITHUB_RELEASE_DOWNLOAD}${cockpit.manifest.version}/SHA256SUMS`}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      SHA256SUMS
                    </a>
                    . If a hash does not match, do not install the file.
                  </p>
                </div>
              </div>
            </section>

            <div className="dl-foot">
              <p>
                Cockpit is a terminal first: no account, no cloud, nothing else
                to install. Agents run as ordinary processes in its tabs, so you
                bring the harness you already use (Claude Code, Codex CLI, Pi,
                OpenCode). Every command and file format lives in the{" "}
                <Link href="/docs">Cockpit reference</Link>.
              </p>
            </div>
          </section>

          {/* ---------- cockpit-server (Linux host / VPS) ---------- */}
          <section className="dl-product reveal" id="vps">
            <div className="section-head">
              <span className="eyebrow">Linux host · cockpit-server</span>
              <h2>Put Cockpit on a machine with no desktop</h2>
              <p>
                One command turns a VPS, a build server or a Raspberry Pi into a
                host you can open as a remote workspace over SSH.
              </p>
            </div>
            <div className="dl-meta">
              <span>Linux x86_64 and arm64</span>
              <span>User space, no sudo</span>
              <span>Idempotent, re-run to update</span>
            </div>

            <div className="dl-os" id="vps-install">
              <div className="dl-os-head">
                <span className="dl-os-icon">
                  <IconLinux />
                </span>
                <div className="dl-os-titles">
                  <h3>Install the server</h3>
                  <p>Run this on the host, over SSH.</p>
                </div>
              </div>
              <div className="dl-os-help">
                <div className="dl-note">
                  <CodeBlock
                    label="on the host"
                    code={`curl -fsSL ${INSTALL_SCRIPT_URL} | bash`}
                  />
                  <p>
                    The script detects the architecture, downloads the matching
                    <code>cockpit-server</code> zip from the GitHub release,
                    verifies its SHA-256 and installs into{" "}
                    <code>~/.cockpit/server</code>, linking the binary into{" "}
                    <code>~/.local/bin</code>. Nothing is exposed on the network:
                    the app talks to it through an SSH tunnel.
                  </p>
                  <CodeBlock
                    label="variants"
                    code={`# register a systemd --user unit so the server is up after a reboot
curl -fsSL ${INSTALL_SCRIPT_URL} | bash -s -- --service

# pin a version instead of taking the latest release
COCKPIT_VERSION=${cockpit.manifest.version} curl -fsSL ${INSTALL_SCRIPT_URL} | bash`}
                  />
                  <p className="dl-note-foot">
                    Piping a script into <code>bash</code> deserves a look first:
                    read{" "}
                    <a
                      href={INSTALL_SCRIPT_RAW}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      the source of the installer
                    </a>{" "}
                    or download it, read it, and run it as a file.
                  </p>
                </div>
              </div>
              <div className="dl-os-help">
                <Callout variant="warning" title="Versions must match">
                  <p>
                    Client and server are released together, and the app refuses
                    a host running a different version. Keep both on the same
                    release, or pin the server with{" "}
                    <code>COCKPIT_VERSION={cockpit.manifest.version}</code>. A desktop client
                    fixes a mismatch by itself over SSH; otherwise, re-run the
                    installer on the host.
                  </p>
                </Callout>
              </div>
            </div>

            <div className="dl-foot">
              <p>
                Start at boot needs <em>linger</em> on most distributions; the{" "}
                <code>--service</code> path tries to enable it and prints the one
                <code>sudo</code> line to run when it cannot. The full story,
                including how a desktop installs the server for you and what to
                do when a connection fails, is in the{" "}
                <Link href="/docs#remote">remote hosts reference</Link>.
              </p>
            </div>
          </section>

        </div>
      </div>
      <RevealController />
    </div>
  );
}
