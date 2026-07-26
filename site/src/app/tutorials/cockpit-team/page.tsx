import type { Metadata } from "next";
import Link from "next/link";
import { DocsSection, InlineCode } from "@/components/docs-shell";
import { CodeBlock } from "@/components/code-block";
import { Callout } from "@/components/callout";
import { Pager } from "@/components/pager";
import { RevealController } from "@/components/landing/reveal-controller";

export const metadata: Metadata = {
  title: "An agent team in Cockpit",
  description:
    "Use Cockpit's multiplexer to run an orchestrator, a backend, and a frontend agent side by side — each in its own folder with its own AGENTS.md, coordinating over the remote-pi mesh.",
};

/* ---- example AGENTS.md files (one per folder) ---- */
const ORCHESTRATOR_MD = `# Orchestrator

You coordinate two teammates over the Piper mesh: \`backend\` and
\`frontend\`. You don't write app code yourself — you split the work,
delegate it, and integrate the results.

## How you work
- At the start of every turn, drain your inbox and read any replies.
- Break a request into one backend task and one frontend task.
- Delegate with agent_send to "backend" and "frontend".
- Collect their replies, reconcile mismatches (e.g. the API shape vs.
  what the UI needs), and report back to the user.

Keep each message small and explicit: say what you want and what
"done" looks like.`;

const BACKEND_MD = `# Backend

You own the server and API in this folder. On the Piper mesh you are
the peer named \`backend\`.

## How you work
- Check your inbox each turn — the \`orchestrator\` sends you tasks.
- Do the work here, in this folder, then reply to the sender (use the
  message id as \`re\`).
- If a task is ambiguous, reply asking for the missing detail instead of
  guessing.
- Keep the API contract (routes, payloads) explicit so \`frontend\` can
  build against it.`;

const FRONTEND_MD = `# Frontend

You own the UI in this folder. On the Piper mesh you are the peer
named \`frontend\`.

## How you work
- Check your inbox each turn — the \`orchestrator\` sends you tasks.
- Build against the contract \`backend\` exposes. If you need a route or
  field that doesn't exist yet, ask the orchestrator to coordinate it.
- When done, reply to the sender with what changed (use the message id
  as \`re\`).`;

export default function CockpitTeamTutorial() {
  return (
    <div className="page">
      <div className="page-body">
        <div className="wrap">
          <div className="tut">
            <header className="page-head reveal" style={{ maxWidth: "none" }}>
              <div className="flex flex-wrap items-center gap-3">
                <span className="inline-flex items-center rounded-full border border-accent/40 bg-accent/15 px-3 py-1 text-xs font-semibold uppercase tracking-[0.15em] text-accent">
                  Cockpit · multi-agent
                </span>
              </div>
              <span className="eyebrow" style={{ marginTop: 14 }}>
                Tutorial · Cockpit
              </span>
              <h1>An agent team in Cockpit</h1>
              <p className="lede">
                Cockpit&apos;s real power is the multiplexer: many agents in one
                window, each in its own folder. Here you&apos;ll wire up three —
                an <strong className="text-fg">orchestrator</strong>, a{" "}
                <strong className="text-fg">backend</strong>, and a{" "}
                <strong className="text-fg">frontend</strong> — each with its own{" "}
                <InlineCode>AGENTS.md</InlineCode>, all talking to each other over
                the <InlineCode>remote-pi</InlineCode> mesh.
              </p>
            </header>

            <article className="prose">
              <DocsSection id="what" title="What you'll build">
                <p>
                  Three Pi agents, side by side as panes in a single Cockpit
                  workspace. Each lives in its own subfolder and reads that
                  folder&apos;s <InlineCode>AGENTS.md</InlineCode> as its standing
                  brief, so each one boots into a role. They coordinate by sending
                  each other messages on the local mesh — the orchestrator splits
                  a request, hands tasks to the backend and frontend, and stitches
                  their replies back together.
                </p>
                <p>
                  Nothing here leaves your machine: the mesh runs over a local
                  socket, and all three agents work on your real files.
                </p>
                <Callout variant="note" title="Two pieces you already know">
                  This builds on{" "}
                  <Link
                    href="/tutorials/getting-started"
                    className="text-accent underline"
                  >
                    Getting started
                  </Link>{" "}
                  (install Pi + the <InlineCode>remote-pi</InlineCode> extension)
                  and{" "}
                  <Link
                    href="/tutorials/mesh-local"
                    className="text-accent underline"
                  >
                    Local mesh
                  </Link>{" "}
                  (how two agents trade messages). Skim those first if the mesh
                  tools are new to you.
                </Callout>
              </DocsSection>

              <DocsSection id="prereqs" title="Before you start">
                <ul className="ml-6 list-disc space-y-2">
                  <li>
                    <strong className="text-fg">Cockpit installed</strong> — grab
                    it from the{" "}
                    <Link href="/cockpit" className="text-accent underline">
                      Cockpit page
                    </Link>
                    . On first launch its onboarding checks for{" "}
                    <InlineCode>pi</InlineCode>, the{" "}
                    <InlineCode>remote-pi</InlineCode> extension, and the
                    supervisor, and helps you install anything missing.
                  </li>
                  <li>
                    The <InlineCode>remote-pi</InlineCode> extension is what hands
                    every agent the mesh tools, so make sure onboarding is green
                    before you build the team.
                  </li>
                </ul>
              </DocsSection>

              <DocsSection id="folders" title="1. Lay out the folders">
                <p>
                  An agent&apos;s identity comes from its folder, so give each
                  teammate one. In your project, create three subfolders, each
                  with its own <InlineCode>AGENTS.md</InlineCode>:
                </p>
                <CodeBlock
                  code={`my-app/
├── orchestrator/
│   └── AGENTS.md
├── backend/
│   └── AGENTS.md
└── frontend/
    └── AGENTS.md`}
                  label="project layout"
                  language="text"
                />
                <p>
                  <InlineCode>AGENTS.md</InlineCode> is the brief Pi reads when it
                  starts in a folder — the agent&apos;s role and house rules. Give
                  each one a clear job and tell it how to behave on the mesh.
                </p>
                <CodeBlock
                  code={ORCHESTRATOR_MD}
                  label="orchestrator/AGENTS.md"
                  language="markdown"
                />
                <CodeBlock
                  code={BACKEND_MD}
                  label="backend/AGENTS.md"
                  language="markdown"
                />
                <CodeBlock
                  code={FRONTEND_MD}
                  label="frontend/AGENTS.md"
                  language="markdown"
                />
                <Callout variant="note" title="One agent per folder">
                  Pi allows exactly one agent per directory — which is precisely
                  why each teammate gets its own subfolder. Three folders, three
                  agents, three distinct peers on the mesh.
                </Callout>
              </DocsSection>

              <DocsSection id="panes" title="2. Open the three panes">
                <p>
                  In Cockpit, open <InlineCode>my-app/</InlineCode> as a workspace.
                  The file tree on the right shows your three subfolders. For each
                  one, <strong className="text-fg">right-click the folder</strong>{" "}
                  and create an agent there — Cockpit roots that agent in the
                  subfolder, so it picks up the right{" "}
                  <InlineCode>AGENTS.md</InlineCode>.
                </p>
                <p>
                  Split the canvas so all three are visible at once — orchestrator
                  on one side, backend and frontend on the other — and drag the
                  dividers to taste. One agent streaming a long answer never
                  freezes the others, and the whole layout comes back exactly like
                  this the next time you open the app.
                </p>
                <Callout variant="tip" title="Name them to match">
                  When an agent asks for a name (or in its{" "}
                  <InlineCode>/remote-pi</InlineCode> wizard), use{" "}
                  <InlineCode>orchestrator</InlineCode>,{" "}
                  <InlineCode>backend</InlineCode>, and{" "}
                  <InlineCode>frontend</InlineCode>. Those are the names teammates
                  address in <InlineCode>agent_send</InlineCode>, so matching them
                  to the folders keeps the prompts readable.
                </Callout>
              </DocsSection>

              <DocsSection id="mesh" title="3. Put them on the mesh">
                <p>
                  Agents meet in a shared session named{" "}
                  <InlineCode>local</InlineCode>, over a Unix socket — no network.
                  Join each agent the same way as in the terminal: in each
                  pane&apos;s composer, run the slash command once.
                </p>
                <CodeBlock
                  code="/remote-pi"
                  label="each pane · composer"
                  language="text"
                />
                <p>
                  The first run is a quick wizard (name + relay); accept the folder
                  name so the peer is called{" "}
                  <InlineCode>orchestrator</InlineCode>,{" "}
                  <InlineCode>backend</InlineCode>, or{" "}
                  <InlineCode>frontend</InlineCode>. Then confirm everyone is home —
                  ask the orchestrator:
                </p>
                <CodeBlock
                  code="List the other agents on the mesh."
                  label="orchestrator · prompt"
                  language="text"
                />
                <CodeBlock
                  code={`list_peers()
→ backend
  frontend`}
                  label="orchestrator · tool call"
                  language="text"
                />
                <p>
                  If a teammate is missing from the roster, run{" "}
                  <InlineCode>/remote-pi</InlineCode> in its pane and check again.
                </p>
              </DocsSection>

              <DocsSection id="run" title="4. Run the orchestration">
                <p>
                  Now give the orchestrator something real and let it delegate.
                  You only talk to the orchestrator — it talks to the others.
                </p>
                <CodeBlock
                  code={`Add a "todos" feature: an API to list and create todos, and a page
that shows them with a form to add one. Coordinate backend and frontend.`}
                  label="orchestrator · prompt"
                  language="text"
                />
                <p>
                  It breaks the work in two and sends a task to each peer. A send
                  returns an ACK, not an answer — it&apos;s fire-and-ACK, not a
                  blocking call.
                </p>
                <CodeBlock
                  code={`agent_send({
  to: "backend",
  body: { task: "Expose GET /todos and POST /todos (title:string). Return the JSON shape." }
})
→ Delivered to backend

agent_send({
  to: "frontend",
  body: { task: "Build a Todos page: list todos and a form to add one, against backend's API." }
})
→ Delivered to frontend`}
                  label="orchestrator · tool calls"
                  language="text"
                />
                <p>
                  On its next turn, <InlineCode>backend</InlineCode> sees the task,
                  does the work <em>in its own folder</em>, and replies — quoting
                  the message id in <InlineCode>re</InlineCode> so the orchestrator
                  knows which task it answers:
                </p>
                <CodeBlock
                  code={`get_messages()
→ [..] from=orchestrator id=7f3a91 { "task": "Expose GET /todos and POST /todos ..." }

# ...writes the routes here, in backend/ ...

agent_send({
  to: "orchestrator",
  body: { done: "Added GET/POST /todos", api: { todo: { id: "string", title: "string", done: "bool" } } },
  re: "7f3a91"
})
→ Delivered to orchestrator`}
                  label="backend · tool calls"
                  language="text"
                />
                <p>
                  <InlineCode>frontend</InlineCode> does the same in its folder.
                  Back in the orchestrator, both replies arrive on its next turns;
                  it reconciles them — for instance, forwarding the exact API shape
                  to the frontend if it asked — and reports the finished feature
                  back to you. Three agents, three folders, one coordinated change.
                </p>
                <Callout variant="note" title="If a reply never comes">
                  An <InlineCode>agent_send</InlineCode> to a peer that&apos;s
                  mid-turn can come back <InlineCode>busy</InlineCode> — the
                  message was dropped, so retry shortly. The full set of ACKs
                  (<InlineCode>Delivered</InlineCode>, <InlineCode>busy</InlineCode>
                  , <InlineCode>denied</InlineCode>, timeout) is covered in{" "}
                  <Link
                    href="/tutorials/mesh-local"
                    className="text-accent underline"
                  >
                    Local mesh
                  </Link>
                  .
                </Callout>
              </DocsSection>

              <DocsSection id="why" title="Why do this in Cockpit">
                <p>
                  You could run three terminals — but in Cockpit the whole team
                  lives in one window. Every agent streams its own work in its own
                  pane, you watch the orchestrator hand off and the others pick up
                  in real time, and the layout (and each session&apos;s history)
                  comes back when you reopen the app. Add a real terminal pane to
                  run the servers, and the build, the agents, and their
                  conversation are all in front of you at once.
                </p>
                <p>
                  From here: promote the orchestrator to a{" "}
                  <Link href="/tutorials/daemon" className="text-accent underline">
                    24/7 daemon
                  </Link>{" "}
                  so the team keeps coordinating in the background, or read{" "}
                  <Link
                    href="/tutorials/mesh-remote"
                    className="text-accent underline"
                  >
                    Remote mesh
                  </Link>{" "}
                  to add a teammate running on a different machine.
                </p>
              </DocsSection>
            </article>

            <Pager
              prev={{ href: "/tutorials/mesh-local", label: "Local mesh" }}
              next={{ href: "/cockpit", label: "Meet Cockpit" }}
            />
          </div>
        </div>
      </div>
      <RevealController />
    </div>
  );
}
