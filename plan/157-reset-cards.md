# Plan 157 — z.ai Quota Reset Cards (Anzeige + bestätigter Button)

## Context

Plan/156 zeigt die z.ai-Abonnement-Quota im Home-Model-Group-Header. z.ai
verteilt zusätzlich **Quota Reset Cards** (5h / weekly; Kampagnen-Benefit).
Der Dashboard-Button zum Einlösen existiert; die (undokumentierte) API wurde
verifiziert (GLMeter-kompatibel, s. crazykun/glm-reset-card):

- `GET  /api/biz/customer-package-reset/list?targetType=PERSONAL`
  → `{fiveHourResets:[{recordId,available,expireTime}...], weekResets:[...]}`
- `POST /api/biz/customer-package-reset/use`
  body `{targetType:"PERSONAL", resetType:"WEEK"|"FIVE_HOUR", recordId, requestId}`
  (`requestId` = Idempotency-Key; Weekly-Reset stellt laut FAQ auch das
  5h-Fenster wieder her.)

**HARD RULE (user, 2026-11-02):** Der Einlöse-POST wird **niemals** vom Agent
/ dev-Shell ausgeführt — nur durch den eingebauten App-Button nach expliziter
Nutzerbestätigung. Read-only-Liste darf dev-seitig gerufen werden.

## UX (user-spezifiziert)

- Button (Chip `🔄×N`) erscheint **nur** wenn das betroffene Fenster
  aufgebraucht ist (`percent >= 100`) UND Karten dieses Typs verfügbar sind.
- Priorität: weekly-Chip wenn weekly ≥ 100 (stellt beides her); sonst 5h-Chip
  wenn 5h ≥ 100.
- Tap → expliziter Bestätigungsdialog (destruktiver Stil, Abbrechen default);
  erst Confirm sendet den Befehl.
- Ergebnis als Snackbar; der Header heilt über den force-probe des Extensions.

## Design

### Extension (pi-extension)

- `plan-usage.ts`: `fetchResetCards(key)` (read-only) → Counts + frühestes
  Ablaufdatum pro Typ;_failt still → Feld fehlt. In den `plan_usage`-Blob als
  `resetCards:{fiveHour:{count,earliestExpire?},week:{...}}`. `_samePlanUsage`
  vergleicht die Counts mit (Republish bei Kartenverbrauch/Grant).
- `redeemResetCard(key, kind)`: frische Liste → früheste verfügbare Karte des
  Typs → POST mit frischem `randomUUID()`-requestId. **Kein Auto-Retry.**
  Gibt `{ok, remaining, error?}`.
- `main.ts` `_routeClientMessageFrom`: neuer case `plan_reset_card`
  `{type,id,kind}`. Guards: `ext.pi` vorhanden, single-flight, Provider=zai
  (sonst error-reply). Danach reply
  `{type:"plan_reset_result",in_reply_to,ok,kind,remaining,message?}` und
  `_voidMaybePublishPlanUsage({force:true})`.
- `protocol/types.ts`: ClientMessage-Union + Reply-Typ.

### App

- `protocol.dart`: `PlanUsage.resetCards` (Typ `ResetCardInventory`), Parse +
  `PlanResetCard` ClientMessage + `PlanResetResult` ServerMessage.
- Gruppierung: Quelle der Usage (das erste ONLINE Item) mitführen, damit der
  Button weiß, an welchen Peer/Room der Befehl geht.
- `SessionGroupHeader`: Chip (siehe UX); Tap-Callback → ViewModel öffnet
  Dialog → senden über den Channel des Sessions (wie `cancel`: sync_service /
  channel nach targetId), Antwort via `in_reply_to`-Korrelation → Snackbar.
- Relay: **keine Änderung** (ClientMessage-Typen laufen opaquely).

## Steps

1. Extension: fetchResetCards + Merge + Dedupe + Tests (gemocktes fetch; nie
   echtes Netz).
2. Extension: redeemResetCard + plan_reset_card-Handler + Reply + Tests
   (single-flight, no-card, provider≠zai, korrekter POST-Body, requestId
   einmalig, force-probe danach).
3. App: Protokoll (ResetCardInventory, PlanResetCard, PlanResetResult) +
   Tests.
4. App: Header-Chip + Dialog + Send/Reply/Snackbar + Tests (Sichtbarkeit nur
   bei ≥100+Karten, weekly-Priorität, Cancel sendet nichts).
5. Changelogs; Release-Flow wie 1.5.x (PR → tag app-vX → CI → adb install).

## DoD

- [ ] Chip erscheint ausschließlich bei erschöpftem Fenster + verfügbarer Karte
- [ ] Kein Send ohne explizite Confirm-Dialog-Bestätigung
- [ ] Extension redeemet nie von selbst (keine Timer/Schwellen)
- [ ] recordId wählt immer die Extension (frisch, frühester Ablauf), nie die App
- [ ] requestId UUID pro Versuch, kein Retry
- [ ] Tests grün (ext + app), analyze/typecheck clean
- [ ] On-device review

## Next plans

- Weitere Provider im Reset-Card-Registrierungs-Muster (falls je existent).
