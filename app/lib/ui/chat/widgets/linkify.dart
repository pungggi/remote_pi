import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Matches a bare HTTP(S) URL anywhere in free text.
///
/// Stops at whitespace and at characters that start Markdown inline syntax
/// (backtick, `*`, `[`, `]`, `<`, `>`, `"`) so it never swallows emphasis, code
/// spans or link syntax that follows a URL without an intervening space.
/// Parentheses ARE allowed (Wikipedia-style `wiki/Foo_(bar)`); a trailing `)`
/// that is just prose punctuation is peeled off by the caller.
final RegExp urlRegExp = RegExp('https?://[^\\s*<>\\[\\]"\u0060]+');

/// Opens [url] in the system browser, surfacing a SnackBar on failure.
///
/// Safe to call from a tap handler: the [ScaffoldMessenger] is captured
/// *before* the async [launchUrl], so [context] is never used across an await.
Future<void> openUrl(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
    }
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
  }
}
