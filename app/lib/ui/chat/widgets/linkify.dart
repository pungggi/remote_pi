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

/// Strips trailing prose punctuation (`.`, `,`, `;`, `:`, `!`, `?`) and one
/// unmatched `)` from a raw [urlRegExp] match, returning the cleaned URL and
/// the peeled-off trailing text. Used by both the Markdown autolinker and the
/// plain-text linkifier so they agree on what counts as the link target.
///
/// A stray `)` is only peeled when it is the actual last character — never a
/// mid-URL one — so `https://x.com/)path` is left intact rather than wrongly
/// truncated.
({String url, String trailing}) peelUrl(String match) {
  var end = match.length;
  const trailingPunct = '.,;:!?';
  while (end > 0 && trailingPunct.contains(match[end - 1])) {
    end--;
  }
  // Drop a trailing ')' only when the parens in the remainder are unbalanced
  // AND the last char really is a ')' (e.g. prose "(see https://x.com)"),
  // never a stray ')' that sits mid-URL.
  var depth = 0;
  for (var i = 0; i < end; i++) {
    final c = match[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    }
  }
  if (depth < 0 && end > 0 && match[end - 1] == ')') {
    end--;
  }
  return (url: match.substring(0, end), trailing: match.substring(end));
}

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
