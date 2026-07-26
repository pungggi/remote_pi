import type { Metadata } from "next";
import type { ReactNode } from "react";
import Link from "next/link";
import { Callout } from "@/components/callout";
import { CodeBlock } from "@/components/code-block";
import { RevealController } from "@/components/landing/reveal-controller";
import {

  IconWindows,
  IconLinux,
  IconAndroid,
  IconDownload,
} from "@/components/landing/icons";
import { ShaCopy } from "@/components/download/sha-copy";
import {
  loadCockpitManifest,
  artifactFileName,
  formatBytes,
  ARCH_LABEL,
  type CockpitArtifact,
  type CockpitManifest,
} from "@/lib/cockpit-release";
import { loadAppManifest } from "@/lib/app-release";

export const metadata: Metadata = {
  title: "Download",
  description:
    "Download Piper — the desktop Cockpit (signed macOS, Windows, Linux) and the Android app (direct APK, no Play Store).",
};

const GETTING_STARTED = "/tutorials/getting-started";

/* A download card reads only these fields, so both manifests feed it. */
type CardArtifact = {
  format: string;
  arch: string;
  url: string;
  sha256: string;
  size: number;
};

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

function DownloadCard({
  artifact,
  live,
  archLabel,
  downloadLabel = "Download",
}: {
  artifact: CardArtifact;
  live: boolean;
  archLabel: string;
  downloadLabel?: string;
}) {
  return (
    <div className="dl-card">
      <div className="dl-card-top">
        <span className="dl-fmt">.{artifact.format}</span>
        <span className="dl-size">{formatBytes(artifact.size)}</span>
      </div>
      <div className="dl-arch">{archLabel}</div>
      <div className="dl-file">{artifactFileName(artifact)}</div>
      {live ? (
        <a className="btn btn-primary dl-btn" href={artifact.url} download>
          <IconDownload /> {downloadLabel}
        </a>
      ) : (
        <span
          className="btn dl-btn dl-btn-off"
          aria-disabled="true"
          title="Not published yet"
        >
          <IconDownload /> Unavailable
        </span>
      )}
      <ShaCopy sha256={artifact.sha256} />
    </div>
  );
}

/** Shared "not published" banner + release notes for a product band. */
function ReleaseNotes({
  version,
  notes,
  live,
}: {
  version: string;
  notes: string;
  live: boolean;
}) {
  return (
    <>
      {!live ? (
        <div className="reveal" style={{ marginTop: 24, maxWidth: 760 }}>
          <Callout variant="warning" title="Not published yet">
            <p>
              These builds haven&apos;t been published to the download host yet,
              so the links below aren&apos;t live. The version, size, and
              checksum are a preview of the layout — check back soon.
            </p>
          </Callout>
        </div>
      ) : null}
      {notes ? (
        <div className="reveal" style={{ marginTop: 20, maxWidth: 760 }}>
          <Callout title={`What's new in ${version}`}>
            <p>{notes}</p>
          </Callout>
        </div>
      ) : null}
    </>
  );
}

type OsGroup = {
  id: string;
  name: string;
  icon: ReactNode;
  tagline: string;
  select: (m: CockpitManifest) => CockpitArtifact[];
  instructions: (m: CockpitManifest) => ReactNode;
};

const OS_GROUPS: OsGroup[] = [
  // No macOS group: this fork does not publish a macOS Cockpit build (no
  // Apple signing identity, so the job left cockpit-release.yml). The old
  // entry also promised a notarized, Developer-ID-signed dmg — untrue here.
  {
    id: "windows",
    name: "Windows",
    icon: <IconWindows />,
    tagline: "Installer for Windows 10 and 11 on x64.",
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
      </div>
    ),
  },
];

export default async function DownloadPage() {
  const [cockpit, app] = await Promise.all([
    loadCockpitManifest(),
    loadAppManifest(),
  ]);
  const apk = app.manifest.artifacts[0];

  return (
    <div className="page">
      <div className="page-body">
        <div className="wrap">
          <header className="page-head reveal" style={{ maxWidth: 760 }}>
            <span className="eyebrow">Download</span>
            <h1>Download Piper</h1>
            <p className="lede">
              The desktop Cockpit and the phone app, built straight from CI. Grab
              the Cockpit to drive your Pi coding agents from your computer, and
              the Android app to carry them in your pocket.
            </p>
          </header>

          {/* ---------- Cockpit (desktop) ---------- */}
          <section className="dl-product reveal" id="cockpit">
            <div className="section-head">
              <span className="eyebrow">Desktop · Cockpit</span>
              <h2>Piper Cockpit</h2>
              <p>
                Pair from your Mac, Windows, or Linux machine, watch live
                sessions, and manage your 24/7 daemons and schedules from one
                window.
              </p>
            </div>
            <div className="dl-meta">
              <span>Version {cockpit.manifest.version}</span>
              <span>Released {cockpit.manifest.date}</span>
              <span>Signed &amp; notarized on macOS</span>
            </div>

            <ReleaseNotes
              version={cockpit.manifest.version}
              notes={cockpit.manifest.notes}
              live={cockpit.live}
            />

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
                    </div>
                  </div>
                  <div className="dl-cards">
                    {artifacts.map((a) => (
                      <DownloadCard
                        key={`${a.format}-${a.arch}`}
                        artifact={a}
                        live={cockpit.live}
                        archLabel={ARCH_LABEL[a.arch]}
                      />
                    ))}
                  </div>
                  <div className="dl-os-help">
                    {group.instructions(cockpit.manifest)}
                  </div>
                </section>
              );
            })}

            <div className="dl-foot">
              <p>
                Cockpit drives a local Pi install — it doesn&apos;t bundle one.
                The app&apos;s onboarding checks for <code>pi</code>, the Remote
                Pi plugin, and the supervisor, and walks you through anything
                missing. New here?{" "}
                <Link href={GETTING_STARTED}>Start with the setup guide</Link>.
              </p>
            </div>
          </section>

          {/* ---------- App (Android) ---------- */}
          <section className="dl-product reveal" id="android">
            <div className="section-head">
              <span className="eyebrow">Mobile · Android</span>
              <h2>Piper — App (Android)</h2>
              <p>
                The phone app — pair once with a QR, then drive your agents from
                anywhere. Installed straight from an APK, no Play Store needed.
              </p>
            </div>
            <div className="dl-meta">
              <span>Version {app.manifest.version}</span>
              <span>Released {app.manifest.date}</span>
              <span>Direct APK · signed release</span>
            </div>

            <ReleaseNotes
              version={app.manifest.version}
              notes={app.manifest.notes}
              live={app.live}
            />

            {apk ? (
              <div className="dl-os" id="android-build">
                <div className="dl-os-head">
                  <span className="dl-os-icon">
                    <IconAndroid />
                  </span>
                  <div className="dl-os-titles">
                    <h3>Android</h3>
                    <p>One universal APK for phones and tablets.</p>
                  </div>
                </div>
                <div className="dl-cards dl-cards-solo">
                  <DownloadCard
                    artifact={apk}
                    live={app.live}
                    archLabel="Universal APK"
                    downloadLabel="Download RemotePi.apk"
                  />
                </div>
                <div className="dl-os-help">
                  <div className="dl-note">
                    <ol>
                      <li>
                        Download <code>RemotePi.apk</code> to your phone.
                      </li>
                      <li>Tap the file to start installing.</li>
                      <li>
                        If Android blocks it, allow your browser to{" "}
                        <strong>install unknown apps</strong> when prompted, then
                        continue.
                      </li>
                      <li>
                        Optional: check the <strong>SHA-256</strong> above
                        matches the file before installing.
                      </li>
                    </ol>
                    <p className="dl-note-foot">
                      The APK is the only channel — Piper has no store listing,
                      and iOS is not supported.
                    </p>
                  </div>
                </div>
              </div>
            ) : null}
          </section>
        </div>
      </div>
      <RevealController />
    </div>
  );
}
