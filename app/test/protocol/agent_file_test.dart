// Plan/126 - wire parsing of the `agent_file` ServerMessage (the document the
// agent pushes to the user via the `show_file` tool: markdown/text/pdf/html,
// plus mermaid since plan/144).

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('agent_file ServerMessage', () {
    test('parses all fields (markdown)', () {
      final m = ServerMessage.fromJson({
        'type': 'agent_file',
        'id': 'doc_1',
        'in_reply_to': 'turn_9',
        'kind': 'markdown',
        'data': 'IyBIZWxsbw==', // "# Hello"
        'mime': 'text/markdown',
        'path': 'README.md',
        'caption': 'the readme',
        'size': 8,
        'allow_network': false,
      });
      final f = m as AgentFile;
      expect(f.id, 'doc_1');
      expect(f.inReplyTo, 'turn_9');
      expect(f.kind, 'markdown');
      expect(f.data, 'IyBIZWxsbw==');
      expect(f.mime, 'text/markdown');
      expect(f.path, 'README.md');
      expect(f.caption, 'the readme');
      expect(f.size, 8);
      expect(f.allowNetwork, isFalse);
    });

    test('in_reply_to/caption/size/allow_network are optional; kind+data required', () {
      final f = ServerMessage.fromJson({
        'type': 'agent_file',
        'id': 'doc_2',
        'kind': 'pdf',
        'data': 'JVBERi0=', // "%PDF-"
      }) as AgentFile;
      expect(f.inReplyTo, '');
      expect(f.caption, isNull);
      expect(f.size, isNull);
      expect(f.allowNetwork, isFalse); // default sandboxed
      expect(f.mime, isNull);
    });

    test('allow_network=true survives the round-trip (HTML online mode)', () {
      final f = ServerMessage.fromJson({
        'type': 'agent_file',
        'id': 'doc_3',
        'kind': 'html',
        'data': 'PHNjcmlwdD48L3NjcmlwdD4=',
        'allow_network': true,
      }) as AgentFile;
      expect(f.kind, 'html');
      expect(f.allowNetwork, isTrue);
    });

    test('kinds text/pdf/html/markdown/mermaid all dispatch to AgentFile', () {
      for (final kind in ['text', 'pdf', 'html', 'markdown', 'mermaid']) {
        final m = ServerMessage.fromJson({
          'type': 'agent_file',
          'id': 'doc_$kind',
          'kind': kind,
          'data': 'AA==',
        });
        expect(m, isA<AgentFile>(), reason: 'kind=$kind');
        expect((m as AgentFile).kind, kind);
      }
    });

    // Plan/158 — new extensions never send agent_file inline; the parser
    // stays tolerant so a mid-rollout legacy frame with no bytes still parses.
    test('agent_file without data parses with data null (forward tolerance)', () {
      final f = ServerMessage.fromJson({
        'type': 'agent_file',
        'id': 'doc_nodata',
        'kind': 'markdown',
      }) as AgentFile;
      expect(f.data, isNull);
      expect(f.kind, 'markdown');
    });
  });

  group('plan/158 agent_file_ref', () {
    test('parses the metadata-only live frame', () {
      final m = ServerMessage.fromJson({
        'type': 'agent_file_ref',
        'id': 'af_1',
        'in_reply_to': 'turn_1',
        'file_id': 'af_1',
        'ts': 1700000000000,
        'kind': 'pdf',
        'mime': 'application/pdf',
        'name': 'report.pdf',
        'bytes': 12582912,
        'caption': 'Q3 report',
        'allow_network': false,
      });
      final r = m as AgentFileRef;
      expect(r.id, 'af_1');
      expect(r.fileId, 'af_1');
      expect(r.ts, 1700000000000);
      expect(r.kind, 'pdf');
      expect(r.mime, 'application/pdf');
      expect(r.name, 'report.pdf');
      expect(r.bytes, 12582912);
      expect(r.caption, 'Q3 report');
      expect(r.allowNetwork, isFalse);
    });

    test('optionals absent: id falls back to file_id, allow_network false', () {
      final r = ServerMessage.fromJson({
        'type': 'agent_file_ref',
        'file_id': 'af_2',
        'kind': 'markdown',
      }) as AgentFileRef;
      expect(r.id, 'af_2');
      expect(r.inReplyTo, '');
      expect(r.ts, isNull);
      expect(r.mime, isNull);
      expect(r.name, isNull);
      expect(r.bytes, isNull);
      expect(r.caption, isNull);
      expect(r.allowNetwork, isFalse);
    });

    // Plan/162 regression (2026-11-07): extensions built before the fix
    // broadcast camelCase `fileId` — the app must still parse (a strict
    // file_id-only read made EVERY card decode-drop silently: no render,
    // ledger hole, permanent replays). And with NEITHER key present the
    // frame is a protocol violation: still throws (decode-drop + counter).
    test('legacy camelCase fileId frame still parses (old extensions)', () {
      final r = ServerMessage.fromJson({
        'type': 'agent_file_ref',
        'id': 'af_3',
        'fileId': 'af_3',
        'kind': 'file',
        'name': 'backup.jwlibrary',
        'bytes': 62367,
      }) as AgentFileRef;
      expect(r.fileId, 'af_3');
      expect(r.id, 'af_3');
      expect(r.kind, 'file');
      expect(r.name, 'backup.jwlibrary');

      // payload + error accept the camel key too.
      final p = ServerMessage.fromJson({
        'type': 'agent_file_payload',
        'fileId': 'af_3',
        'offset': 0,
        'total': 10,
        'data': 'AA==',
        'more': false,
      }) as AgentFilePayload;
      expect(p.fileId, 'af_3');
      final e = ServerMessage.fromJson({
        'type': 'agent_file_error',
        'fileId': 'af_3',
        'code': 'gone',
      }) as AgentFileError;
      expect(e.fileId, 'af_3');
    });

    test('neither file_id nor fileId → still throws (protocol violation)', () {
      expect(
        () => ServerMessage.fromJson({
          'type': 'agent_file_ref',
          'kind': 'markdown',
        }),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('plan/158 agent_file_payload', () {
    test('parses offset/total/data/more', () {
      final p = ServerMessage.fromJson({
        'type': 'agent_file_payload',
        'in_reply_to': 'req_1',
        'file_id': 'af_1',
        'offset': 1048576,
        'total': 2097152,
        'data': 'aGVsbG8=',
        'more': true,
      }) as AgentFilePayload;
      expect(p.inReplyTo, 'req_1');
      expect(p.fileId, 'af_1');
      expect(p.offset, 1048576);
      expect(p.total, 2097152);
      expect(p.data, 'aGVsbG8=');
      expect(p.more, isTrue);
    });

    test('missing offset/total/more degrade to safe defaults', () {
      final p = ServerMessage.fromJson({
        'type': 'agent_file_payload',
        'file_id': 'af_1',
        'data': 'aGVsbG8=',
      }) as AgentFilePayload;
      expect(p.offset, 0);
      expect(p.total, 0);
      expect(p.more, isFalse);
    });
  });

  group('plan/158 agent_file_error', () {
    test('parses the code', () {
      final e = ServerMessage.fromJson({
        'type': 'agent_file_error',
        'in_reply_to': 'req_2',
        'file_id': 'af_1',
        'code': 'changed',
      }) as AgentFileError;
      expect(e.fileId, 'af_1');
      expect(e.code, 'changed');
    });

    test('missing code degrades to unknown', () {
      final e = ServerMessage.fromJson({
        'type': 'agent_file_error',
        'file_id': 'af_1',
      }) as AgentFileError;
      expect(e.code, 'unknown');
    });
  });

  group('plan/158 agent_file_ref history event', () {
    test('SessionHistoryEvent dispatches to AgentFileRefEvt', () {
      final e = SessionHistoryEvent.fromJson({
        'type': 'agent_file_ref',
        'ts': 1700000001000,
        'file_id': 'af_hist',
        'kind': 'markdown',
        'mime': 'text/markdown',
        'name': 'plan.md',
        'bytes': 2048,
        'caption': 'the plan',
      });
      final r = e as AgentFileRefEvt;
      expect(r.ts, 1700000001000);
      expect(r.fileId, 'af_hist');
      expect(r.kind, 'markdown');
      expect(r.mime, 'text/markdown');
      expect(r.name, 'plan.md');
      expect(r.bytes, 2048);
      expect(r.caption, 'the plan');
      expect(r.allowNetwork, isFalse);
    });
  });
}
