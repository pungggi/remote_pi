import Link from "next/link";

const GITHUB_URL = "https://github.com/pungggi/remote_pi";

export function SiteFooter() {
  return (
    <footer className="footer">
      <div className="wrap footer-inner">
        <div className="copy">
          <b>Piper</b> — open source under the MIT license. Software, not a
          service: no account, no relay operated for you.
        </div>
        <nav className="footer-links">
          <Link href="/cockpit">Cockpit</Link>
          <Link href="/download">Download</Link>
          <Link href="/terms">Terms</Link>
          <Link href="/privacy">Privacy Policy</Link>
          <a
            href={`${GITHUB_URL}/blob/main/PROTOCOL.md`}
            target="_blank"
            rel="noopener noreferrer"
          >
            Protocol
          </a>
          <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
            GitHub
          </a>
        </nav>
      </div>
    </footer>
  );
}
