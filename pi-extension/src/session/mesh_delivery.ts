import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { MeshEnvelope } from "../extension-state.js";

export type MeshDrainContext = Pick<ExtensionContext, "isIdle">;
export type MeshDeliveryErrorHandler = (message: string) => void;

type MeshWakeRequest = {
  token: number;
  lifecycleGeneration: number;
  timer: ReturnType<typeof setTimeout> | null;
};

const MESH_WAKE_START_TIMEOUT_MS = 1_000;
const MESH_IDLE_RECHECK_MS = 10;

function meshMessageForAgent(env: MeshEnvelope) {
  const bodyText = typeof env.body === "string" ? env.body : JSON.stringify(env.body);
  const header = `[agent-network] message from "${env.from}" (id=${env.id}${env.re ? `, re=${env.re}` : ""}):`;
  const footer = env.re
    ? "(This is a reply to a previous message of yours.)"
    : `(If a reply is expected, call agent_send with to="${env.from}" and re="${env.id}".)`;
  return {
    customType: "remote-pi:mesh-message",
    content: `${header}\n${bodyText}\n\n${footer}`,
    display: true,
  };
}

function meshWakeMessage() {
  return {
    customType: "remote-pi:mesh-wake",
    content: "Process any already-appended agent-network messages.",
    display: false,
  };
}

/**
 * Delivery state for exactly one AgentSession.
 *
 * A wake request is not activity: only agent_start confirms a run. Accepted
 * appends are never replayed after a wake failure; only an unsubmitted suffix
 * returns to the FIFO. dispose() invalidates every callback and drops the
 * outgoing in-memory queue, matching the existing non-durable ACK contract.
 */
export class MeshDeliveryController {
  private pending: MeshEnvelope[] = [];
  private scheduled = false;
  private lifecycleGeneration = 0;
  private agentRunActive = false;
  private agentRunGeneration = 0;
  private agentEndSettling = false;
  private agentEndSettleTimer: ReturnType<typeof setTimeout> | null = null;
  private idleRecheckTimer: ReturnType<typeof setTimeout> | null = null;
  private context: MeshDrainContext | null = null;
  private contextGeneration = 0;
  private wakeRequest: MeshWakeRequest | null = null;
  private wakeToken = 0;
  private disposed = false;

  constructor(
    readonly pi: ExtensionAPI,
    private readonly onError: MeshDeliveryErrorHandler,
  ) {}

  captureContext(ctx: MeshDrainContext): void {
    if (this.disposed) return;
    this.context = ctx;
    this.contextGeneration += 1;
    if (this.idleRecheckTimer) {
      clearTimeout(this.idleRecheckTimer);
      this.idleRecheckTimer = null;
    }
    this.scheduleDrain();
  }

  agentStart(ctx?: MeshDrainContext): void {
    if (this.disposed) return;
    this.agentRunActive = true;
    this.agentRunGeneration += 1;
    this.agentEndSettling = false;
    if (this.agentEndSettleTimer) {
      clearTimeout(this.agentEndSettleTimer);
      this.agentEndSettleTimer = null;
    }
    this.clearWakeRequest();
    if (ctx) this.captureContext(ctx);
  }

  agentEnd(ctx?: MeshDrainContext): void {
    if (this.disposed) return;
    this.agentRunActive = false;
    if (ctx) this.captureContext(ctx);
    // Pi remains internally active until agent_end listeners return. Keep a
    // separate settling gate and then wait for the live context to prove idle.
    this.agentEndSettling = true;
    if (this.agentEndSettleTimer) clearTimeout(this.agentEndSettleTimer);
    this.scheduleAgentEndSettle(this.lifecycleGeneration, this.agentRunGeneration, 0);
  }

  deliver(env: MeshEnvelope): boolean {
    if (this.disposed) return false;
    this.pending.push(env);
    this.scheduleDrain();
    return true;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.lifecycleGeneration += 1;
    this.scheduled = false;
    this.agentEndSettling = false;
    this.agentRunActive = false;
    this.pending = [];
    if (this.agentEndSettleTimer) clearTimeout(this.agentEndSettleTimer);
    if (this.idleRecheckTimer) clearTimeout(this.idleRecheckTimer);
    this.agentEndSettleTimer = null;
    this.idleRecheckTimer = null;
    this.clearWakeRequest();
    this.context = null;
    this.contextGeneration += 1;
  }

  private clearWakeRequest(): void {
    const request = this.wakeRequest;
    if (!request) return;
    if (request.timer) clearTimeout(request.timer);
    this.wakeRequest = null;
  }

  private readContextIdle(
    context: MeshDrainContext,
    contextGeneration: number,
  ): boolean | null {
    if (this.disposed || this.context !== context || this.contextGeneration !== contextGeneration) {
      return null;
    }
    try {
      return context.isIdle();
    } catch {
      // Extension contexts throw after replacement. Never re-arm against a
      // newer session after that stale access fails.
      if (this.context === context && this.contextGeneration === contextGeneration) {
        this.context = null;
        this.contextGeneration += 1;
      }
      return null;
    }
  }

  private scheduleAgentEndSettle(
    lifecycleGeneration: number,
    endedGeneration: number,
    delay: number,
  ): void {
    if (this.agentEndSettleTimer) clearTimeout(this.agentEndSettleTimer);
    const context = this.context;
    const contextGeneration = this.contextGeneration;
    this.agentEndSettleTimer = setTimeout(() => {
      this.agentEndSettleTimer = null;
      if (
        this.disposed
        || this.lifecycleGeneration !== lifecycleGeneration
        || this.agentRunGeneration !== endedGeneration
        || !this.agentEndSettling
        || !context
      ) return;
      const isIdle = this.readContextIdle(context, contextGeneration);
      if (isIdle !== true) {
        if (isIdle === false) {
          this.scheduleAgentEndSettle(lifecycleGeneration, endedGeneration, MESH_IDLE_RECHECK_MS);
        }
        return;
      }
      this.agentEndSettling = false;
      this.scheduleDrain();
    }, delay);
  }

  private scheduleIdleRecheck(
    lifecycleGeneration: number,
    context: MeshDrainContext,
    contextGeneration: number,
  ): void {
    if (this.idleRecheckTimer) return;
    this.idleRecheckTimer = setTimeout(() => {
      this.idleRecheckTimer = null;
      if (this.disposed || this.lifecycleGeneration !== lifecycleGeneration) return;
      const isIdle = this.readContextIdle(context, contextGeneration);
      if (isIdle !== true) {
        if (isIdle === false && this.pending.length > 0) {
          this.scheduleIdleRecheck(lifecycleGeneration, context, contextGeneration);
        }
        return;
      }
      this.scheduleDrain();
    }, MESH_IDLE_RECHECK_MS);
  }

  private requestWake(lifecycleGeneration: number): void {
    const request: MeshWakeRequest = {
      token: ++this.wakeToken,
      lifecycleGeneration,
      timer: null,
    };
    // Install before sending: a runtime bridge may synchronously emit
    // agent_start while sendMessage is still on the stack.
    this.wakeRequest = request;
    try {
      this.pi.sendMessage(meshWakeMessage(), { triggerTurn: true, deliverAs: "followUp" });
    } catch (error) {
      if (this.wakeRequest?.token === request.token) this.wakeRequest = null;
      const detail = error instanceof Error ? error.message : String(error);
      this.onError(`[remote-pi] queued mesh wake failed: ${detail}`);
      return;
    }

    // A re-entrant agent_start already confirmed this wake.
    if (this.wakeRequest?.token !== request.token) return;
    request.timer = setTimeout(() => {
      if (
        this.disposed
        || this.wakeRequest?.token !== request.token
        || this.lifecycleGeneration !== request.lifecycleGeneration
      ) return;
      this.wakeRequest = null;
      // No agent_start is ambiguous. Do not replay accepted content; a later
      // envelope or ordinary turn can consume it, while later FIFO work resumes.
      this.scheduleDrain();
    }, MESH_WAKE_START_TIMEOUT_MS);
  }

  private scheduleDrain(): void {
    if (this.disposed || this.scheduled || this.pending.length === 0) return;
    this.scheduled = true;
    const lifecycleGeneration = this.lifecycleGeneration;
    queueMicrotask(() => {
      this.scheduled = false;
      if (
        this.disposed
        || this.lifecycleGeneration !== lifecycleGeneration
        || this.agentRunActive
        || this.agentEndSettling
        || this.wakeRequest
        || this.pending.length === 0
      ) return;

      const context = this.context;
      const contextGeneration = this.contextGeneration;
      if (!context) return;
      const isIdle = this.readContextIdle(context, contextGeneration);
      if (isIdle !== true) {
        if (isIdle === false) {
          this.scheduleIdleRecheck(lifecycleGeneration, context, contextGeneration);
        }
        return;
      }

      const batch = this.pending.splice(0);
      let submitted = 0;
      try {
        for (const env of batch) {
          this.pi.sendMessage(meshMessageForAgent(env), { triggerTurn: false });
          submitted += 1;
        }
      } catch (error) {
        // Preserve only the unsubmitted suffix, ahead of arrivals that happened
        // while this batch was on the stack.
        this.pending = [...batch.slice(submitted), ...this.pending];
        const detail = error instanceof Error ? error.message : String(error);
        this.onError(`[remote-pi] queued mesh delivery failed: ${detail}`);
        return;
      }

      if (submitted === 0 || this.disposed || this.lifecycleGeneration !== lifecycleGeneration) return;
      this.requestWake(lifecycleGeneration);
    });
  }
}

/** Per-pi controllers plus the single owner whose MeshNode receives envelopes. */
export class MeshDeliveryRegistry {
  private readonly controllers = new Map<ExtensionAPI, MeshDeliveryController>();
  private activePi: ExtensionAPI | null = null;

  constructor(private onError: MeshDeliveryErrorHandler = (message) => console.error(message)) {}

  setErrorHandler(onError: MeshDeliveryErrorHandler): void {
    this.onError = onError;
  }

  for(pi: ExtensionAPI): MeshDeliveryController {
    let controller = this.controllers.get(pi);
    if (!controller) {
      controller = new MeshDeliveryController(pi, (message) => this.onError(message));
      this.controllers.set(pi, controller);
    }
    return controller;
  }

  activate(pi: ExtensionAPI): MeshDeliveryController {
    const controller = this.for(pi);
    this.activePi = pi;
    return controller;
  }

  active(): MeshDeliveryController | null {
    return this.activePi ? this.controllers.get(this.activePi) ?? null : null;
  }

  dispose(pi: ExtensionAPI): void {
    this.controllers.get(pi)?.dispose();
    this.controllers.delete(pi);
    if (this.activePi === pi) this.activePi = null;
  }

  disposeActive(): void {
    if (this.activePi) this.dispose(this.activePi);
  }

  disposeAll(): void {
    for (const controller of this.controllers.values()) controller.dispose();
    this.controllers.clear();
    this.activePi = null;
  }
}
