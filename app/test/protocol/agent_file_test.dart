// Plan/126 - wire parsing of the `agent_file` ServerMessage (the document the
// agent pushes to the user via the `show_file` tool: markdown/text/pdf/html).

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

    test('kinds text/pdf/html all dispatch to AgentFile', () {
      for (final kind in ['text', 'pdf', 'html', 'markdown']) {
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
  });
}
