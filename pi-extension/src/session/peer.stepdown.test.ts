/**
 * Issue #140 — one broker per host.
 *
 * A host is meant to have exactly one local broker: the leader of the one
 * local mesh, and the only process that attaches the cross-PC relay bridge.
 * While two answered for the same PC, a cross-PC send was settled by whichever
 * answer came first, so a delivered message could be reported as `denied`.
 *
 * The election no longer produces a second leader (see `leader_election.test.ts`).
 * These tests cover the two safety nets behind it in `SessionPeer`:
 *
 * - a leader that hears ANOTHER broker at its own path keeps the registration
 *   that broker just gave it and follows it;
 * - a leader whose path is later taken away stands down, and its clients
 *   re-elect onto whoever owns the path now.
 *
 * In both cases the old broker is abandoned, not closed: libuv unlinks the file
 * a server was bound to when the server closes, whatever lies there by then,
 * so closing would remove the successor's socket.
 */
import { afterEach, describe, expect, test, vi } from "vitest";
import { once } from "node:events";
import { linkSync, mkdtempSync, rmSync, unlinkSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { Broker } from "./broker.js";
import { SessionPeer } from "./peer.js";
import { ipcAddress } from "./ipc.js";
import { probe, removeStaleSock, socketIdentity } from "./leader_election.js";

// Only `joinOrLead` is replaced, and only while a test sets `next`; everything
// else stays real so the POSIX cases can use the actual election.
const election = vi.hoisted(() => ({
  next: null as null | (() => Promise<unknown>),
}));
vi.mock("./leader_election.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./leader_election.js")>();
  return {
    ...actual,
    joinOrLead: (sockPath: string) =>
      (election.next ? election.next() : actual.joinOrLead(sockPath)),
  };
});

const posix = process.platform !== "win32";

function tmpSock(): { dir: string; path: string } {
  const dir = mkdtempSync(join(tmpdir(), "pi-peer-stepdown-"));
  return { dir, path: ipcAddress(`peer-sd-${basename(dir)}`, join(dir, "broker.sock")) };
}

async function listen(server: Server, path: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(path, () => {
      server.off("error", reject);
      resolve();
    });
  });
}

async function waitFor(what: string, predicate: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await delay(10);
  }
}

afterEach(() => {
  election.next = null;
});

describe("SessionPeer: one broker per host (issue #140)", () => {
  test("a leader that hears another broker at its own path follows it instead", async () => {
    const { dir, path } = tmpSock();
    const rivalServer = createServer();
    const rival = new Broker({ server: rivalServer });
    await listen(rivalServer, path);

    // The election reports "leader" but hands a server that is NOT the one at
    // the path: the tail of a race in which another process rebound the path
    // after our bind.
    const orphanServer = createServer();
    election.next = async () => ({ role: "leader", server: orphanServer, identity: null });

    const peer = new SessionPeer({
      sockPath: path,
      name: "orphan",
      cwd: "/tmp/orphan",
      leaderPathCheckIntervalMs: 0,
    });
    try {
      expect(await peer.start()).toBe("orphan");

      // No second broker on this host: the peer is a follower of the real one.
      expect(peer.currentRole()).toBe("follower");
      expect(peer.localBroker()).toBeNull();
      // The successor keeps its socket: giving up our own broker did not
      // remove it (closing the listener would have).
      const reachable = await probe(path);
      expect(reachable.ok).toBe(true);
      if (reachable.ok) reachable.socket.destroy();

      // The registration the rival gave over the loopback connection stands.
      expect(rival.peerNames()).toEqual(["/tmp/orphan@orphan"]);
      expect(peer.address()).toBe("/tmp/orphan@orphan");

      // And it is a working connection: a message through the rival arrives.
      const seen: string[] = [];
      peer.onMessage((env) => seen.push(JSON.stringify(env.body)));
      rival.injectFromRemote({
        from: "trab:someone",
        to: peer.address(),
        id: "01976000-0000-7000-8000-000000000201",
        re: null,
        body: { hello: "world" },
      });
      await waitFor("the injected message", () => seen.length === 1, 2_000);
      expect(seen[0]).toBe('{"hello":"world"}');
    } finally {
      await peer.leave();
      await rival.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 10_000);

  test.skipIf(!posix)("a leader whose path is taken away stands down; its clients follow the new owner", async () => {
    const { dir, path } = tmpSock();
    const leader = new SessionPeer({
      sockPath: path,
      name: "first",
      cwd: "/tmp/first",
      leaderPathCheckIntervalMs: 30,
    });
    const client = new SessionPeer({
      sockPath: path,
      name: "client",
      cwd: "/tmp/client",
      leaderPathCheckIntervalMs: 0,
    });
    await leader.start();
    await client.start();
    expect(leader.currentRole()).toBe("leader");
    expect(client.currentRole()).toBe("follower");
    expect(leader.localBroker()!.peerNames().sort()).toEqual(["/tmp/client@client", "/tmp/first@first"]);

    const reconnects: string[] = [];
    const roleChanges = () => {
      reconnects.push(`leader:${leader.currentRole()}`);
      reconnects.push(`client:${client.currentRole()}`);
    };
    leader.onReconnect(roleChanges);
    client.onReconnect(roleChanges);

    // The takeover the election no longer produces on its own: the leader's
    // socket file disappears and another broker is bound at the path. The
    // `.keep` link holds the old inode allocated, so the new file cannot come
    // back with the same inode number and the check has something to see.
    const keep = `${path}.keep`;
    linkSync(path, keep);
    const own = socketIdentity(path)!;
    unlinkSync(path);
    const rivalServer = createServer();
    const rival = new Broker({ server: rivalServer });
    await listen(rivalServer, path);
    const rivalIdentity = socketIdentity(path)!;
    expect(rivalIdentity.ino).not.toBe(own.ino);

    try {
      await waitFor(
        "leader and client on the new broker",
        () => leader.currentRole() === "follower" && rival.peerNames().length === 2,
        5_000,
      );
      expect(leader.localBroker()).toBeNull();
      expect(client.currentRole()).toBe("follower");
      expect(rival.peerNames().sort()).toEqual(["/tmp/client@client", "/tmp/first@first"]);
      // The old leader abandoned its listener instead of closing it, so the
      // successor is still the one at the path, and a newcomer follows it.
      expect(socketIdentity(path)).toEqual(rivalIdentity);
      const newcomer = new SessionPeer({
        sockPath: path,
        name: "late",
        cwd: "/tmp/late",
        leaderPathCheckIntervalMs: 0,
      });
      try {
        await newcomer.start();
        expect(newcomer.currentRole()).toBe("follower");
        expect(rival.peerNames()).toContain("/tmp/late@late");
      } finally {
        await newcomer.leave();
      }
      // Both were told that the broker changed, as after any leader loss.
      expect(reconnects).toContain("leader:follower");
      expect(reconnects).toContain("client:follower");
    } finally {
      await leader.leave();
      await client.leave();
      await rival.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 15_000);

  test.skipIf(!posix)("a path check finds nothing wrong while the leader owns its socket", async () => {
    const { dir, path } = tmpSock();
    const leader = new SessionPeer({
      sockPath: path,
      name: "calm",
      cwd: "/tmp/calm",
      leaderPathCheckIntervalMs: 10,
    });
    const reconnects: number[] = [];
    try {
      await leader.start();
      expect(leader.currentRole()).toBe("leader");
      leader.onReconnect(() => reconnects.push(Date.now()));
      const own = socketIdentity(path);
      expect(own).not.toBeNull();

      // Several check intervals pass without a stand-down.
      await delay(120);
      expect(leader.currentRole()).toBe("leader");
      expect(reconnects).toHaveLength(0);
      expect(socketIdentity(path)).toEqual(own);
    } finally {
      await leader.leave();
      removeStaleSock(path);
      rmSync(dir, { recursive: true, force: true });
    }
  }, 10_000);
});
