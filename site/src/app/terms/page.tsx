import type { Metadata } from "next";
import Link from "next/link";
import { LegalShell, LegalSection } from "@/components/legal-shell";

export const metadata: Metadata = {
  title: "Terms",
  description:
    "Terms for Piper — MIT-licensed software provided as is. There is no hosted service, no account, and no relay operated on your behalf.",
};

const CONTACT_EMAIL = "alessandro@pungitore.ch";
const GITHUB_URL = "https://github.com/pungggi/remote_pi";

export default function TermsPage() {
  return (
    <LegalShell
      title="Terms"
      lastUpdated="2026-07-26"
      subtitle={
        <p>
          Piper is <strong className="text-fg">MIT-licensed software</strong>,
          not a hosted service. These terms describe what that means in
          practice; the licence itself is the binding grant, and it is in the{" "}
          <a
            className="text-accent underline"
            href={`${GITHUB_URL}/blob/main/LICENSE`}
            target="_blank"
            rel="noopener noreferrer"
          >
            repository
          </a>
          .
        </p>
      }
    >
      <LegalSection id="what" number={1} title="What You Are Getting">
        <p>
          Piper is a set of open-source programs: a phone app, an extension for
          the Pi coding agent, a desktop Cockpit, and a relay. You download
          them and run them on your own hardware.
        </p>
        <p>
          There is <strong className="text-fg">no service behind them</strong>.
          No account, no sign-up, no subscription, no server operated on your
          behalf — including no public relay. Nothing here is sold, so there is
          no purchase, no billing, and no consumer transaction between you and
          the maintainer.
        </p>
      </LegalSection>

      <LegalSection id="licence" number={2} title="Licence">
        <p>
          The source is released under the MIT licence: you may use, copy,
          modify, merge, publish, distribute, sublicense, and sell copies,
          subject to the licence text keeping its copyright notice. That licence
          governs your rights to the code, and nothing on this page narrows it.
        </p>
        <p>
          The name <strong className="text-fg">Piper</strong> and the project&apos;s
          visual identity are not part of the code grant. Fork freely — just
          don&apos;t ship a modified build under this name in a way that
          suggests it is the same project.
        </p>
      </LegalSection>

      <LegalSection id="as-is" number={3} title="Provided As Is">
        <p>
          The software is provided <strong className="text-fg">&quot;as is&quot;,
          without warranty of any kind</strong>, express or implied, including
          merchantability, fitness for a particular purpose, and
          non-infringement. To the maximum extent permitted by law, the authors
          and copyright holders are not liable for any claim, damages, or other
          liability arising from the software or its use — including lost data,
          lost work, or anything an agent does while you are not watching.
        </p>
        <p>
          This is the MIT disclaimer restated, not an extra condition. Nothing
          here excludes liability that cannot lawfully be excluded.
        </p>
      </LegalSection>

      <LegalSection id="you-run-it" number={4} title="You Are the Operator">
        <p>
          Because you run every component, you are responsible for how they are
          configured and what they can reach:
        </p>
        <ul className="ml-6 list-disc space-y-2">
          <li>
            Keeping your devices and their pairings secure. Anyone with access
            to a paired device can drive the agent on the other end. Revoke a
            pairing from the app, or with{" "}
            <code className="rounded bg-surface px-1.5 py-0.5 font-mono text-xs text-fg">
              /remote-pi revoke &lt;id&gt;
            </code>
            .
          </li>
          <li>
            The relay you start, including who can reach its port and what it
            forwards. Payloads are not end-to-end encrypted at the application
            layer — see the{" "}
            <Link href="/privacy#your-relay" className="text-accent underline">
              Privacy Policy, §5
            </Link>
            .
          </li>
          <li>
            What you ask the agent to do. It executes commands on a real
            machine with your permissions.
          </li>
          <li>
            Complying with the terms of any third party you connect — model
            providers above all, whose policies govern the prompts you send
            them.
          </li>
        </ul>
      </LegalSection>

      <LegalSection id="conduct" number={5} title="Don't Use It to Attack People">
        <p>
          Obvious, but stated: do not use Piper to break into systems you are
          not authorised to access, to impersonate someone else&apos;s paired
          device, or to attack infrastructure — including a relay operated by
          someone other than you. Security research and interoperability work on
          your own systems are fine.
        </p>
      </LegalSection>

      <LegalSection id="security-reports" number={6} title="Security Reports">
        <p>
          Found a vulnerability? Report it to{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>{" "}
          rather than filing a public issue, and give a reasonable window before
          disclosure. Reports are acknowledged as quickly as is practical for a
          project maintained by one person in their own time — no response-time
          guarantee is offered.
        </p>
      </LegalSection>

      <LegalSection id="changes" number={7} title="Changes and Continuity">
        <p>
          Features may change or disappear between releases, and the project may
          stop being maintained. You are not owed a migration path. The
          mitigation is structural rather than contractual: the source is MIT
          and public, so a working copy stays available to you regardless.
        </p>
        <p>
          These terms may be updated; the version published here, with the
          &quot;Last updated&quot; date at the top, is the current one.
        </p>
      </LegalSection>

      <LegalSection id="law" number={8} title="Applicable Law">
        <p>
          Swiss law applies, to the extent a dispute over freely licensed
          software with no consideration and no service can arise. Mandatory
          protections in your own country of residence are unaffected.
        </p>
      </LegalSection>

      <LegalSection id="contact" number={9} title="Contact">
        <p>
          Questions and notices:{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          . Bugs and feature discussion belong in the{" "}
          <a
            className="text-accent underline"
            href={GITHUB_URL}
            target="_blank"
            rel="noopener noreferrer"
          >
            repository
          </a>
          .
        </p>
      </LegalSection>
    </LegalShell>
  );
}
