import type { Socket } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import {
  type Envelope,
  type TransportErrorReason,
  asTransportErrorBody,
  envelope,
  hasTransportErrorType,
  parse,
  serialize,
  EnvelopeError,
} from "./envelope.js";
import {
  joinOrLead,
  socketIdentity,
  type ElectionResult,
  type SocketIdentity,
} from "./leader_election.js";
import { Broker } from "./broker.js";
import { CROSS_PC_DENIED_GRACE_MS } from "./ack_policy.js";
import { usesNamedPipe } from "./ipc.js";
import { describeRegistrationBlocker, describeSocketOwner } from "./socket_owner.js";

export { CROSS_PC_DENIED_GRACE_MS } from "./ack_policy.js";

/**
 * Symmetric peer-in-session API. Hides whether you are leader or follower;
 * `send`, `request`, `onMessage`, `rename`, `leave` all work the same.
 *
 * Pending map demuxes parallel `request()` calls by message `id` → `re`.
 *
 * Failover: when the leader dies, follower socket emits `close`. Remaining
 * peers re-run `joinOrLead`. One becomes the new leader; others reconnect.
 */
export type MessageHandler = (env: Envelope) => void;
export type ReconnectHandler = () => void;

export interface SessionPeerOptions {
  sockPath: string;
  name: string;
  /**
   * Working directory of this agent. Sent in the `register` so the broker can
   * key peers by the (cwd, name) pair: two agents in the SAME folder with the
   * same name are the SAME logical agent reincarnating (switch_session /
   * restart), so the broker take-over the name instead of suffixing `#N`.
   * Optional for backward-compat with peers that predate this field.
   */
  cwd?: string;
  /** Replace an existing same-(cwd,name) registration instead of accepting a
   *  broker-assigned `#N`. Use only for stable logical identities; ordinary
   *  multi-agent sessions should leave this false. */
  takeoverExisting?: boolean;
  auditPath?: string;
  /** Per-request default timeout (ms). Override per call if needed. */
  defaultTimeoutMs?: number;
  /** How often a leader verifies that its socket path still leads to its own
    broker, in ms (issue #140). Default `LEADER_PATH_CHECK_INTERVAL_MS`; 0
   * disables the check. */
  leaderPathCheckIntervalMs?: number;
}

const DEFAULT_TIMEOUT_MS = 30_000;
const ACK_TIMEOUT_MS = 5_000;
const FAILOVER_RETRY_MS = 100;

/** How often a leader checks that its socket path still leads to its own
 *  broker (issue #140). Zero disables the check. The timing of a cross-PC
 *  refusal lives in `ack_policy.ts`, next to the tool text that quotes it. */
export const LEADER_PATH_CHECK_INTERVAL_MS = 5_000;

export type AckStatus = "received" | "busy" | "denied" | "timeout";

/** One broker's answer to a cross-PC send. `pid` is the answering process. */
export interface AckAnswer {
  status: Exclude<AckStatus, "timeout">;
  pid?: number;
}

export interface AckResult {
  status: AckStatus;
  /** The original envelope id that was awaiting ACK. */
  id: string;
  /** Target name reported by broker (when ACK arrived). Undefined on timeout. */
  target?: string;
  error?: `transport_error: ${TransportErrorReason}`;
  reason?: TransportErrorReason;
  /** Every broker answer behind a cross-PC `denied` (issue #140): who said
 *  it, so the tool text and the session log can name them. */
  answers?: ReadonlyArray<AckAnswer>;
}

export class MeshTransportError extends Error {
  constructor(
    readonly reason: TransportErrorReason,
    readonly correlationId: string,
  ) {
    super(`transport_error: ${reason}`);
    this.name = "MeshTransportError";
  }
}

interface AckBody {
  type: "ack";
  status: "received" | "busy" | "denied";
  target: string;
  /** Process of the broker that answered (cross-PC bridges set it). */
  pid?: number;
}

/** What the register handshake tells a joining peer. `foreign` is set when a
 *  leader heard another broker than its own answer (issue #140). */
interface Registration {
  name: string;
  foreign: boolean;
}

/** One send awaiting its ACK. */
interface AckSlot {
  expectedFrom: string;
  resolve: (result: AckResult) => void;
  timer: ReturnType<typeof setTimeout>;
  /** Cross-PC `denied` answers seen so far (issue #140). */
  denials: AckAnswer[];
  /** Running while a first `denied` waits out `CROSS_PC_DENIED_GRACE_MS`. */
  graceTimer: ReturnType<typeof setTimeout> | null;
}

function hasExactAckType(body: unknown): body is { type: "ack" } {
  return typeof body === "object"
    && body !== null
    && Object.prototype.hasOwnProperty.call(body, "type")
    && (body as { type: unknown }).type === "ack";
}

function expectedAckSender(destination: string): string {
  // Local absolute paths may contain colons; only non-path aliases are remote.
  if (
    destination === "" ||
    !destination.includes(":") ||
    destination.startsWith("/") ||
    /^[A-Za-z]:[\\/]/.test(destination) ||
    destination.startsWith("\\\\")
  ) {
    return "broker";
  }
  const remote = /^([^:]+):.+$/.exec(destination);
  return remote ? `${remote[1]}:broker` : "broker";
}

function asAckBody(body: unknown): AckBody | null {
  if (!hasExactAckType(body)
    || !Object.prototype.hasOwnProperty.call(body, "status")
    || !Object.prototype.hasOwnProperty.call(body, "target")) {
    return null;
  }

  const { status, target, pid } = body as {
    type: "ack";
    status: unknown;
    target: unknown;
    pid?: unknown;
  };
  if ((status !== "received" && status !== "busy" && status !== "denied")
    || typeof target !== "string") {
    return null;
  }

  return {
    type: "ack",
    status,
    target,
    ...(typeof pid === "number" && Number.isInteger(pid) && pid > 0 ? { pid } : {}),
  };
}

export class SessionPeer {
  private readonly opts: SessionPeerOptions;
  /** Clean leaf name actually assigned by the broker (may carry a `#N`
   *  collision suffix). Used for display + self-filtering. */
  private assignedName: string;
  /** Canonical address assigned by the broker (`[<pc>:]<cwd>@<nome>`, or just
   *  the name for a legacy broker). This is the routing/identity key the mesh
   *  uses; callers ECHO it, never compose it. */
  private assignedAddress: string;
  private role: "leader" | "follower" = "follower";
  private broker: Broker | null = null;
  private socket: Socket | null = null;
  private buf = "";
  /** Map of in-flight request ids → resolver. Used by `request()`. */
  private readonly pending = new Map<string, {
    resolve: (env: Envelope) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }>();
  /** Map of in-flight send ids → ACK resolver. Used by `sendWithAck()`. */
  private readonly ackPending = new Map<string, AckSlot>();
  private readonly handlers = new Set<MessageHandler>();
  private readonly reconnectHandlers = new Set<ReconnectHandler>();
  private leftFlag = false;
  /** The leader's own socket file (issue #140), null while following. */
  private ownSockIdentity: SocketIdentity | null = null;
  private leaderPathCheck: ReturnType<typeof setInterval> | null = null;
  /** A stand-down in progress; `leave` and `rename` wait for it. */
  private stepDownInFlight: Promise<void> | null = null;

  constructor(opts: SessionPeerOptions) {
    this.opts = opts;
    this.assignedName = opts.name;
    this.assignedAddress = opts.name;
  }

  // ── public API ────────────────────────────────────────────────────────────

  /** Joins or leads the session at `sockPath`. Resolves with the assigned name. */
  async start(): Promise<string> {
    return this._joinOrLead();
  }

  /** Returns the clean leaf name as assigned by the broker (after any `#N`). */
  name(): string {
    return this.assignedName;
  }

  /** Returns the canonical address (`[<pc>:]<cwd>@<nome>`) assigned by the
   *  broker — the key the mesh routes on. Equals `name()` against a legacy
   *  broker that returns no address. */
  address(): string {
    return this.assignedAddress;
  }

  /** Returns "leader" or "follower" — current role. */
  currentRole(): "leader" | "follower" {
    return this.role;
  }

  /** Returns the locally-hosted Broker when this peer is the leader, or
   *  null when it's a follower. Wave 25C uses this to attach the
   *  cross-PC router. */
  localBroker(): Broker | null {
    return this.broker;
  }

  /**
   * Fire-and-forget send. Doesn't await a reply.
   *
   * `re` (optional) lets the caller correlate this message as a reply to a
   * previous request — when an LLM peer is *answering* a question from
   * another agent, it must echo the original `id` here so the requester's
   * pending map can resolve. Without `re`, the requester treats this as a
   * new unsolicited message and its `request()` call times out.
   */
  async send(
    to: string | string[],
    body: unknown,
    re: string | null = null,
  ): Promise<void> {
    const env = envelope(this.assignedName, to, body, re);
    await this._writeEnvelope(env);
  }

  /**
   * Unicast send + await broker ACK. Returns the ACK status:
   *   - `received` — peer was idle, envelope delivered, will be processed soon
   *   - `busy`     — peer mid-turn, envelope dropped; sender is owner of retry
   *   - `denied`   — broker/Relay refused delivery (including authorization or envelope failure).
   *                  Cross-PC: only after `CROSS_PC_DENIED_GRACE_MS` without a
   *                  `received`; `answers` names every broker that denied
   *   - `timeout`  — no ACK within `timeoutMs`, or trusted Relay says offline
   *
   * Only meaningful for unicast non-broadcast addresses. The peer's body-level
   * reply (if any) is asynchronous and arrives as a normal inbound envelope
   * carrying `re=<this-send-id>` in a future turn — handled by `onMessage`.
   */
  async sendWithAck(
    to: string,
    body: unknown,
    re: string | null = null,
    timeoutMs: number = ACK_TIMEOUT_MS,
  ): Promise<AckResult> {
    const env = envelope(this.assignedName, to, body, re);
    return new Promise<AckResult>((resolve) => {
      const timer = setTimeout(() => {
        const slot = this.ackPending.get(env.id);
        if (slot) this._settleAck(env.id, slot, { status: "timeout", id: env.id });
        else resolve({ status: "timeout", id: env.id });
      }, timeoutMs);
      this.ackPending.set(env.id, {
        expectedFrom: expectedAckSender(to),
        resolve,
        timer,
        denials: [],
        graceTimer: null,
      });
      this._writeEnvelope(env).catch(() => {
        const slot = this.ackPending.get(env.id);
        if (!slot) return;
        this._settleAck(env.id, slot, { status: "timeout", id: env.id });
      });
    });
  }

  /**
   * Send + await reply. Resolves with the first inbound envelope whose `re`
   * matches the outbound `id`. Rejects on timeout, teardown/write failure, or
   * a trusted Relay transport error.
   */
  async request(
    to: string,
    body: unknown,
    timeoutMs: number = this.opts.defaultTimeoutMs ?? DEFAULT_TIMEOUT_MS,
  ): Promise<Envelope> {
    const env = envelope(this.assignedName, to, body, null);
    return new Promise<Envelope>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(env.id);
        reject(new Error(`request to ${to} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(env.id, { resolve, reject, timer });
      this._writeEnvelope(env).catch((err) => {
        const slot = this.pending.get(env.id);
        if (!slot) return;
        clearTimeout(slot.timer);
        this.pending.delete(env.id);
        reject(err);
      });
    });
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  /**
   * Fires after the peer successfully (re)joins following a failover —
   * leader died and we re-elected. NOT called for the initial `start()`,
   * only for post-drop reconnects. Consumers use this to re-query state
   * the broker may have lost in the transition (e.g., peer list).
   */
  onReconnect(handler: ReconnectHandler): () => void {
    this.reconnectHandlers.add(handler);
    return () => this.reconnectHandlers.delete(handler);
  }

  /**
   * Requests a different display name from the broker. Returns the name
   * actually assigned (may carry a #N suffix on collision). Implemented as
   * a soft rejoin: leaves & rejoins with the new name.
   */
  async rename(newName: string): Promise<string> {
    await this._teardownConn();
    this.opts.name = newName;
    this.assignedName = newName;
    return this._joinOrLead();
  }

  async leave(): Promise<void> {
    this.leftFlag = true;
    await this._teardownConn();
  }

  // ── join / failover loop ──────────────────────────────────────────────────

  private async _joinOrLead(): Promise<string> {
    const result: ElectionResult = await joinOrLead(this.opts.sockPath);
    if (result.role === "leader") {
      this.role = "leader";
      const broker = new Broker({
        server: result.server,
        auditPath: this.opts.auditPath,
      });
      this.broker = broker;
      // Leader also registers itself as a peer so other followers see it +
      // can address it. We create a self-loopback socket via the broker's
      // internal API: easiest is to open a real client connection back to
      // our own server.
      try {
        const registration = await this._registerAsClient(broker.instanceId);
        if (registration.foreign) {
          // Issue #140: between our bind and this registration another process
          // took the path, so nothing can reach our server. That process is
          // the leader. The registration it just gave us over the loopback
          // connection stands: keep that connection as our follower socket and
          // give up only our own broker. Abandon, not close: see `abandon()`.
          this.role = "follower";
          this.broker = null;
          this.ownSockIdentity = null;
          try { broker.abandon(); } catch { /* best-effort */ }
          return registration.name;
        }
        this.ownSockIdentity = result.identity;
        this._startLeaderPathCheck();
        return registration.name;
      } catch (err) {
        // Self-registration failed, so this process cannot act as a peer even
        // though it now owns the broker path. Release the path rather than hold
        // it: leaving it bound strands every later joiner behind a broker whose
        // owner simultaneously reports "join failed".
        //
        // The server accepts from the moment Broker is constructed, so a fast
        // follower may already be attached. close() destroys those sockets, and
        // a follower that is still joined reads the drop as a leader loss and
        // re-runs election via _onSocketClose; one already leaving stays put.
        // Either way it recovers, whereas a stranded path never does.
        try {
          if (this._ownsBrokerPath(result.identity)) await broker.close();
          else broker.abandon();
        } catch { /* best-effort */ }
        this.broker = null;
        this.role = "follower";
        this.ownSockIdentity = null;
        throw err;
      }
    } else {
      this.role = "follower";
      this._wireSocket(result.socket);
      return (await this._registerOver(result.socket)).name;
    }
  }

  private async _registerAsClient(expectInstance?: string): Promise<Registration> {
    const { createConnection } = await import("node:net");
    const sock = createConnection(this.opts.sockPath);
    await new Promise<void>((resolve, reject) => {
      sock.once("connect", () => resolve());
      // Destroy before rejecting: a failed connect still leaves a socket object
      // holding an fd, and nothing downstream ever sees this one.
      sock.once("error", (err) => { sock.destroy(); reject(err); });
    });
    this._wireSocket(sock);
    return this._registerOver(sock, expectInstance);
  }

  private _wireSocket(sock: Socket): void {
    this.socket = sock;
    this.buf = "";
    sock.setEncoding("utf8");
    sock.on("data", (chunk: string) => this._onData(chunk));
    sock.on("close", () => this._onSocketClose(sock));
    sock.on("error", () => { /* close will follow */ });
  }

  private _registerOver(sock: Socket, expectInstance?: string): Promise<Registration> {
    return new Promise<Registration>((resolve, reject) => {
      let settled = false;
      // The first inbound line MUST be the register_ack. Buffer-aware.
      //
      // Reaching this timer means election chose the follower path against a
      // broker that cannot answer. `tryConnect` only proves the endpoint is
      // connectable, never that its owner is servicing anything. On POSIX an
      // AF_UNIX connect() completes as soon as the kernel queues the connection
      // in the listener backlog, so the owning process need not run at all; a
      // suspended or event-loop-blocked leader still looks healthy to election.
      // Windows named pipes behave the same way here (fork note): a suspended
      // server's listening instance still completes the kernel-level handshake.
      //
      // Nothing here can recover on its own, because the queued connection and
      // the mesh both belong to that other process. Naming it saves the operator
      // a manual walk of /proc (Linux) or Process Explorer (Windows), but
      // diagnosis must never widen the leak this path exists to close: the
      // deadline decides the outcome and frees the descriptor, and only the
      // wording of the rejection is still pending. An ack arriving after that
      // point is too late to be honoured.
      //
      // The deadline is installed before the helpers it calls. JavaScript runs
      // this executor to completion before any timer callback, so `release` is
      // always defined by the time the deadline can fire.
      const wait = setTimeout(() => {
        if (settled) return;
        settled = true;
        release();
        void describeSocketOwner(this.opts.sockPath).then((owner) => {
          reject(new Error(
            `register_ack timeout after ${ACK_TIMEOUT_MS}ms: `
            + describeRegistrationBlocker(this.opts.sockPath, owner),
          ));
        });
      }, ACK_TIMEOUT_MS);
      // Releasing is separate from rejecting because the timeout path needs the
      // descriptor closed at the deadline while it still has a message to build.
      const release = (): void => {
        clearTimeout(wait);
        this._preAckListener = null;
        // Clear the active socket before destroying it, so the close handler does
        // not read this as a live-connection drop and start a fresh election.
        // On the leader path this is only the self-loopback client; the broker
        // server belongs to _joinOrLead and is closed there when we throw.
        if (this.socket === sock) this.socket = null;
        sock.destroy();
      };
      const fail = (err: Error): void => {
        if (settled) return;
        settled = true;
        release();
        reject(err);
      };
      const onceListener = (raw: unknown) => {
        // plan/38: a new broker returns `address_assigned` (canonical key) +
        // `name_assigned` (clean leaf). Read both with cross-fallback so we work
        // against either a new broker OR a legacy one (only `name_assigned`,
        // where address == name).
        const ack = raw as { type?: string; name_assigned?: string; address_assigned?: string; instance?: unknown };
        const name = typeof ack?.name_assigned === "string" ? ack.name_assigned : ack?.address_assigned;
        const address = typeof ack?.address_assigned === "string" ? ack.address_assigned : ack?.name_assigned;
        if (ack && ack.type === "register_ack" && typeof name === "string" && typeof address === "string") {
          if (settled) return;
          settled = true;
          clearTimeout(wait);
          this.assignedName = name;
          this.assignedAddress = address;
          this._preAckListener = null;
          resolve({
            name,
            // A leader registering back through its own path must hear its own
            // broker (issue #140). A different instance, or a broker too old
            // to name itself, means the path was taken over in between.
            foreign: expectInstance !== undefined && ack.instance !== expectInstance,
          });
        } else {
          fail(new Error(`expected register_ack, got: ${JSON.stringify(raw)}`));
        }
      };
      this._preAckListener = onceListener;
      const req = JSON.stringify({
        type: "register",
        name: this.opts.name,
        // Only include cwd when set — keeps the wire identical to the legacy
        // payload for callers that don't supply it (broker treats absent cwd
        // as "no take-over", i.e. the old #N behavior).
        ...(this.opts.cwd !== undefined ? { cwd: this.opts.cwd } : {}),
        ...(this.opts.takeoverExisting === true ? { takeover: true } : {}),
      }) + "\n";
      try {
        sock.write(req);
      } catch (e) {
        fail(e as Error);
      }
    });
  }

  private _preAckListener: ((raw: unknown) => void) | null = null;

  private _onData(chunk: string): void {
    this.buf += chunk;
    let nl: number;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      if (!line) continue;
      this._handleLine(line);
    }
  }

  private _handleLine(line: string): void {
    // Before register_ack: parse loosely as an ack control message.
    if (this._preAckListener) {
      try {
        const parsed = JSON.parse(line) as unknown;
        this._preAckListener(parsed);
      } catch {
        // Garbage during register window — ignore.
      }
      return;
    }

    // Regular envelope.
    let env: Envelope;
    try {
      env = parse(line);
    } catch (e) {
      if (e instanceof EnvelopeError) return;
      throw e;
    }

    // Reserve every raw transport_error body before either pending map can
    // correlate it. Only exact broker provenance plus a valid body may settle;
    // forged or invalid reserved frames remain ordinary handler messages.
    if (hasTransportErrorType(env.body)) {
      const trusted = env.from === "broker" && env.re !== null
        ? asTransportErrorBody(env.body)
        : null;
      if (trusted && env.re !== null) {
        this._consumeAckTransportError(env.re, trusted.reason);
        this._rejectRequestTransportError(env.re, trusted.reason);
        return;
      }
      this._dispatchToHandlers(env);
      return;
    }

    // Reserve exact broker ACKs before generic correlation or handler dispatch.
    // The sender is bound when the send begins: local sends accept only
    // `broker`, while remote alias sends accept only `<alias>:broker`.
    const fromBroker = env.from === "broker" || env.from.endsWith(":broker");
    if (fromBroker && hasExactAckType(env.body)) {
      const ackBody = asAckBody(env.body);
      if (env.re !== null && ackBody) {
        const slot = this.ackPending.get(env.re);
        if (slot && slot.expectedFrom === env.from) {
          if (ackBody.status === "denied" && slot.expectedFrom !== "broker") {
            // Issue #140: several brokers of the target PC may answer this
            // send; the one that knows the target has not had its say yet.
            this._deferRemoteDenial(env.re, slot, ackBody);
          } else {
            this._settleAck(env.re, slot, {
              status: ackBody.status,
              id: env.re,
              target: ackBody.target,
            });
          }
        }
      }
      return;
    }

    // Correlate replies for `request()`.
    if (env.re) {
      const slot = this.pending.get(env.re);
      if (slot) {
        clearTimeout(slot.timer);
        this.pending.delete(env.re);
        slot.resolve(env);
        return;
      }
    }

    // Otherwise dispatch to subscribers.
    this._dispatchToHandlers(env);
  }

  private _consumeAckTransportError(
    correlationId: string,
    reason: TransportErrorReason,
  ): void {
    const pendingId = correlationId.toLowerCase();
    const slot = this.ackPending.get(pendingId);
    if (!slot) return;
    // The Relay is one voice: its refusal settles at once, with no grace.
    this._settleAck(pendingId, slot, {
      status: reason === "offline" ? "timeout" : "denied",
      id: pendingId,
      error: `transport_error: ${reason}`,
      reason,
    });
  }

  private _rejectRequestTransportError(
    correlationId: string,
    reason: TransportErrorReason,
  ): void {
    const pendingId = correlationId.toLowerCase();
    const slot = this.pending.get(pendingId);
    if (!slot) return;
    clearTimeout(slot.timer);
    this.pending.delete(pendingId);
    slot.reject(new MeshTransportError(reason, pendingId));
  }

  /** Issue #140: a cross-PC `denied` starts the grace instead of settling the
   *  send. The first one starts the timer; later ones are only recorded. When
   * the grace runs out the send is still pending, the `denied` is final and
   * carries every broker that said it. */
  private _deferRemoteDenial(id: string, slot: AckSlot, ackBody: AckBody): void {
    slot.denials.push({
      status: "denied",
      ...(ackBody.pid !== undefined ? { pid: ackBody.pid } : {}),
    });
    if (slot.graceTimer) return;
    slot.graceTimer = setTimeout(() => {
      const pending = this.ackPending.get(id);
      if (!pending) return;
      this._settleAck(id, pending, {
        status: "denied",
        id,
        target: ackBody.target,
        answers: pending.denials,
      });
    }, CROSS_PC_DENIED_GRACE_MS);
  }

  private _settleAck(id: string, slot: AckSlot, result: AckResult): void {
    clearTimeout(slot.timer);
    if (slot.graceTimer) clearTimeout(slot.graceTimer);
    slot.graceTimer = null;
    this.ackPending.delete(id);
    slot.resolve(result);
  }

  private _dispatchToHandlers(env: Envelope): void {
    for (const h of this.handlers) {
      try { h(env); } catch { /* handler errors don't break peer */ }
    }
  }

  private async _writeEnvelope(env: Envelope): Promise<void> {
    if (!this.socket || this.socket.destroyed) {
      throw new Error("session peer not connected");
    }
    this.socket.write(serialize(env));
  }

  private async _onSocketClose(closedSock: Socket): Promise<void> {
    if (this.leftFlag) return;  // intentional leave
    // Only the CURRENT socket dying is a real failover. A close from a socket
    // we've already replaced — `rename()` (teardown + rejoin) or a prior
    // reconnect — must NOT trigger another `_joinOrLead`, or we'd double-
    // register (the broker suffixes the second as `#N`) and leave an orphaned
    // still-open socket as a ghost peer. `this.socket` is null mid-rename
    // (teardown done, rejoin in flight) or already the new socket — either way
    // `!== closedSock`, so we skip. Genuine leader death: `this.socket` is still
    // the (now-closed) follower socket → identity matches → we re-elect.
    if (this.socket !== closedSock) return;
    // Attempt to re-elect once. New leader will bind sockPath; we either
    // become leader ourselves or rejoin as follower.
    await delay(FAILOVER_RETRY_MS);
    if (this.leftFlag || this.socket !== closedSock) return;
    await this._rejoin();
  }

  /** Re-run the election and tell consumers the broker changed: its peers map
   *  starts empty, so cached state (peer count, relay bridge) must be rebuilt. */
  private async _rejoin(): Promise<void> {
    try {
      await this._joinOrLead();
      for (const h of this.reconnectHandlers) {
        try { h(); } catch { /* handler errors don't break peer */ }
      }
    } catch { /* election failed; peer stuck in disconnected state */ }
  }

  /**
   * Issue #140: a leader whose socket path no longer leads to its own broker
   * cannot be reached by any later joiner, yet it keeps its clients and (via
   * MeshNode) the relay bridge. The host then has two brokers answering for
   * it. The election no longer produces that on its own, but an operator's
   * `rm`, a cleanup script or an unknown race can, so the leader checks. One
   * `lstat`, no connection: it cannot misfire on a busy broker. POSIX only; a
   * Windows pipe cannot be removed under its owner.
   */
  private _startLeaderPathCheck(): void {
    const expected = this.ownSockIdentity;
    const intervalMs = this.opts.leaderPathCheckIntervalMs ?? LEADER_PATH_CHECK_INTERVAL_MS;
    if (!expected || intervalMs <= 0 || this.leaderPathCheck) return;
    const timer = setInterval(() => {
      if (this.role !== "leader" || !this.broker || this.leftFlag) return;
      const current = socketIdentity(this.opts.sockPath);
      if (current && current.dev === expected.dev && current.ino === expected.ino) return;
      void this._stepDown();
    }, intervalMs);
    timer.unref?.();
    this.leaderPathCheck = timer;
  }

  private _stopLeaderPathCheck(): void {
    if (this.leaderPathCheck) clearInterval(this.leaderPathCheck);
    this.leaderPathCheck = null;
  }

  /**
   * Issue #140: stand down as leader and rejoin the mesh. The old broker's
   * clients read its close as a leader loss and re-elect, which now leads them
   * to whoever owns the path; the reconnect handlers then take the relay
   * bridge down (MeshNode), so one PC speaks with one broker again.
   */
  private async _stepDown(): Promise<void> {
    if (this.stepDownInFlight) return this.stepDownInFlight;
    const broker = this.broker;
    if (!broker || this.role !== "leader" || this.leftFlag) return;
    const run = (async (): Promise<void> => {
      this.role = "follower";
      this.broker = null;
      this.ownSockIdentity = null;
      this._stopLeaderPathCheck();
      // The loopback socket dies with the broker. Detach it first so its
      // close is not read as a live-connection drop and answered with a
      // second, concurrent election.
      this.socket = null;
      // Not `close()`: this leader no longer owns the path (that is why it
      // stands down), and closing would remove the successor's socket file.
      try { broker.abandon(); } catch { /* ignored */ }
      if (this.leftFlag) return;
      await this._rejoin();
    })();
    this.stepDownInFlight = run;
    try {
      await run;
    } finally {
      if (this.stepDownInFlight === run) this.stepDownInFlight = null;
    }
  }

  private async _teardownConn(): Promise<void> {
    // A stand-down re-elects. Let it finish, so this teardown and that join
    // cannot interleave into a double registration.
    while (this.stepDownInFlight) await this.stepDownInFlight;
    this._stopLeaderPathCheck();
    const own = this.ownSockIdentity;
    this.ownSockIdentity = null;
    for (const [id, slot] of this.pending) {
      clearTimeout(slot.timer);
      this.pending.delete(id);
      slot.reject(new Error("peer leaving"));
    }
    for (const [id, slot] of this.ackPending) {
      this._settleAck(id, slot, { status: "timeout", id });
    }

    if (this.socket) {
      try { this.socket.destroy(); } catch { /* ignored */ }
      this.socket = null;
    }
    if (this.broker) {
      try {
        if (this._ownsBrokerPath(own)) await this.broker.close();
        else this.broker.abandon();
      } catch { /* ignored */ }
      this.broker = null;
    }
  }

  /**
   * Whether the socket file at our path is still the one this leader's
   * broker was bound to. It decides between `close()` and `abandon()` (issue
   * #140): closing a listening server makes libuv unlink whatever lies at the
   * path by then, so only the owner of the path may close.
   *
   * A Windows pipe cannot be removed or rebound under its owner, so its
   * holder always owns it. On POSIX an unknown identity counts as not owned:
   * leaving a listener behind costs one descriptor, removing a successor's
   * socket costs the host its broker.
   */
  private _ownsBrokerPath(identity: SocketIdentity | null): boolean {
    if (usesNamedPipe()) return true;
    if (!identity) return false;
    const current = socketIdentity(this.opts.sockPath);
    return current !== null && current.dev === identity.dev && current.ino === identity.ino;
  }
}
