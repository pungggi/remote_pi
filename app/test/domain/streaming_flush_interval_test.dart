import 'package:app/domain/session_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('streaming flush cadence adapts to the buffered response length', () {
    expect(streamingFlushIntervalMs(0), 16);
    expect(streamingFlushIntervalMs(49999), 16);
    expect(streamingFlushIntervalMs(50000), 50);
    expect(streamingFlushIntervalMs(99999), 50);
    expect(streamingFlushIntervalMs(100000), 100);
    expect(streamingFlushIntervalMs(200000), 100);
  });
}
