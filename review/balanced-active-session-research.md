# Recherche: Balanced-/Active-session-Modus für Android

**Datum:** 2026-10-29

**Frage:** Wie kann Piper während aktiver Agent-Läufe zuverlässig erreichbar bleiben, ohne im Leerlauf einen Foreground-Service und eine permanente WebSocket-Verbindung mit hohem Akkuverbrauch zu betreiben?
**Fokus:** Android-Foreground-Services, Doze, Hintergrundstarts, WorkManager/JobScheduler, Push-Alternativen, Tailscale und belastbare Messung.

## Kurzfazit

Ein **Balanced-/Active-session-Modus ist technisch sinnvoll** und passt zur offiziellen Android-Architektur:

- **Aktive Nutzung:** WebSocket und Echtzeit-Streaming.
- **Aktiver Agent-Lauf im Hintergrund:** Foreground-Service plus WebSocket, weil die laufende Arbeit für den Nutzer sichtbar und relevant ist.
- **Längerer Leerlauf:** Foreground-Service und WebSocket beenden, damit Android und das Netzwerk schlafen können.
- **Erneute Nutzung:** Beim Öffnen oder Netzwerkwechsel sofort verbinden und einen vollständigen Snapshot laden.

Die wichtigste Einschränkung: Ohne Push kann eine schlafende App nicht erfahren, dass am PC ein neuer Lauf beginnt. Der einfache Balanced-Modus funktioniert daher besonders gut für **am Telefon gestartete oder bereits bekannte aktive Läufe**. Für zuverlässiges Aufwecken bei beliebigen neuen Ereignissen ist ein Push-Kanal nötig.

Android beschreibt dieses Modell selbst sehr direkt: WebSockets für Echtzeit im Vordergrund, FCM für zuverlässige Hintergrundnachrichten. Eine eigene Dauerverbindung pro App verbraucht laut Android mehr Akku als eine gemeinsam genutzte Push-Verbindung. Quellen: [Receiving messages reliably](https://developer.android.com/social-and-messaging/guides/communication/receiving-messages), [Doze und App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby).

## 1. Ausgangslage in Piper

Piper besitzt bereits viele Bausteine eines Balanced-Modus:

- **Aktiv-/Lean-Kadenz:** 25 s Protokoll-Ping im aktiven Modus, 90 s im Lean-Modus.
- **Relay-Heartbeat:** 60 s.
- **WebSocket-Backstop:** 240 s.
- **Netzwerkwechsel:** automatische Prüfung und schneller Reconnect.
- **Arbeitszustand:** `RoomInfo.working` liegt bereits pro Raum vor.
- **Ereignisse:** `run_done` und `waiting_for_input` sind bereits vorhanden.
- **Lokale Meldungen:** Abschluss- und Eingabe-Benachrichtigungen existieren.
- **Modi:** `Always`, `When charging` und `Off`.

Relevante Projektdateien:

- `app/lib/data/transport/keep_alive_controller.dart`
- `app/lib/data/transport/connection_manager.dart`
- `app/android/app/src/main/kotlin/ch/pungitore/piper/KeepAliveService.kt`
- `plan/125-battery-and-heat.md`
- `plan/142-keepalive-fgs-timeout.md`

**Entscheidende Lücke:** Der Keep-alive-Controller steuert aktuell den Foreground-Service, aber keinen vollständigen Schlafzustand der Verbindung. Für Balanced reicht `stopForeground()` allein nicht. Auch WebSocket, Ping-Timer und Retry-Schleife müssen im Idle-Zustand beendet oder suspendiert werden.

## 2. Was Android offiziell empfiehlt

### 2.1 WebSocket im Vordergrund, Push im Hintergrund

Die offizielle Messaging-Anleitung nennt WebSockets ausdrücklich für **Foreground real-time messaging**. Für **Background real-time messaging** empfiehlt sie FCM, damit nicht jede App eine eigene persistente Verbindung vorhalten muss.

Quelle: [Android: Receive messages reliably](https://developer.android.com/social-and-messaging/guides/communication/receiving-messages).

**Bedeutung für Piper:** Der WebSocket ist für aktives Chatten und Streaming richtig. Eine dauerhafte Hintergrundverbindung nur für mögliche zukünftige Ereignisse ist dagegen genau der teure Fall, den Android durch Push ersetzt.

### 2.2 Regelmäßige Netzwerkpakete verhindern Energiesparen

Android dokumentiert, dass Netzwerkzugriffe nicht nur Daten kosten. Sie aktivieren CPU und Funk und verlängern deren aktive Zeit. Bereits eine Anfrage alle 15 Sekunden kann das Mobilfunkmodem praktisch dauerhaft aktiv halten.

Quelle: [Android: Minimize the effect of regular updates](https://developer.android.com/develop/connectivity/minimize-effect-regular-updates).

**Bedeutung für Piper:** Die vorhandene Reduktion auf 60-/90-/240- Sekunden-Intervalle hilft. Der größere Gewinn entsteht jedoch, wenn im langen Leerlauf überhaupt keine Verbindung und keine Retry-Schleife mehr läuft.

### 2.3 Foreground-Services sind für bemerkbare Aufgaben

Android beschreibt Foreground-Services für Aufgaben, die der Nutzer auch ohne direkte Interaktion bemerkt und deren Ausführung er erwartet. Die dauerhafte Benachrichtigung macht den Ressourcenverbrauch sichtbar. Android rät ausdrücklich davon ab, einen Foreground-Service nur zur Vermeidung des Idle-Status zu verwenden.

Quellen: [Foreground services overview](https://developer.android.com/develop/background-work/services/fgs), [Doze und App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby).

**Bewertung:** Ein laufender Agent, dessen Abschluss oder Eingabebedarf den Nutzer interessiert, ist ein plausibler zeitlich begrenzter Anwendungsfall. Ein den ganzen Tag inaktiver Relay-Socket ist wesentlich schwächer zu rechtfertigen.

## 3. Empfohlenes Zustandsmodell

### Zustand A: App im Vordergrund

- WebSocket verbunden.
- Kein Foreground-Service nötig.
- Aktive Ping-Kadenz und schnelle Zustandsupdates.
- Voller Rooms-/Presence-Snapshot nach einem Reconnect.

**Warum:** Der Vordergrundprozess besitzt bereits hohe Priorität. Ein zusätzlicher Service erzeugt keinen Nutzen.

### Zustand B: App im Hintergrund, mindestens ein Raum arbeitet

- Foreground-Service läuft.
- WebSocket bleibt verbunden.
- Lean-Kadenz auf Akku, aktive Kadenz beim Laden oder nach Bedarf.
- `run_done` und `waiting_for_input` erzeugen lokale Benachrichtigungen.
- Der Service bleibt aktiv, solange mindestens ein relevanter Raum `working=true` meldet.

**Warum:** Genau hier hat die Dauerverbindung einen konkreten Nutzen: Streaming, Abschlussmeldung und Eingabebedarf während bekannter Arbeit.

### Zustand C: Kein Lauf mehr aktiv, kurze Nachlaufzeit

- Abschluss- oder Eingabe-Benachrichtigung zuerst verarbeiten.
- Foreground-Service und Verbindung für eine kurze konfigurierbare Grace Period behalten.
- Bei einem neuen Lauf die Nachlaufzeit abbrechen und Zustand B fortsetzen.
- Nach Ablauf in Zustand D wechseln.

**Empfehlung:** Mit **5 Minuten** beginnen und den Wert nach Messungen anpassen. Die bisher diskutierten 5–10 Minuten sind ein Produktparameter, keine Android-Vorgabe.

**Warum:** Kurze Folgeereignisse und ein erneuter Blick auf das Ergebnis bleiben komfortabel, ohne stundenlang Ressourcen zu verbrauchen.

### Zustand D: Längerer Leerlauf

- Foreground-Service stoppen.
- WebSocket kontrolliert schließen.
- Ping-, Watchdog- und Retry-Timer suspendieren.
- Pairing, ausgewählten Peer und gecachte Rooms behalten.
- Kein periodischer Reconnect nur zur Präsenzanzeige.

**Warum:** Nur dieser Zustand beseitigt die wiederkehrenden CPU- und Funkaktivitäten wirklich.

### Rückkehr aus dem Leerlauf

- Beim Öffnen sofort mit zurückgesetztem Backoff verbinden.
- Presence, Rooms und aktuellen Chatzustand vollständig abgleichen.
- Nach einem Netzwerkwechsel nur dann automatisch verbinden, wenn die App nicht bewusst schläft oder ein Wake-Ereignis vorliegt.

**Warum:** Der Nutzer erhält beim Öffnen schnell einen korrekten Zustand, ohne dass die App zwischendurch dauerhaft online bleibt.

## 4. Die kritische Grenze: neue Läufe am PC

Ohne Push existiert im Zustand D kein Kommunikationsweg zum Telefon. Beginnt am PC ein neuer Agent-Lauf, kann Piper davon erst nach einem Öffnen, einem geplanten Sync oder einem Push erfahren.

Auch ein bereits empfangenes `working=true` löst nicht automatisch alle Android-Probleme:

- Ab Android 12 darf eine App im Hintergrund nicht grundsätzlich einen Foreground-Service starten.
- Ausnahmen existieren unter anderem bei sichtbarer Nutzerinteraktion, bestimmten Benachrichtigungsaktionen, High-priority-FCM und deaktivierter Akkuoptimierung.
- Ein normaler WebSocket-Callback im Hintergrund ist in der offiziellen Liste keine allgemeine Ausnahme.

Quelle: [Restrictions on starting a foreground service from the background](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start).

**Designfolge:**

- Ein Balanced-Modus ohne Push sollte den Service beim Übergang in den Hintergrund starten, wenn zu diesem Zeitpunkt Arbeit aktiv ist oder die Nachlaufzeit läuft.
- Ein später neuer Lauf nach vollständigem Idle-Schlaf ist ohne Push nicht garantiert.
- Der Modus sollte dies in der UI klar als **„Bei aktiven Läufen verbunden“** und nicht als **„Immer benachrichtigen“** beschreiben.

## 5. Android-Limits, die die Implementierung betreffen

### 5.1 `dataSync`: 6 Stunden innerhalb von 24 Stunden

Für Apps mit Ziel Android 15 oder höher begrenzt Android `dataSync`- und `mediaProcessing`-Foreground-Services auf insgesamt 6 Stunden innerhalb von 24 Stunden. Danach ruft das System `Service.onTimeout()` auf. Der Service muss sich innerhalb weniger Sekunden beenden, sonst erzeugt das System einen schweren Fehler. Erst ein erneuter Vordergrundbesuch des Nutzers erlaubt danach wieder einen Start.

Quelle: [Foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout).

**Für Piper:**

- `KeepAliveService` verwendet aktuell `FOREGROUND_SERVICE_TYPE_DATA_SYNC`.
- Ein Balanced-Modus reduziert den Verbrauch dieses Zeitbudgets deutlich.
- Sehr lange Agent-Läufe können das Limit trotzdem erreichen.
- `onTimeout()` sollte unabhängig vom neuen Modus implementiert und getestet werden.

Android stellt dafür Testbefehle bereit, unter anderem:

```text
adb shell am compat enable FGS_INTRODUCE_TIME_LIMITS <package>
adb shell device_config put activity_manager data_sync_fgs_timeout_duration <milliseconds>
```

### 5.2 `remoteMessaging` und `connectedDevice` sind keine Akku-Fixes

Android beschreibt `remoteMessaging` für die Übertragung von Textnachrichten zwischen Geräten und für die Kontinuität von Messaging-Aufgaben. `connectedDevice` deckt Interaktionen mit externen Geräten unter anderem über Netzwerk oder lokale Internetverbindung ab. Die Timeout-Seite nennt die 6-Stunden-Regel aktuell nur für `dataSync` und `mediaProcessing`.

Quellen: [Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types), [Foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout).

**Bewertung:** Piper könnte die semantische Eignung dieser Typen für seinen Nachrichtenverkehr oder den PC im LAN prüfen. Ein Wechsel wäre jedoch keine Energieoptimierung. Die Dokumentation garantiert nicht, dass jede Remote-Agent-Anwendung diese Typen verwenden darf. Eignung und gegebenenfalls Store-Regeln müssten separat validiert werden, statt den Typ nur zur Umgehung des Zeitlimits zu wechseln.

### 5.3 Akkuoptimierungs-Ausnahme ist keine vollständige Freischaltung

Eine von Doze ausgenommene App darf laut Android weiterhin Netzwerk und partielle Wake Locks verwenden. Andere Einschränkungen bleiben bestehen. Diese Ausnahme erlaubt außerdem Hintergrundstarts von Foreground-Services, bedeutet aber nicht null Akkuverbrauch.

Quellen: [Doze und App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby), [FGS-Hintergrundstarts](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start).

**Bewertung:** „Unrestricted“ sollte im Balanced-Modus nicht Voraussetzung sein. Es kann optional die Zuverlässigkeit erhöhen, reproduziert aber gerade den aggressiven Energiepfad, der vermieden werden soll.

## 6. WorkManager, JobScheduler und UIDT

### WorkManager

WorkManager eignet sich für unterbrechbare und verschiebbare Aufgaben. Periodische Arbeit hat ein minimales Intervall von 15 Minuten und kann durch Doze verzögert werden. Lang laufende Worker verwenden intern ebenfalls einen Foreground-Service und erben dessen Einschränkungen.

Quellen: [Long-running workers](https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/long-running), [Data transfer options](https://developer.android.com/develop/background-work/background-tasks/data-transfer-options), [Work requests](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work).

**Fazit:** Kein Ersatz für einen interaktiven WebSocket während eines aktiven Laufs. Sinnvoll als sparsamer Fallback für gelegentliche Snapshot-Synchronisation.

### User-Initiated Data Transfer Jobs

UIDT-Jobs sind für längere, ausdrücklich vom Nutzer gestartete Datenübertragungen vorgesehen. Sie starten sofort, benötigen eine Benachrichtigung und unterliegen nicht den normalen App-Standby-Jobquoten. Das System kann sie trotzdem aus Systemgesundheitsgründen oder bei zu langer Ausführung beenden.

Quellen: [User-initiated data transfer](https://developer.android.com/develop/background-work/background-tasks/uidt), [FGS-Änderungen](https://developer.android.com/develop/background-work/services/fgs/changes).

**Fazit:** Interessant für einen klar abgegrenzten Upload oder Download. Für einen dauerhaften bidirektionalen Chat-/Agent-Stream ist dies nicht die dokumentierte Zielanwendung.

### Android 16

Auf Android 16 müssen auch Jobs, die während eines Foreground-Services laufen, ihre normalen Runtime-Quoten einhalten. UIDT-Jobs sind von den normalen Jobquoten ausgenommen.

Quelle: [Changes to foreground services](https://developer.android.com/develop/background-work/services/fgs/changes).

**Fazit:** Ein Design, das WorkManager nur als Umgehung der FGS-Regeln einsetzt, wird nicht robuster.

## 7. Push als Ergänzung, nicht als WebSocket-Ersatz

### FCM

Android und Firebase empfehlen High-priority-Nachrichten für zeitkritische, nutzerseitig sichtbare Ereignisse. Solche Nachrichten können Doze durchbrechen und kurz Netzwerkzugriff sowie Verarbeitung ermöglichen. Die Verarbeitungszeit ist für eine Benachrichtigung und begrenzte Folgearbeit gedacht, nicht für einen dauerhaften Stream.

Quellen: [Android: Doze und App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby), [FCM message priority](https://firebase.google.com/docs/cloud-messaging/android-message-priority).

**Geeignete Piper-Ereignisse:**

- `run_done`
- `waiting_for_input`
- neuer Lauf, falls das Telefon darüber erneut verbinden soll

**Nicht geeignet:** Vollständige Agent-Chunks oder dauerhafte Präsenzupdates. Dafür wird nach dem Aufwecken wieder der WebSocket verwendet. Wiederholte High-priority-Nachrichten ohne sichtbare Nutzerbenachrichtigung können laut Firebase auf normale Priorität herabgestuft werden.

### UnifiedPush als Firebase-freie Variante

UnifiedPush lagert die dauerhafte Verbindung an einen wählbaren Distributor aus. Dadurch muss nicht jede App einen eigenen Hintergrundservice betreiben. Self-hosting wird ausdrücklich unterstützt, und ein offizieller Flutter-Connector ist vorhanden.

Quellen: [UnifiedPush FAQ](https://unifiedpush.org/users/faq/), [UnifiedPush implementations](https://unifiedpush.org/developers/implementations/), [UnifiedPush Android specification](https://unifiedpush.org/developers/spec/android).

Die Android-Spezifikation sieht außerdem einen kurzen Bind-Zeitraum vor, in dem der Distributor die App in den Vordergrund heben kann. Dies kann den Start eines Foreground-Services ohne „Unrestricted“ ermöglichen. Das ist ein Spezifikationsmechanismus, keine Garantie gegen jede OEM-Einschränkung.

**Wichtige Einschränkungen:**

- Der Distributor benötigt selbst eine funktionierende Verbindung.
- Ein selbst gehosteter Push-Endpunkt, der nur über Tailscale erreichbar ist, erbt die Tailscale-Abhängigkeit.
- Push sollte nur ein kleines Wake-Ereignis enthalten. Der eigentliche Zustand wird nach dem Reconnect geladen.
- Die Spezifikation begrenzt eine Push-Nachricht auf 4096 Byte inklusive Verschlüsselung.

## 8. Tailscale als separater Energie- und Zuverlässigkeitsfaktor

Tailscale dokumentiert mobilen Akkuverbrauch als bekanntes Problem. Als häufigste Ursache nennt der Hersteller die Verwendung eines Exit Nodes für den gesamten Verkehr.

Quelle: [Tailscale: Mobile device batteries drain quickly](https://tailscale.com/docs/reference/troubleshooting/mobile/battery-drains).

**Praktische Folge:** Für Piper sollte am Telefon kein Exit Node verwendet werden, wenn nur der Relay im Tailnet benötigt wird. Ein Exit Node leitet den gesamten Internetverkehr um, während normale Tailscale-Nutzung nur Tailnet-Verkehr betrifft. Quelle: [Tailscale: Exit nodes](https://tailscale.com/docs/features/exit-nodes).

Android-Split-Tunneling kann andere Apps vom Tailnet ausschließen. Eine Include-only-Konfiguration nur für Piper erfordert laut Tailscale MDM. Quelle: [Tailscale: Android app-based split tunneling](https://tailscale.com/docs/features/client/android-app-split-tunneling).

**Bewertung:** Der LAN-Endpunkt hilft zu Hause, den Tailscale-Datenpfad zu vermeiden. Er beweist aber nicht, dass der Android-VPN-Dienst selbst keinen Strom verbraucht. Piper und Tailscale müssen deshalb bei der Messung getrennt beobachtet werden.

## 9. Hitze kann auch von aktiver Verarbeitung kommen

Der projekteigene Befund aus `plan/142-keepalive-fgs-timeout.md` zeigt, dass während eines Streams erhebliche Ed25519-Verifizierungskosten und Rückstände auftraten. Der aktuelle Code besitzt bereits einen Hintergrund-Isolate und bevorzugte v2-Verifizierung, verwendet aber weiterhin reine Dart-Kryptographie.

**Bedeutung für den Balanced-Modus:**

- Idle-Schlaf kann den Leerlaufverbrauch deutlich senken.
- Hitze während eines sehr aktiven Streams kann zusätzlich CPU-bedingt sein.
- Ein erfolgreicher Balanced-Modus darf daher nicht nur Ping-Intervalle messen, sondern auch CPU, Krypto-Warteschlangen und UI-Verzögerung.

Diese Projektbeobachtung ist keine allgemeine Web-Behauptung und sollte mit einem erneuten On-device-Profil bestätigt werden.

## 10. Vergleich der realistischen Optionen

| Option | Akku im Idle | Aktive Läufe | Neuer PC-Lauf im Idle | Aufwand | Bewertung |
|---|---:|---|---|---|---|
| `Always` | Schlecht | Sehr gut | Gut | Vorhanden | Nur für maximale Dauererreichbarkeit |
| `When charging` | Gut auf Akku | Nur eingeschränkt | Nicht zuverlässig | Vorhanden | Derzeit bester einfacher Kompromiss |
| **Balanced ohne Push** | Sehr gut | Gut für bekannte Läufe | Nicht garantiert | Mittel | **Empfohlener erster Schritt** |
| **Balanced plus Push** | Sehr gut | Sehr gut | Gut | Hoch | **Beste langfristige Architektur** |
| WorkManager-Polling | Gut | Verzögert | Verzögert | Mittel | Nur Fallback, kein Echtzeitkanal |
| UIDT-Job | Mittel | Für endliche Transfers | Nutzerstart nötig | Hoch | Kein passender Chat-Ersatz |
| Anderer FGS-Typ | Unverändert | Unverändert | Unverändert | Klein | Kein Akku-Fix |

## 11. Konkrete Empfehlung

### Phase 1: Balanced ohne neue Infrastruktur

Einen vierten Modus **Balanced / Active sessions** einführen:

- Beim Hintergrundwechsel nur bei aktivem Lauf oder laufender Grace Period verbinden bleiben.
- `working` über alle sichtbaren Räume aggregieren.
- Nach dem letzten Abschluss zunächst 5 Minuten Nachlaufzeit.
- Danach Service, WebSocket und alle Retry-/Ping-Pfade gemeinsam suspendieren.
- Beim Öffnen sofort reconnecten und vollständig synchronisieren.
- In den Einstellungen klar erklären: **„Neue PC-Läufe werden im tiefen Idle nur nach dem Öffnen erkannt.“**

**Warum zuerst:** Diese Variante nutzt vorhandene Ereignisse und löst den größten Idle-Verbrauch ohne Push-Server oder Relay-Protokolländerung.

### Phase 2: Wake-Ereignisse

Push nur für seltene, nutzerrelevante Ereignisse ergänzen:

- Abschluss
- Eingabe erforderlich
- optional neuer Lauf

UnifiedPush ist die naheliegende Firebase-freie Variante. FCM bleibt die von Android am stärksten dokumentierte Standardlösung. Die Auswahl sollte separat entschieden werden, weil sie Infrastruktur, Datenschutz und Vertrieb betrifft.

### Phase 3: Aktive Last optimieren

Falls das Telefon vor allem während laufender Streams heiß wird:

- CPU- und Krypto-Profile während identischer Läufe vergleichen.
- Native Ed25519-Prüfung oder weitere Reduktion doppelter Signaturarbeit bewerten.
- Keine kürzeren Heartbeats als Reaktion einführen.

## 12. Mess- und Abnahmeplan

### Funktionale Fälle

1. **Telefonstart:** Lauf am Telefon starten, App in den Hintergrund, Abschlussmeldung muss ankommen.
2. **Grace Period:** Nach Abschluss darf der Service erst nach Ablauf stoppen.
3. **Idle:** Nach Ablauf keine WebSocket-Verbindung, keine Ping- oder Retry-Aktivität.
4. **Resume:** Beim Öffnen sofortiger Reconnect und korrekter Rooms-/Chat-Snapshot.
5. **Mehrere Räume:** Service läuft, solange mindestens ein Raum arbeitet.
6. **PC-Start im tiefen Idle:** In Phase 1 als dokumentierte Einschränkung prüfen, in Phase 2 per Push.
7. **Netzwerkwechsel:** Aktiver Lauf überlebt WLAN-/Mobilfunkwechsel; Idle bleibt ohne unnötige Verbindung.
8. **Android-Timeout:** `onTimeout()` mit verkürztem Testlimit prüfen.
9. **Doze:** Mit `adb shell dumpsys deviceidle force-idle` testen.

### A/B-Messung

Unter möglichst gleichen Bedingungen **Always** und **Balanced** vergleichen:

- Gleiches Telefon und ähnlicher Akkustand.
- Gleiches Netz und vergleichbare Signalstärke.
- Gleicher Exit-Node-/Tailscale-Zustand.
- Getrennte Szenarien für 30 Minuten Idle und einen aktiven Stream.
- Piper und Tailscale getrennt in den Android-Akkustatistiken prüfen.

Offizieller Messablauf:

```text
adb shell dumpsys batterystats --reset
# Telefon trennen, Szenario auf Akku ausführen
adb shell dumpsys batterystats > batterystats.txt
adb bugreport bugreport.zip
```

Quelle: [Android: Batterystats and Battery Historian](https://developer.android.com/topic/performance/power/setup-battery-historian).

Battery Historian kann CPU, Wake Locks, Services, Jobs und mobile Funkaktivität zeigen. Die Aktivitätsbalken belegen nicht allein den exakten Stromverbrauch eines Bauteils. Deshalb Akkuverlauf, App-Statistiken und Aktivitätsdaten gemeinsam auswerten. Quelle: [Analyze power use with Battery Historian](https://developer.android.com/topic/performance/power/battery-historian).

Auf unterstützten Pixel-Geräten kann der Power Profiler zusätzlich Geräte-Leistungsschienen wie WLAN darstellen. Diese Werte sind gerätebezogen und nicht einer einzelnen App zugeordnet. Quelle: [Android Studio Power Profiler](https://developer.android.com/studio/profile/energy-profiler).

Für die Korrelation sollte Piper während der Messung FGS-Zeit, Socket-Laufzeit, Ping-Anzahl und übertragene Bytes, Reconnects sowie tatsächliche Agent-Laufzeit protokollieren.

## Endurteil

**Der Balanced-/Active-session-Modus ist der richtige Mittelweg.** Er sollte nicht nur den Foreground-Service zeitlich begrenzen, sondern einen echten Verbindungsschlaf einführen. Die einfache Version deckt bekannte und am Telefon gestartete Läufe ab. Für neue Ereignisse während tiefem Idle ist Push die technisch saubere Ergänzung.

Der wichtigste verbleibende Produktentscheid ist daher nicht „25 oder 90 Sekunden Ping“, sondern: **Soll Piper nach längerem Idle überhaupt selbständig über neue PC-Ereignisse erfahren?** Wenn ja, ist ein Wake-Kanal erforderlich.
