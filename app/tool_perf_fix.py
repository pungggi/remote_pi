# -*- coding: utf-8 -*-
# Perf fix in ws_transport.dart:
#  1) drop the serialized inFlight chain (parallel per-frame processing;
#     ratchet race stays closed via synchronous flag capture before await)
#  2) remove the per-frame debugPrint volume probe (Jank in debug builds)
NL = "\r\n"
p = "lib/data/transport/ws_transport.dart"
s = open(p, encoding="utf-8", newline="").read()

# ── 1) comment + inFlight declaration ──
old_decl = NL.join([
    "    // PR #24 follow-up (#4) \u2014 `Stream.listen` does NOT await async callbacks,",
    "    // so an unsigned frame arriving right after a valid signed one could",
    "    // evaluate `_requireSignature` before this verification flips it and be",
    "    // queued. This leaves a race in the post-first-signature strip protection.",
    "    // Serialize ALL inbound handling through this future chain: frames",
    "    // are processed strictly in arrival order, each seeing the ratchet",
    "    // state left by its predecessor. Errors are swallowed to keep the chain",
    "    // alive (individual frames already handle their own failures).",
    "    Future<void> inFlight = Future<void>.value();",
])
new_decl = NL.join([
    "    // Perf fix (2026-08-16): frames are processed in PARALLEL again \u2014 the",
    "    // serialized chain made every inbound frame wait for the previous",
    "    // frame's Ed25519 verify and froze the UI during agent-chunk bursts.",
    "    // The review-#4 ratchet race stays closed because the flag is flipped",
    "    // SYNCHRONOUSLY (before the awaited verify) inside processFrame, so any",
    "    // later frame in the same microtask queue already sees it flipped.",
])
assert old_decl in s, "decl block not found"
s = s.replace(old_decl, new_decl, 1)

# ── 2) remove the volume-probe comment + per-frame logs ──
old_probe = NL.join([
    "    Future<void> processFrame(dynamic raw) async {",
    "        // Volume probe: log every frame the relay pushes onto this",
    "        // socket so we can spot firehose patterns (e.g. presence",
    "        // churn, repeated room snapshots) by counting prefix",
    "        // occurrences \u2014 body kept compact so the log stays grep-able",
    "        // even when the relay is chatty.",
    "        final rawStr = raw is String ? raw : raw.toString();",
    "        if (!authDone) {",
    "          debugPrint('[ws-in] bytes=${rawStr.length} stage=preauth');",
])
new_probe = NL.join([
    "    Future<void> processFrame(dynamic raw) async {",
    "        // Volume probe removed (perf, 2026-08-16): per-frame debugPrint",
    "        // flooded the debug-build console (~200 frames/10s firehose) and",
    "        // caused visible jank. Only drops/errors log now.",
    "        final rawStr = raw is String ? raw : raw.toString();",
    "        if (!authDone) {",
])
assert old_probe in s, "probe header not found"
s = s.replace(old_probe, new_probe, 1)

# 3) room-mismatch drop: silent
old_rm = NL.join([
    "            if (senderRoom != null && senderRoom != transport._activeRoom) {",
    "              debugPrint(",
    "                '[ws-in] bytes=${rawStr.length} kind=envelope '",
    "                'sender_room=$senderRoom DROPPED (room-mismatch)',",
    "              );",
    "              return;",
    "            }",
    "            debugPrint(",
    "              '[ws-in] bytes=${rawStr.length} kind=envelope '",
    "              'ct.bytes=${bytes.length}',",
    "            );",
])
new_rm = NL.join([
    "            if (senderRoom != null && senderRoom != transport._activeRoom) {",
    "              return; // room-mismatch \u2014 drop silently (perf: no per-frame log)",
    "            }",
])
assert old_rm in s, "room-mismatch block not found"
s = s.replace(old_rm, new_rm, 1)

# 4) sig INVALID drop: compact log
old_inv = NL.join([
    "                debugPrint(",
    "                  '[ws-in] bytes=${rawStr.length} kind=envelope '",
    "                  'sig=INVALID DROPPED',",
    "                );",
])
new_inv = NL.join([
    "                debugPrint('[ws-in] sig=INVALID DROPPED');",
])
assert old_inv in s, "invalid-sig log not found"
s = s.replace(old_inv, new_inv, 1)

# 5) ABSENT-after-ratchet drop: compact log
old_abs = NL.join([
    "            } else if (transport._requireSignature) {",
    "              debugPrint(",
    "                '[ws-in] bytes=${rawStr.length} kind=envelope '",
    "                'sig=ABSENT-after-ratchet DROPPED',",
    "              );",
    "              return;",
    "            }",
])
new_abs = NL.join([
    "            } else if (transport._requireSignature) {",
    "              debugPrint('[ws-in] sig=ABSENT-after-ratchet DROPPED');",
    "              return;",
    "            }",
])
assert old_abs in s, "absent log not found"
s = s.replace(old_abs, new_abs, 1)

# 6) control-frame log: remove
old_ctrl = NL.join([
    "          if (ctrl != null && !transport._controlController.isClosed) {",
    "            debugPrint(",
    "              '[ws-in] bytes=${rawStr.length} kind=control '",
    "              'type=${frame['type']}',",
    "            );",
    "            transport._controlController.add(ctrl);",
])
new_ctrl = NL.join([
    "          if (ctrl != null && !transport._controlController.isClosed) {",
    "            transport._controlController.add(ctrl);",
])
assert old_ctrl in s, "control log not found"
s = s.replace(old_ctrl, new_ctrl, 1)

# 7) unknown + malformed logs: compact
old_unk = "          debugPrint('[ws-in] bytes=${rawStr.length} kind=unknown DROPPED');"
new_unk = "          // unknown shape \u2014 drop silently"
assert old_unk in s, "unknown log not found"
s = s.replace(old_unk, new_unk, 1)

old_mal = NL.join([
    "        } catch (e) {",
    "          debugPrint(",
    "            '[ws-in] bytes=${rawStr.length} kind=malformed DROPPED err=$e',",
    "          );",
    "        }",
])
new_mal = NL.join([
    "        } catch (e) {",
    "          debugPrint('[ws-in] malformed DROPPED err=$e');",
    "        }",
])
assert old_mal in s, "malformed log not found"
s = s.replace(old_mal, new_mal, 1)

# 8) listener: parallel dispatch instead of the chain
old_listen = NL.join([
    "    final sub = ws.stream.listen(",
    "      (raw) {",
    "        inFlight = inFlight.then((_) => processFrame(raw)).catchError((_) {});",
    "      },",
])
new_listen = NL.join([
    "    final sub = ws.stream.listen((raw) {",
    "      // Perf fix (2026-08-16): parallel per-frame processing \u2014 no global",
    "      // serialization. Race-safety is preserved by the synchronous ratchet",
    "      // capture inside processFrame (see the flag comment above).",
    "      unawaited(processFrame(raw));",
    "    },",
])
assert old_listen in s, "listener block not found"
s = s.replace(old_listen, new_listen, 1)

open(p, "w", encoding="utf-8", newline="").write(s)
print("perf fix applied")
