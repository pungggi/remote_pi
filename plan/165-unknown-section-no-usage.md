# Plan 165 — Unknown provider section shows no usage

## Context

Plan/161 made the provider header the single place a subscription quota is
shown (`5h x% · wk y%` + bar + ⏳). Device verification of 1.6.x exposed one
rough edge: sessions from **pre-161 extensions** publish no `provider` field,
so they land in the **Unknown provider** fallback section — and that section
was happy to display the quota of whatever provider one of its online items
happened to carry.

Result: the same z.ai quota appeared on **two** headers. Worse, it is
semantically wrong: the fallback section mixes providers, so no single
account quota can be attributed to it.

## Decision

Suppress usage entirely on the fallback section:

- `HomeViewModel.planUsageForSection` returns `null` when
  `section.isFallback` — no quota text, no bar, no ⏳, and no 🔄 redeem chip
  (the chip is already gated on usage being non-null).
- Real provider sections are untouched: the first ONLINE session still
  speaks for the whole section.

Why the VM and not the pure grouping helper: `firstOnlinePlanUsage` stays a
generic primitive; the fallback rule is Home-header policy.

## Steps

1. VM guard + doc comment. **Acceptance**: analyze clean (no new issues).
2. VM test: z.ai online session with usage → header lit; legacy online
   session carrying the same usage object → fallback header stays dark.
   **Acceptance**: `flutter test test/ui/home` green.

## DoD

- [x] Guard in `planUsageForSection`
- [x] VM test pins both sides of the rule
- [x] Shipped in 1.6.3; verified on device (fallback header dark)

## Next plans

- When all sessions run a ≥161 extension the fallback section disappears
  naturally; no migration needed.
