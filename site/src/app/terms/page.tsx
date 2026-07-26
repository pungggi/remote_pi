import type { Metadata } from "next";
import { LegalShell, LegalSection } from "@/components/legal-shell";

export const metadata: Metadata = {
  title: "Terms of Service",
  description:
    "Terms of Service for Piper — provided by Flutterando Desenvolvimento de Programas de Computador LTDA.",
};

const CONTACT_EMAIL = "jacob@flutterando.com.br";

export default function TermsPage() {
  return (
    <LegalShell
      title="Terms of Service"
      lastUpdated="2026-05-22"
      subtitle={
        <p>
          Provider: <strong className="text-fg">Flutterando Desenvolvimento de Programas de Computador LTDA</strong>{" "}
          (CNPJ 33.637.582/0001-70). Address: Rua Clara Nunes, 198, Maringá/PR,
          CEP 87.045-650, Brazil.
        </p>
      }
    >
      <LegalSection id="acceptance" number={1} title="Acceptance of Terms">
        <p>
          By installing, accessing, or using the Piper mobile application,
          the Piper Pi-side extension, the Piper relay service, or any
          other software or service provided under the Piper name
          (collectively, the &quot;Service&quot;), you agree to be bound by
          these Terms of Service (&quot;Terms&quot;). If you do not agree to
          these Terms, you must not use the Service.
        </p>
        <p>
          These Terms form a binding agreement between you and Flutterando
          Desenvolvimento de Programas de Computador LTDA (&quot;Flutterando&quot;,
          &quot;we&quot;, &quot;us&quot;, or &quot;our&quot;).
        </p>
      </LegalSection>

      <LegalSection id="account-pairing" number={2} title="Account & Pairing">
        <p>
          Piper does not require you to create an account, register an email
          address, or provide personally identifiable information to use the
          Service. Instead, the Service uses an ephemeral, on-demand pairing
          flow: a QR code generated locally on the Pi-side extension is scanned
          by the mobile app, establishing a mutually authenticated channel
          between the two devices (Ed25519 challenge-response). See the
          Privacy Policy, section 9, for the full trust model — application-
          layer end-to-end encryption of payloads is on the roadmap, not yet
          active.
        </p>
        <p>
          Each pairing produces a cryptographic key pair stored locally on the
          phone and the Pi. Pairings can be revoked at any time from either
          device. You are responsible for keeping your devices secure; anyone
          with physical or remote access to a paired device can use that
          pairing.
        </p>
        <p>
          The Service is not directed at, and may not be used by, individuals
          under 13 years of age.
        </p>
      </LegalSection>

      <LegalSection id="features" number={3} title="Features">
        <p>The Service currently provides the following features:</p>
        <ul className="ml-6 list-disc space-y-2">
          <li>
            Remote control of a Pi-based coding agent (such as Claude Code,
            Codex, or similar) from a paired mobile device.
          </li>
          <li>
            A local multi-agent messaging mesh on the Pi (UDS broker) that lets
            multiple agents and the mobile peer exchange messages.
          </li>
          <li>
            An optional public relay service that forwards encrypted messages
            between paired devices when they are not on the same local network.
            You may instead self-host your own relay using the open-source
            relay code.
          </li>
        </ul>
        <p>
          Features may be added, modified, or removed at any time. We will make
          a reasonable effort to communicate breaking changes through the
          project README and this site.
        </p>
      </LegalSection>

      <LegalSection id="user-content" number={4} title="User-Generated Content">
        <p>
          The prompts you send to your Pi-side agent and the responses produced
          by that agent (&quot;User Content&quot;) belong to you. Flutterando
          does not log, persist, or inspect User Content.
        </p>
        <p>
          For full transparency about the current trust model: in the current
          MVP, message payloads travel base64-encoded over TLS between your
          devices and the relay. Application-layer end-to-end encryption is{" "}
          <strong className="text-fg">not</strong> active yet (it was removed
          for MVP stability and is on the roadmap). This means the operator of
          the relay you connect to could in principle access plaintext message
          contents while forwarding them. Users who require cryptographic
          confidentiality from the relay operator should self-host the relay
          (it is open source and the docs cover Docker + VPN deployment). See
          our Privacy Policy, section 9, for the full description.
        </p>
        <p>
          You are solely responsible for the User Content you send through the
          Service and for ensuring that you have the right to send and receive
          that content under applicable law and any third-party agreements
          (including the terms of any AI provider whose model the Pi-side agent
          uses).
        </p>
      </LegalSection>

      <LegalSection id="prohibited" number={5} title="Prohibited Conduct">
        <p>You must not:</p>
        <ul className="ml-6 list-disc space-y-2">
          <li>
            Attempt to break, bypass, or weaken the cryptographic
            authentication used by the Service (Ed25519 pairing, TLS to the
            relay), or attempt to impersonate another paired device.
          </li>
          <li>
            Attack, overload, or otherwise disrupt the relay infrastructure or
            any other component of the Service (denial-of-service, abusive
            connection patterns, etc.).
          </li>
          <li>
            Reverse-engineer the Service for the purpose of producing a
            confusingly similar product or circumventing security features
            (reverse engineering for interoperability or security research is
            permitted to the extent allowed by applicable law).
          </li>
          <li>
            Use the Service to commit, facilitate, or attempt unlawful acts, or
            to violate the rights of any third party.
          </li>
        </ul>
      </LegalSection>

      <LegalSection
        id="reporting"
        number={6}
        title="Reporting and Security Issues"
      >
        <p>
          Piper does not host or moderate user-to-user content (the relay is
          oblivious to message contents), so there is no general content
          moderation process. However, if you discover a security vulnerability
          in the Service or believe the Service is being abused to attack
          infrastructure or users, please report the issue to{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          . We will acknowledge security reports and respond as quickly as
          reasonably possible.
        </p>
      </LegalSection>

      <LegalSection
        id="ip"
        number={7}
        title="Platform Intellectual Property"
      >
        <p>
          The source code for Piper components is released under the MIT
          license and can be found in the project&apos;s public repository.
          Subject to that license, you may use, copy, modify, and distribute the
          source code.
        </p>
        <p>
          The Piper name, logo, and visual identity (including the π symbol
          mark, the color palette, and the wordmark) are trademarks and trade
          dress of Flutterando and are not granted to you by the MIT license.
          You may not use them in a way that suggests endorsement of, or
          affiliation with, a derivative product without prior written
          permission.
        </p>
      </LegalSection>

      <LegalSection
        id="availability"
        number={8}
        title="Availability and Service Modifications"
      >
        <p>
          The Service is provided on an &quot;as is&quot; and &quot;as
          available&quot; basis. We do not guarantee that the Service will be
          uninterrupted, error-free, or free from defects, and we may suspend,
          modify, or discontinue all or part of the Service at any time without
          prior notice.
        </p>
        <p>
          The public relay in particular is a free, best-effort service. If you
          require strong availability guarantees, you should self-host the
          relay.
        </p>
      </LegalSection>

      <LegalSection id="liability" number={9} title="Liability Limitation">
        <p>
          To the maximum extent permitted by applicable law, Flutterando shall
          not be liable for any indirect, incidental, special, consequential, or
          punitive damages, or for any loss of profits, revenue, data, use,
          goodwill, or other intangible losses, resulting from (i) your use of
          or inability to use the Service; (ii) any conduct or content of any
          third party in the Service; (iii) any unauthorized access to, use of,
          or alteration of your transmissions or content; or (iv) any other
          matter relating to the Service.
        </p>
        <p>
          Nothing in these Terms excludes or limits liability that cannot be
          excluded or limited under applicable law (including consumer
          protection rights under Brazilian law).
        </p>
      </LegalSection>

      <LegalSection
        id="modifications"
        number={10}
        title="Terms Modifications"
      >
        <p>
          We may update these Terms from time to time. The current version is
          always published on this site, with the &quot;Last updated&quot; date
          at the top. Material changes will additionally be announced in the
          project README. Your continued use of the Service after a change
          becomes effective constitutes acceptance of the new Terms.
        </p>
      </LegalSection>

      <LegalSection id="termination" number={11} title="Termination">
        <p>
          You may stop using the Service at any time. To terminate a specific
          pairing, revoke it from the mobile app or, on the Pi side, run{" "}
          <code className="rounded bg-surface px-1.5 py-0.5 font-mono text-xs text-fg">
            /remote-pi revoke &lt;id&gt;
          </code>
          . You may also uninstall the mobile application and the Pi-side
          extension to fully stop using the Service.
        </p>
        <p>
          We may suspend or terminate your access to the public relay if you
          violate these Terms or if your usage threatens the stability or
          security of the Service.
        </p>
      </LegalSection>

      <LegalSection id="law" number={12} title="Applicable Law">
        <p>
          These Terms are governed by the laws of the Federative Republic of
          Brazil. Any dispute arising out of or relating to these Terms or the
          Service shall be resolved exclusively in the courts of the district
          of Maringá, State of Paraná, Brazil, except where Brazilian consumer
          law mandates a different jurisdiction.
        </p>
      </LegalSection>

      <LegalSection id="contact" number={13} title="Contact">
        <p>
          Questions, notices, and requests under these Terms can be addressed
          to{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          , attention: Jacob Moura, Data Protection Officer, Flutterando
          Desenvolvimento de Programas de Computador LTDA.
        </p>
      </LegalSection>
    </LegalShell>
  );
}
