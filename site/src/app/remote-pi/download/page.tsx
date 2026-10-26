import type { Metadata } from "next";
import Link from "next/link";
import { RevealController } from "@/components/landing/reveal-controller";
import { IconAndroid } from "@/components/landing/icons";
import {
  DownloadCard,
  ReleaseNotes,
} from "@/components/download/download-card";
import { loadAppManifest } from "@/lib/app-release";

export const metadata: Metadata = {
  title: "Download the Piper app",
  description:
    "Get the Piper phone app as a direct Android APK with its published SHA-256. No store listing and no iOS build.",
};

export default async function RemotePiDownloadPage() {
  const app = await loadAppManifest();
  const apk = app.manifest.artifacts[0];

  return (
    <div className="page">
      <div className="page-body">
        <div className="wrap">
          <header className="page-head reveal" style={{ maxWidth: 760 }}>
            <span className="eyebrow">Piper · Download</span>
            <h1>Get the Piper app</h1>
            <p className="lede">
              The phone app is the authenticator and the remote control: pair
              once with a QR, then drive your agents from anywhere. Install the
              signed Android APK directly.
            </p>
          </header>

          <section className="dl-product reveal" id="android">
            <div className="section-head">
              <span className="eyebrow">Mobile · Android</span>
              <h2>Piper for Android</h2>
              <p>
                Straight from CI, signed, with a published SHA-256. No Play
                Store account needed.
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
                        <strong>install unknown apps</strong> when prompted,
                        then continue.
                      </li>
                      <li>
                        Optional: check the <strong>SHA-256</strong> above
                        matches the file before installing.
                      </li>
                    </ol>
                    <p className="dl-note-foot">
                      The APK is the only channel: there is no Play Store
                      listing, and iOS is not supported.
                    </p>
                  </div>
                </div>
              </div>
            ) : null}

            <div className="dl-foot">
              <p>
                The app drives agents on your machines, so install the{" "}
                <code>remote-pi</code> side first:{" "}
                <Link href="/remote-pi/tutorials/getting-started">
                  the getting started guide
                </Link>{" "}
                goes from a fresh machine to a paired phone. Looking for the
                Cockpit desktop app instead? It has its own{" "}
                <Link href="/download">download page</Link>.
              </p>
            </div>
          </section>
        </div>
      </div>
      <RevealController />
    </div>
  );
}
