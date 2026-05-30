# gptel-send: System-Message aus markierter Section am Dateiende

Kontext- und Entwicklerdokumentation für das Feature „System-Message
Section“ in Org-Dateien. Basis: `mydocs/gptel-send-extension-prompt.md`,
Konzept: `mydocs/gptel-send-extension-concept.md`, Implementierung in
`gptel-org.el` (Fork/Clone unter `/home/alex/git/clones/gptel`).

---

## 1. Ziel (Originalanforderung)

In **Org-Mode** soll `gptel-send` die **System-Message** aus einem
**markierten Section am Ende des Puffers** lesen — nicht aus dem
Konversations-Text.

- `gptel-send` sendet normalerweise nur Inhalt **bis zur Cursorposition**.
- Steht der Cursor **vor** der System-Section, wird deren Text **nicht** als
  User-/Assistant-Nachricht mitgeschickt, sondern als **`system`-Message** ans
  Backend.
- Die Section liegt **immer am Dateiende** (Konvention + Validierung).
- Später: gleiches Prinzip für andere Formate (z. B. Emacs-Lisp mit gültiger
  Syntax); **Phase 1 ist nur Org**.

Mentalmodell: **oben der Chat, unten die Konfiguration** (System-Prompt).

---

## 2. Implementierungsstand (Phase 1 — erledigt)

| Bereich | Status |
|---------|--------|
| Erkennung Begin/End-Marker | `gptel-org--system-section-bounds` |
| System-Text extrahieren | `gptel-org--system-section-message` |
| Vor `gptel-send`: Section prüfen & setzen | `gptel-org--apply-buffer-system-message` |
| Prompt ohne Section-Inhalt | `gptel-org--cap-prompt-end-for-system-section` in `gptel-org--create-prompt-buffer` |
| `GPTEL_SYSTEM` vs. Buffer-Merge | `gptel-org--merge-system-message` |
| Integration `gptel-send` | Advice `gptel-org--send-with-props` |
| Integration `gptel-request` | Advice `gptel-org--request-with-system-section` |
| Log-Hinweis bei Verwendung | `message` + optional `gptel--log` |
| Batch-Tests | `scripts/gptel-org-system-section-tests.el` |
| Emacs-Lisp / andere Modi | **nicht** implementiert |

**Send-Ablauf:**

1. `gptel-send` → `gptel-org--send-with-props`
2. **Zuerst:** `gptel-org--apply-buffer-system-message` — gibt es eine gültige
   System-Section am Dateiende?
   - **Ja** → `gptel--system-message` aus Section; Log-Meldung; Heading-
     `GPTEL_SYSTEM` wird **nicht** für die System-Message verwendet.
   - **Nein** → `gptel-org--merge-system-message` für `GPTEL_SYSTEM` und Buffer;
     sonst Preset/Transient wie bisher.
3. `gptel-request` → Prompt-Buffer (`prompt-end` vor Section-Beginn, wenn
   Cursor davor steht).

---

## 3. Format der System-Section (dateityp-unabhängig)

### Pflicht (reine Textsuche, keine Org-Baumlogik)

- **Begin-Marker** und **End-Marker** als eigene Zeilen (Namen konfigurierbar).
- **Zeilensyntax** (eine Zeile pro Marker, am Zeilenanfang):
  - Org-Property: `:MARKER:` (optional `t` dahinter)
  - Kommentar: `# MARKER`, `; MARKER`, `;; MARKER`, `% MARKER`
- **Erkennung:** Rückwärtssuche vom Dateiende — **letzter** End-Marker, davor
  **letzter** Begin-Marker (unabhängig von Org-Überschriften).
- **System-Text:** nur **zwischen** Begin- und End-Marker-Zeile (Marker-Zeilen
  selbst ausgeschlossen).
- **Dateiende:** Nach der End-Marker-Zeile nur noch Leerzeichen bis
  `point-max` (ein Emacs-`Local Variables'-Trailer am Dateiende ist erlaubt),
  sonst Warnung und Ignorieren (`gptel-org-require-system-section-at-eof`).

Standard-Marker: `GPTEL_SYSTEM_MESSAGE_BEGIN` (Begin),
`GPTEL_SYSTEM_MESSAGE_END` (End).

### Empfohlenes Muster (Org)

```org
* Chat

** User
Hallo, erkläre kurz was Org-Mode ist.

* System prompt
:GPTEL_SYSTEM_MESSAGE_BEGIN: t
Du bist ein hilfreicher Assistent für Org-Mode-Fragen.
Antworte auf Deutsch und knapp.
:GPTEL_SYSTEM_MESSAGE_END: t
```

### Portabel (z. B. Emacs-Lisp, Markdown mit `#`)

```emacs-lisp
;; GPTEL_SYSTEM_MESSAGE_BEGIN
You are a helpful assistant.
;; GPTEL_SYSTEM_MESSAGE_END
```

```markdown
# GPTEL_SYSTEM_MESSAGE_BEGIN
System prompt text.
# GPTEL_SYSTEM_MESSAGE_END
```

### Was **nicht** als Konversations-Text mitgeht

- Der Inhalt zwischen Begin- und End-Marker (wird System-Message)
- Begin-/End-Marker-Zeilen
- Zeilen **oberhalb** des Begin-Markers (z. B. `* System prompt`)

---

## 4. Verhalten bei `gptel-send`

| Situation | Verhalten |
|-----------|-----------|
| Keine markierte Section / nicht am EOF | Wie bisheriges gptel |
| Section am EOF, Cursor **darüber** | System-Message aus Section; Prompt nur bis Cursor, **ohne** Section |
| Cursor **in** der Section | **Fehler:** „Cursor is inside the system-message section…“ |
| Aktive Region schneidet Section | **Fehler:** Region overlaps system-message section |
| Section + `GPTEL_SYSTEM` am Heading | **Section gewinnt** |
| `gptel-rewrite` mit Section am EOF | System-Message = **Section + Rewrite-Directive** |
| Rewrite-Region schneidet Section | **Warnung**, Rewrite läuft ohne
  Buffer-System-Prompt (Overlay-Bounds zählen, nicht veraltete Markierung) |
| `gptel-send` + Region schneidet Section | **Fehler** (wie bisher) |
| Mehrere Section-Paare in der Datei | **Letztes** Paar (vom Ende) zählt |
| Text nach End-Marker (z. B. weiterer Chat) | Ignoriert (Section nicht am EOF) |
| Nur Begin-Marker, kein End-Marker | Ignoriert |

`GPTEL_TOPIC` schränkt den Prompt ein; die System-Section gilt **buffer-weit**
(Konfiguration pro Datei, nicht nur innerhalb des Topics).

---

## 5. Konfiguration (Customize)

| Option | Default | Bedeutung |
|--------|---------|-----------|
| `gptel-org-use-system-section` | `t` | Feature ein/aus |
| `gptel-org-system-section-property` | `"GPTEL_SYSTEM_MESSAGE_BEGIN"` | Begin-Marker-Name |
| `gptel-org-system-section-end-property` | `"GPTEL_SYSTEM_MESSAGE_END"` | End-Marker-Name |
| `gptel-org-require-system-section-at-eof` | `t` | Nur Leerzeichen nach End-Marker |

Es gibt **keine** separate Prioritäts-Option `gptel-org-system-section-priority`
(im Konzept erwähnt, nicht implementiert): Ist eine gültige Section da, setzt
sie die System-Message immer durch.

---

## 6. Relevante Lisp-Funktionen (`gptel-org.el`)

| Funktion | Rolle |
|----------|--------|
| `gptel-org--system-section-bounds` | `(begin-line-beg . end-line-end)` per Rückwärtssuche |
| `gptel-org--system-section-bounds--find` | End-Marker, dann Begin-Marker davor |
| `gptel-org--system-section-marker-regexp` | Org-Property oder Kommentarpräfix |
| `gptel-org--system-section-message` | System-Text als String |
| `gptel-org--apply-buffer-system-message` | Setzt `gptel--system-message`, Log, Fehler bei Cursor in Section; return `t`/`nil` |
| `gptel-org--cap-prompt-end-for-system-section` | Begrenzt `prompt-end` vor Section-Beginn |
| `gptel-org--send-with-props` | Advice um `gptel-send` / `gptel--suffix-send` |
| `gptel-org--request-with-system-section` | Advice um `gptel-request` |
| `gptel-org--suffix-rewrite-with-system-section` | Advice um `gptel--suffix-rewrite` (Bounds-Check) |
| `gptel-org--merge-system-message` | Org-Property vs. Buffer (letzte Änderung gewinnt) |
| `gptel-org--system-message-with-rewrite-directive` | Section + Rewrite-Directive (in `gptel-request`) |
| `gptel-org--rewrite-target-bounds` | Overlay oder Region für Rewrite-Overlap |

Section-Grenzen: plain-text (keine Org-Baumlogik).

---

## 7. Log und Prüfen in Emacs

### Nach dem Senden

Bei Verwendung der Buffer-Section erscheint in **\*Messages\***:

```text
gptel: System message from buffer section (N chars)
```

- Anzeigen: `M-x view-echo-area-messages` oder `C-h e`

### Ausführlicher Log (optional)

```elisp
(setq gptel-log-level 'info)   ;; oder 'debug
```

Dann zusätzlich Eintrag in **\*gptel-log\*** (`gptel--log`, Typ
`system-section`). Im Transient-Menü (`C-u C-c RET`): Logging → **Inspect
Log** (`L`), oder:

```elisp
(pop-to-buffer "*gptel-log*")
```

### Code nach Änderungen laden

Lokaler Emacs-Build: `/home/alex/git/clones/emacs/src/emacs`

```elisp
(add-to-list 'load-path "/home/alex/git/clones/gptel")
(require 'gptel-request)
(require 'gptel)
(load-file "/home/alex/git/clones/gptel/gptel-org.el")
;; Kontext-Befehle (gptel-add, gptel-add-file, Transient-Menü „Context“):
(require 'gptel-context)
```

Nur `gptel-org.el` per `load-file` reicht für `gptel-send` und die
System-Subtree-Logik, **nicht** für `gptel-add`: der Befehl lebt in
`gptel-context.el`. Ohne `(require 'gptel-context)` oder Installation
über ELPA/`package.el` (Autoloads) ist `gptel-add` undefiniert.

Mit `package.el`/`use-package` normalerweise kein Extra-`require`
nötig — Autoloads laden `gptel-context` beim ersten Aufruf von
`gptel-add`.

Kompilieren (Shell):

```bash
/home/alex/git/clones/emacs/src/emacs --batch \
  -L /home/alex/git/clones/gptel \
  -f batch-byte-compile /home/alex/git/clones/gptel/gptel-org.el
```

Tests:

```bash
/home/alex/git/clones/gptel/scripts/run-gptel-org-system-section-tests.sh
```

### Manueller Dry-Run

Org-Buffer mit `gptel-mode`, Cursor über der System-Section:

- `gptel-send` → Meldung in \*Messages\*
- oder Transient → Inspect query / Dry-run, falls konfiguriert

---

## 8. Anleitung: Mit gptel (KI) eine System-Section erzeugen lassen

Ziel: Du chattest in einer **Org-Datei mit `gptel-mode`** und willst, dass das
Modell dir **am Dateiende** die markierte Section einfügt oder umschreibt.

### Voraussetzungen

1. Org-Datei mit aktivem **`gptel-mode`** (`M-x gptel-mode`).
2. Geänderte **`gptel-org.el`** geladen (siehe Abschnitt 7).
3. Cursor **oberhalb** der Stelle, wo die Section hin soll (typisch: im
   Chat-Teil, nicht am Dateiende).

### Prompt-Vorlage (an gptel senden)

Kopiere und passe an — als **User-Nachricht** in den Org-Chat (nicht in die
System-Section selbst):

```text
Erstelle oder aktualisiere am ENDE dieser Org-Datei eine System-Message-Section
für gptel mit genau diesem Aufbau:

1. Neue Überschrift der obersten Ebene (z. B. "* System prompt").
2. Begin-Marker: :GPTEL_SYSTEM_MESSAGE_BEGIN: t
3. System-Prompt-Text (mehrzeilig erlaubt).
4. End-Marker: :GPTEL_SYSTEM_MESSAGE_END: t

Anforderungen an den System-Prompt:
- [HIER: Rolle, Sprache, Stil, Verbote, z. B. "Du bist …", "Antworte auf
  Deutsch", "Kein Code unless asked"]

Wichtig:
- Nach dem End-Marker nur noch Leerzeilen (Section am Dateiende).
- Bestehende Chat-Inhalte oben nicht löschen.
- Marker-Namen exakt wie oben (Begin und End).
- Keine andere Property für die System-Message verwenden.

Wenn schon eine solche Section existiert, ersetze nur deren Prompt-Text und
lass Struktur und Property-Zeile korrekt.
```

### Kürzere Variante

```text
Am Dateiende: "* System prompt", dann :GPTEL_SYSTEM_MESSAGE_BEGIN: t,
Prompt-Text, dann :GPTEL_SYSTEM_MESSAGE_END: t

[HIER DEIN PROMPT]

Nichts am Chat darüber ändern. Nach dem End-Marker nur Leerzeilen.
```

### Nach der KI-Antwort prüfen

1. Datei scrollen: Section wirklich **ganz unten**?
2. Begin- und End-Marker vorhanden und korrekt benannt?
3. Cursor in den **Chat** setzen (über der Section).
4. `gptel-send` (`C-c RET`) → in \*Messages\* muss stehen:
   `gptel: System message from buffer section …`
5. Wenn **keine** Meldung: fehlender End-Marker, Text nach End-Marker, falscher
   Marker-Name, oder `gptel-org-use-system-section` ist `nil`.

### Typische Fehler der KI (korrigieren lassen)

| Problem | Korrektur |
|---------|-----------|
| Chat-Text nach End-Marker | Section ans Dateiende, End-Marker zuletzt |
| Fehlender End-Marker | `:GPTEL_SYSTEM_MESSAGE_END: t` ergänzen |
| Nur `:GPTEL_SYSTEM:` am Heading | Begin/End-Marker + eigene Überschrift unten |
| Falscher Marker-Name (z. B. `GPTEL_SYSTEM`) | Exakte Namen Begin/End laut Tabelle |
| System-Prompt im Chat-Text | In die Section zwischen Begin und End |
| Cursor in Section beim Senden | Cursor nach oben setzen |

### System-Prompt für den Assistenten in der Datei (Beispiel)

```text
Du bist ein Assistent für Org-Mode und gptel in Emacs.
Antworte knapp auf Deutsch.
Wenn der Nutzer eine System-Section anfordert, halte dich strikt an das
Format aus der Dokumentation (Überschrift, Begin-/End-Marker, Section am
Dateiende).
```

(Diesen Text trägst du in die **System-Section** ein — nicht als normale
Chat-Nachricht.)

---

## 9. Tests

**Section (20 ERT-Tests):** `scripts/gptel-org-system-section-tests.el`, Runner
`scripts/run-gptel-org-system-section-tests.sh`, Liste
`gptel-org-system-section--test-names`.

**Merge Org/Buffer:** `scripts/gptel-org-merge-tests.el`, Runner
`scripts/run-gptel-org-merge-regression.sh` (prüft alte vs. neue `gptel-org.el`).

Datei: `scripts/gptel-org-system-section-tests.el`  
Runner: `scripts/run-gptel-org-system-section-tests.sh`  
Alle Tests: Konstante `gptel-org-system-section--test-names` (20 Stück).

| Test | Kurzbeschreibung |
|------|------------------|
| `gptel-org-system-section-bounds` | Begin/End-Marker, Bounds am Dateiende |
| `gptel-org-system-section-message-text` | Text zwischen den Markern |
| `gptel-org-system-section-prompt-excludes-section` | Prompt-Buffer ohne Section |
| `gptel-org-system-section-send-system` | System-Message bei Send oberhalb |
| `gptel-org-system-section-cursor-inside-errors` | Cursor in Section → Fehler |
| `gptel-org-system-section-region-overlap-errors` | Region schneidet Section → Fehler |
| `gptel-org-system-section-overrides-heading-property` | Section vor `GPTEL_SYSTEM` am Heading |
| `gptel-org-system-section-last-section-wins` | Letztes Begin/End-Paar zählt |
| `gptel-org-system-section-nested-outline-ok` | Org-Tiefe irrelevant |
| `gptel-org-system-section-bounds-cached` | Cache bis Buffer-Änderung |
| `gptel-org-system-section-text-after-end-ignored` | Text nach End-Marker → ignoriert |
| `gptel-org-system-section-text-after-end-allowed` | Mit `require-at-eof` nil → erlaubt |
| `gptel-org-system-section-missing-end-ignored` | Nur Begin-Marker → nil |
| `gptel-org-system-section-missing-begin-ignored` | Nur End-Marker → nil |
| `gptel-org-system-section-begin-after-end-ignored` | Begin nach End → nil |
| `gptel-org-system-section-comment-markers-hash` | `#`-Kommentarzeilen |
| `gptel-org-system-section-comment-markers-semicolon` | `;;`-Kommentarzeilen |
| `gptel-org-system-section-rewrite-system-combined` | Section + Rewrite-Directive |
| `gptel-org-system-section-rewrite-region-overlap-warns` | Rewrite-Overlap → Warnung |
| `gptel-org-system-section-rewrite-ignores-stale-region` | Overlay statt veralteter Region |

---

## 10. Geplante Weiterentwicklung (noch offen)

Aus Konzept/Prompt, **nicht** umgesetzt:

- `cl-defgeneric` `gptel--system-message-region` / `gptel--system-message-text`
  für andere Major Modes
- Emacs-Lisp: gültige Datei, ignorierte Markierung am Ende (z. B. `defvar` oder
  Kommentarblock)
- Befehle `gptel-org-insert-system-section`, `gptel-org-validate-system-section`
- README.org / NEWS upstream
- Escape-Hatch: Prefix → Subtree doch als normaler Prompt senden

---

## 11. Festgelegte Entscheidungen (Konzept §10)

1. System-Subtree **buffer-weit** (unabhängig von `GPTEL_TOPIC`).
2. Cursor **in** der Section → **harter Fehler**.
3. System-Text wie bei `GPTEL_SYSTEM` über `gptel--parse-directive` (in
   `gptel-request`).
4. Beim Org-Export bleibt die Section sichtbar (normale Überschrift).
5. **Letztes** Begin/End-Paar (Rückwärtssuche vom Dateiende).

---

## 12. Kurzreferenz für KI-Entwickler

**Wenn du dieses Feature erweiterst:**

- Haupteinstieg: `gptel-org--apply-buffer-system-message` (muss **zuerst**
  laufen, bevor Heading-Properties die System-Message setzen).
- Prompt-Kappung: `gptel-org--cap-prompt-end-for-system-section` in
  `gptel-org--create-prompt-buffer`.
- Section-Erkennung: `gptel-org--system-section-bounds--find` (plain-text,
  `gptel-org--system-section-marker-regexp`).
- Keine Org-Baumlogik für die Begrenzer.
- Tests nach Änderungen: `scripts/run-gptel-org-system-section-tests.sh`.
- Emacs des Nutzers: `/home/alex/git/clones/emacs/src/emacs`.

**Verwandte Dateien:**

- `mydocs/gptel-send-extension-prompt.md` — Ursprungsidee
- `mydocs/gptel-send-extension-concept.md` — ausführliches Konzept (teilweise
  veraltete Property-Namen in Beispielen; **maßgeblich ist dieser Stand**)
- `gptel-org.el` — Implementierung

---

## 13. Beispiel komplette Org-Datei

```org
#+title: gptel Chat mit System-Section

* Unterhaltung

** User
Was ist 2+2?

** Assistant
4

* System prompt
:GPTEL_SYSTEM_MESSAGE_BEGIN: t
Du bist ein Mathe-Tutor. Antworte nur mit dem Ergebnis, ohne Erklärung,
außer der Nutzer fragt explizit danach.
:GPTEL_SYSTEM_MESSAGE_END: t
```

Cursor in `** User` oder darunter (aber über `* System prompt`) → Senden nutzt
den Mathe-Tutor-Prompt als System-Message, die Frage als User-Inhalt.
