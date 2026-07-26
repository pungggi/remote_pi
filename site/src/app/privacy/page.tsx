import type { Metadata } from "next";
import { LegalShell, LegalSection } from "@/components/legal-shell";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "Privacy Policy for Piper — what little data we touch, why we touch it, and your LGPD rights.",
};

const CONTACT_EMAIL = "jacob@flutterando.com.br";

export default function PrivacyPage() {
  return (
    <LegalShell
      title="Privacy Policy"
      lastUpdated="2026-05-22"
      subtitle={
        <p>
          Data controller:{" "}
          <strong className="text-fg">
            Flutterando Desenvolvimento de Programas de Computador LTDA
          </strong>{" "}
          (CNPJ 33.637.582/0001-70). Data Protection Officer (DPO):{" "}
          <strong className="text-fg">Jacob Moura</strong> —{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          .
        </p>
      }
    >
      <LegalSection id="who" number={1} title="Who We Are (Data Controller)">
        <p>
          Piper is operated by Flutterando Desenvolvimento de Programas de
          Computador LTDA, a company incorporated in Brazil (CNPJ
          33.637.582/0001-70), with offices at Rua Clara Nunes, 198, Maringá/PR,
          CEP 87.045-650.
        </p>
        <p>
          For any matter related to this Policy or to the processing of your
          personal data, you may contact our Data Protection Officer, Jacob
          Moura, at{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          .
        </p>
      </LegalSection>

      <LegalSection id="collect" number={2} title="Data We Collect">
        <h3 className="text-base font-semibold text-fg">
          2.1 Data you provide directly
        </h3>
        <p>
          Piper is designed so that you provide essentially nothing to us on
          the relay path. There is no account, no email registration, no
          profile, and no payment information. The pairing flow generates
          cryptographic keys locally on your devices.
        </p>
        <p>
          On the device itself, the mobile app stores a list of paired peers
          (their public keys, a friendly name you choose, and the relay URL) in
          the platform&apos;s secure storage (iOS Keychain / Android Keystore).
          This information never leaves your device unless you explicitly send
          it.
        </p>
        <h3 className="text-base font-semibold text-fg">
          2.2 Data processed automatically by the public relay
        </h3>
        <p>
          When you connect to the public relay operated by Flutterando, the
          relay processes three categories of data:
        </p>
        <ul className="ml-6 list-disc space-y-2">
          <li>
            <strong className="text-fg">Connection metadata</strong> — source
            IP address, connection timestamps, public-key identifier of the
            connecting peer, room identifiers, and basic transport statistics
            (bytes in/out, message timing and sizes). This is{" "}
            <strong className="text-fg">logged</strong> for at most 30 days and
            used for abuse mitigation and reliable operation of the relay.
          </li>
          <li>
            <strong className="text-fg">Message payloads</strong> forwarded
            between paired peers. In the current MVP, payloads travel
            base64-encoded over TLS and{" "}
            <strong className="text-fg">
              are not end-to-end encrypted at the application layer
            </strong>
            . The relay operator could in principle access plaintext message
            contents in memory while forwarding. We do{" "}
            <strong className="text-fg">not log, persist, or inspect</strong>{" "}
            those payloads — we forward them and discard them. See §9 for the
            full trust model.
          </li>
          <li>
            <strong className="text-fg">Signed mesh-membership blobs.</strong>{" "}
            When you pair a new machine, your Owner key signs a small JSON
            blob listing which Pi devices belong to that Owner&apos;s mesh,
            and your app uploads it to the relay via{" "}
            <code className="rounded bg-surface px-1 py-0.5 font-mono text-xs text-fg">
              POST /mesh/&lt;owner_pk_hash&gt;
            </code>
            . The relay verifies the Ed25519 signature and persists the blob
            (a few KB per Owner) so that new devices restoring the same Owner
            key can recover their peer list. The blob contains: Owner public
            key, a version number, the list of Pi public keys you have
            paired, and a timestamp. It is{" "}
            <strong className="text-fg">not encrypted</strong> — anyone with
            access to the relay database can read it. Pairing on your own
            self-hosted relay keeps this data on your infrastructure.
          </li>
        </ul>
        <p>
          If you require cryptographic confidentiality from the relay operator,
          self-host the relay (the code is open source and documented). When
          you self-host, the data described in §2.2 is processed by your own
          infrastructure, not by Flutterando.
        </p>
        <h3 className="text-base font-semibold text-fg">
          2.3 Data we do NOT collect
        </h3>
        <ul className="ml-6 list-disc space-y-2">
          <li>Precise device location.</li>
          <li>Contacts, photos, microphone, or camera content.</li>
          <li>The text of your prompts or the responses produced by your Pi-side agent.</li>
          <li>Advertising identifiers (IDFA, AAID).</li>
          <li>Behavioral analytics or tracking telemetry.</li>
        </ul>
      </LegalSection>

      <LegalSection id="use" number={3} title="How We Use Your Data">
        <p>The limited connection metadata described in §2.2 is used to:</p>
        <ul className="ml-6 list-disc space-y-2">
          <li>Operate, maintain, and route traffic on the relay service.</li>
          <li>
            Detect and mitigate abuse, such as denial-of-service attacks or
            patterns of unauthorized access attempts.
          </li>
          <li>
            Investigate incidents and protect the security of the Service and
            its users.
          </li>
        </ul>
        <p>
          We do not use any data for advertising, profiling, or behavioral
          analytics.
        </p>
      </LegalSection>

      <LegalSection
        id="legal-bases"
        number={4}
        title="Legal Bases (LGPD Article 7)"
      >
        <p>
          Under the Brazilian General Data Protection Law (Lei Geral de Proteção
          de Dados, Law 13.709/2018, &quot;LGPD&quot;), we process the limited
          data described above on the following legal bases:
        </p>
        <ul className="ml-6 list-disc space-y-2">
          <li>
            <strong className="text-fg">Performance of a contract</strong>{" "}
            (Article 7, V) — to provide the relay service you connect to.
          </li>
          <li>
            <strong className="text-fg">Legitimate interest</strong> (Article 7,
            IX) — to ensure the security and integrity of the relay
            infrastructure.
          </li>
        </ul>
      </LegalSection>

      <LegalSection id="sharing" number={5} title="Data Sharing">
        <p>
          We do not sell or rent your data. We do not share connection metadata
          with third parties for advertising or analytics purposes. We may
          disclose data only when required to do so by a valid legal order
          under Brazilian law, and only to the extent strictly necessary to
          comply with that order.
        </p>
        <p>
          If you choose to self-host your own relay or connect to a relay
          operated by a third party, that operator becomes the data controller
          for the connection metadata they process. This Policy does not cover
          third-party relays.
        </p>
      </LegalSection>

      <LegalSection
        id="international"
        number={6}
        title="International Transfer"
      >
        <p>
          The public relay operated by Flutterando may be hosted in data centers
          located outside Brazil. Where this is the case, transfers occur under
          conditions equivalent to those required by Article 33 of the LGPD,
          including contractual safeguards with infrastructure providers. You
          can avoid international transfer entirely by running your own relay
          on infrastructure under your control.
        </p>
      </LegalSection>

      <LegalSection id="retention" number={7} title="Data Retention">
        <p>
          Relay connection logs are retained for a maximum of{" "}
          <strong className="text-fg">30 days</strong>, after which they are
          deleted or anonymized. Aggregated, non-identifying statistics (e.g.
          daily active connection counts) may be retained longer for capacity
          planning.
        </p>
        <p>
          Paired peers stored on your device persist until you revoke the
          pairing or uninstall the app. We do not have access to that storage.
        </p>
      </LegalSection>

      <LegalSection
        id="rights"
        number={8}
        title="Your Rights (LGPD Article 18)"
      >
        <p>
          Subject to the LGPD, you have the right to request, with respect to
          personal data we hold about you:
        </p>
        <ul className="ml-6 list-disc space-y-2">
          <li>Confirmation that we process your data.</li>
          <li>Access to that data.</li>
          <li>Correction of incomplete, inaccurate, or outdated data.</li>
          <li>
            Anonymization, blocking, or deletion of unnecessary or excessive
            data, or data processed in non-compliance with the LGPD.
          </li>
          <li>
            Information about public and private entities with which we have
            shared your data.
          </li>
          <li>
            Information about the possibility of not providing consent, and the
            consequences of refusal.
          </li>
          <li>Revocation of consent, where consent was the legal basis.</li>
        </ul>
        <p>
          To exercise any of these rights, contact our DPO at{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          . We may need to verify your identity (for example, by asking you to
          prove control of a paired device&apos;s public key) before fulfilling
          the request.
        </p>
      </LegalSection>

      <LegalSection id="security" number={9} title="Security and trust model">
        <p>We use the following safeguards:</p>
        <ul className="ml-6 list-disc space-y-2">
          <li>
            <strong className="text-fg">TLS 1.3</strong> on every connection
            between clients and the relay.
          </li>
          <li>
            <strong className="text-fg">Ed25519 challenge-response</strong> at
            pairing time, so paired devices verify each other&apos;s identity
            cryptographically and identity squatting is prevented.
          </li>
          <li>
            Private keys generated on-device and stored in the platform secure
            storage (iOS Keychain / Android Keystore). Private keys never leave
            your devices.
          </li>
          <li>
            Operational separation between transport metadata and any other
            system, with strict access controls on relay logs.
          </li>
        </ul>
        <p>
          <strong className="text-fg">
            Important — read this if confidentiality matters to you.
          </strong>{" "}
          Application-layer{" "}
          <strong className="text-fg">end-to-end encryption of message payloads is not active in the current MVP</strong>.
          Payloads travel base64-encoded over TLS to the relay and from the
          relay to the paired device. The public relay operator (Flutterando)
          could in principle access plaintext message contents in memory while
          forwarding, but we do{" "}
          <strong className="text-fg">not log, persist, or inspect</strong>{" "}
          payloads. Per-message end-to-end encryption was removed for MVP
          stability and is on the roadmap for a future release.
        </p>
        <p>
          If you require cryptographic confidentiality from the relay operator,{" "}
          <strong className="text-fg">run your own relay</strong>. The relay is
          open source and the documentation covers Docker deployment and VPN
          gating (Tailscale, WireGuard) so that only your devices can reach the
          relay&apos;s WebSocket port at all.
        </p>
        <p>
          No system is perfectly secure. If you believe your account or device
          has been compromised, revoke the affected pairing immediately and
          report the incident to{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          .
        </p>
      </LegalSection>

      <LegalSection id="minors" number={10} title="Children and Minors">
        <p>
          The Service is not directed at, and is not intended for use by,
          individuals under the age of 13. We do not knowingly collect personal
          data from minors. If we become aware that we have collected personal
          data from a minor under 13, we will delete that data promptly.
        </p>
      </LegalSection>

      <LegalSection id="cookies" number={11} title="Cookies">
        <p>
          This site does not use tracking, advertising, or analytics cookies.
          The mobile application and the Pi-side extension do not use cookies
          either. We may use strictly functional cookies on this site only if
          needed for security (for example, CSRF protection on a future
          contact form); none are used today.
        </p>
      </LegalSection>

      <LegalSection id="updates" number={12} title="Policy Updates">
        <p>
          We may update this Policy from time to time. The current version is
          always published on this site, with the &quot;Last updated&quot; date
          at the top. Material changes will additionally be announced in the
          project README.
        </p>
      </LegalSection>

      <LegalSection id="contact" number={13} title="Contact">
        <p>
          For questions, requests under the LGPD, or any other privacy matter,
          contact our DPO, Jacob Moura, at{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          .
        </p>
        <p>
          You also have the right to lodge a complaint with the Brazilian
          National Data Protection Authority (Autoridade Nacional de Proteção
          de Dados — ANPD).
        </p>
      </LegalSection>
    </LegalShell>
  );
}
