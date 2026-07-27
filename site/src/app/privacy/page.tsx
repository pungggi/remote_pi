import type { Metadata } from "next";
import Link from "next/link";
import { LegalShell, LegalSection } from "@/components/legal-shell";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "Privacy Policy for Piper — open-source software with no service behind it. Nobody operates a relay, and there is no account to create.",
};

const CONTACT_EMAIL = "contact@pungitore.ch";

export default function PrivacyPage() {
  return (
    <LegalShell
      title="Privacy Policy"
      lastUpdated="2026-07-26"
      subtitle={
        <p>
          Piper is <strong className="text-fg">software, not a service</strong>.
          There is no company behind it, no account to create, and no relay
          anyone operates on your behalf. Questions:{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          .
        </p>
      }
    >
      <LegalSection id="who" number={1} title="Who We Are">
        <p>
          Piper is an open-source project maintained by an individual in
          Switzerland. It is not a company, and it does not operate any hosted
          service — no relay, no backend, no accounts, no sync, no telemetry.
        </p>
        <p>
          For anything related to this Policy, write to{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          .
        </p>
      </LegalSection>

      <LegalSection id="model" number={2} title="Why This Policy Is Short">
        <p>
          Most privacy policies are long because the software phones home to
          servers the vendor runs. Piper has no such servers. The pieces are:
          an app on your phone, an extension on your machine, and a relay
          process that <strong className="text-fg">you</strong> start on your
          own hardware. They talk to each other; none of them talk to us.
        </p>
        <p>
          That means for the parts that actually process your data, you are the
          operator — see §5.
        </p>
      </LegalSection>

      <LegalSection id="website" number={3} title="This Website">
        <p>
          This site is a set of static pages. It sets no cookies, embeds no
          analytics, no advertising trackers, no social widgets, and no
          third-party fonts or scripts.
        </p>
        <p>
          As with any website, the server delivering these pages may write
          ordinary access logs (IP address, timestamp, requested path, user
          agent) as part of normal operation and security. Those logs are not
          used for profiling, are not combined with anything else, and are not
          shared.
        </p>
      </LegalSection>

      <LegalSection id="apps" number={4} title="The App and the Extension">
        <p>
          Data stays on the device that produced it. Specifically:
        </p>
        <ul className="ml-6 list-disc space-y-2">
          <li>
            <strong className="text-fg">Keys are generated on-device</strong>{" "}
            during pairing and stored in the platform&apos;s secure storage
            (Android Keystore on the phone; the system keyring — Credential
            Manager, Keychain, or libsecret — on the machine). Private keys
            never leave the device that made them.
          </li>
          <li>
            <strong className="text-fg">Paired peers</strong> — public keys, a
            name you choose, and the relay address — are stored locally so the
            app knows what it is talking to.
          </li>
          <li>
            <strong className="text-fg">Your prompts and the agent&apos;s
            replies</strong> travel between your phone and your machine. They
            are not collected, not uploaded anywhere by Piper, and not visible
            to the maintainer.
          </li>
        </ul>
        <p>
          Uninstalling removes this local state. There is no server-side copy to
          delete, because there is no server.
        </p>
      </LegalSection>

      <LegalSection id="your-relay" number={5} title="The Relay Is Yours">
        <p>
          Piper operates <strong className="text-fg">no public relay</strong>{" "}
          and ships no default pointing at anyone else&apos;s. The relay is a
          process you run — typically on the same machine as your coding agent.
        </p>
        <p>
          Be aware what that process sees. Message payloads are{" "}
          <strong className="text-fg">
            not end-to-end encrypted at the application layer
          </strong>
          , so whoever runs the relay could in principle read plaintext in
          memory while forwarding, along with connection metadata and signed
          mesh-membership blobs. That is precisely why there is no shared
          instance: the operator is you, on your hardware, and no third party
          is placed in that position by default.
        </p>
        <p>
          If you point Piper at a relay somebody else runs, that operator
          becomes responsible for the data they process, and this Policy does
          not cover them. To reach your own relay from outside your Wi-Fi
          without exposing it, put both ends on an overlay network — see the{" "}
          <Link href="/docs#self-host" className="text-accent underline">
            relay documentation
          </Link>
          .
        </p>
      </LegalSection>

      <LegalSection id="third-parties" number={6} title="Third Parties You Connect">
        <p>
          Piper drives a coding agent that you configure. When that agent calls
          a model provider, your prompts go to that provider under{" "}
          <em>their</em> terms and privacy policy, not this one. The same
          applies to any overlay-network provider you choose (for example
          Tailscale) and to wherever you downloaded the app from.
        </p>
        <p>
          Piper adds no analytics, crash reporting, or attribution SDK of its
          own.
        </p>
      </LegalSection>

      <LegalSection id="rights" number={7} title="Your Rights">
        <p>
          Swiss data-protection law (revFADP) and, where it applies, the GDPR
          give you rights of access, correction, deletion, objection, and
          portability over personal data a controller holds about you.
        </p>
        <p>
          In practice there is very little to exercise them against here: no
          account exists, and the data described in §4 sits on your own devices
          under your own control. If you believe personal data of yours is held
          in connection with this project, write to{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>{" "}
          and it will be addressed. You may also lodge a complaint with the
          Swiss Federal Data Protection and Information Commissioner (FDPIC).
        </p>
      </LegalSection>

      <LegalSection id="security" number={8} title="Security">
        <p>Within the software itself:</p>
        <ul className="ml-6 list-disc space-y-2">
          <li>
            <strong className="text-fg">Ed25519 challenge-response</strong> at
            pairing, so paired devices verify each other cryptographically.
          </li>
          <li>
            Private keys generated on-device and held in platform secure
            storage; they never leave the device.
          </li>
          <li>
            Transport encryption on the connection to the relay when the relay
            is served over TLS or reached across an encrypted overlay network.
          </li>
        </ul>
        <p>
          <strong className="text-fg">
            Application-layer end-to-end encryption of message payloads is not
            active.
          </strong>{" "}
          Read §5 before deciding what to send. No system is perfectly secure;
          if you think a device has been compromised, revoke its pairing
          immediately and report the issue to{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          .
        </p>
      </LegalSection>

      <LegalSection id="minors" number={9} title="Children">
        <p>
          Piper is a developer tool and is not directed at children. No personal
          data is knowingly collected from anyone, minors included.
        </p>
      </LegalSection>

      <LegalSection id="updates" number={10} title="Policy Updates">
        <p>
          This Policy may change as the software changes. The current version is
          always the one published here, with the &quot;Last updated&quot; date
          at the top, and its history is in the project&apos;s public
          repository.
        </p>
      </LegalSection>

      <LegalSection id="contact" number={11} title="Contact">
        <p>
          For any privacy question or request:{" "}
          <a className="text-accent underline" href={`mailto:${CONTACT_EMAIL}`}>
            {CONTACT_EMAIL}
          </a>
          .
        </p>
      </LegalSection>
    </LegalShell>
  );
}
