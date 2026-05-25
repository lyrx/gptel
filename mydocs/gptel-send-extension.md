# gptel-send: System-Message aus Org-Subtree am Dateiende

Kontext- und Entwicklerdokumentation für das Feature „System-Message
Section“ in Org-Dateien. Basis: `mydocs/gptel-send-extension-prompt.md`,
Konzept: `mydocs/gptel-send-extension-concept.md`, Implementierung in
`gptel-org.el` (Fork/Clone unter `/home/alex/git/clones/gptel`).

---

## 1. Ziel (Originalanforderung)

In **Org-Mode** soll `gptel-send` die **System-Message** aus einem
**markierten Subtree am Ende des Puffers** lesen — nicht aus dem
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
| Erkennung markierter Subtree | `gptel-org--system-subtree-bounds` |
| System-Text extrahieren | `gptel-org--system-subtree-message` |
| Vor `gptel-send`: Subtree prüfen & setzen | `gptel-org--apply-buffer-system-message` |
| Prompt ohne Subtree-Inhalt | `gptel-org--cap-prompt-end-for-system-subtree` in `gptel-org--create-prompt-buffer` |
| Integration `gptel-send` | Advice `gptel-org--send-with-props` |
| Integration `gptel-request` | Advice `gptel-org--request-with-system-subtree` |
| Log-Hinweis bei Verwendung | `message` + optional `gptel--log` |
| Batch-Tests | `scripts/gptel-org-system-subtree-tests.el` |
| Emacs-Lisp / andere Modi | **nicht** implementiert |

**Send-Ablauf:**

1. `gptel-send` → `gptel-org--send-with-props`
2. **Zuerst:** `gptel-org--apply-buffer-system-message` — gibt es eine gültige
   System-Section am Dateiende?
   - **Ja** → `gptel--system-message` aus Subtree; Log-Meldung; Heading-
     `GPTEL_SYSTEM` wird **nicht** für die System-Message verwendet.
   - **Nein** → wie bisher (`GPTEL_SYSTEM` am Heading, Buffer, Preset).
3. `gptel-request` → Prompt-Buffer (Subtree-Ende wird vor dem Subtree
   abgeschnitten, wenn Cursor davor steht).

---

## 3. Format der System-Section (Org)

### Pflicht

- **Eigene Überschrift** (Titel beliebig, z. B. `* System` oder
  `* System prompt`).
- **Property-Zeile** direkt unter der Überschrift (Name konfigurierbar,
  Standard siehe unten).
- **Position:** Subtree muss das **letzte substantielle** Element der Datei
  sein (danach nur Leerzeilen). Sonst: Warnung und Ignorieren (wenn Option an).
- **Inhalt:** Fließtext unter der Property-Zeile = System-Message (mehrzeilig
  möglich).

### Empfohlenes Muster (funktioniert zuverlässig)

```org
* Chat

** User
Hallo, erkläre kurz was Org-Mode ist.

* System prompt
:GPTEL_SYSTEM_MESSAGE_SUBTREE: t
Du bist ein hilfreicher Assistent für Org-Mode-Fragen.
Antworte auf Deutsch und knapp.
```

**Wichtig:** Property-Name exakt `GPTEL_SYSTEM_MESSAGE_SUBTREE`, Wert
mindestens `t` (nicht nur leere Zeile `:…:` ohne Wert — das ist in frischen
Buffern oft nicht per `org-entry-get` lesbar; zusätzlich greift ein
Regex-Fallback auf die Property-Zeile).

Alternative mit Property-Drawer (ebenfalls gültig):

```org
* System prompt
:PROPERTIES:
:GPTEL_SYSTEM_MESSAGE_SUBTREE: t
:END:
Dein System-Prompt hier.
```

### Was **nicht** als Konversations-Text mitgeht

- Überschrift der System-Section
- Die Zeile `:GPTEL_SYSTEM_MESSAGE_SUBTREE: t`
- Property-Drawer (werden gestrippt wie beim normalen Org-Prompt)

---

## 4. Verhalten bei `gptel-send`

| Situation | Verhalten |
|-----------|-----------|
| Keine markierte Section / nicht am EOF | Wie bisheriges gptel |
| Section am EOF, Cursor **darüber** | System-Message aus Section; Prompt nur bis Cursor, **ohne** Section |
| Cursor **in** der Section | **Fehler:** „Cursor is inside the system-message subtree…“ |
| Aktive Region schneidet Section | **Fehler:** Region overlaps system-message subtree |
| Section + `GPTEL_SYSTEM` am Heading | **Section gewinnt** (Subtree hat Vorrang) |
| Mehrere markierte Headings | Warnung; **erster** in der Datei zählt |

`GPTEL_TOPIC` schränkt den Prompt ein; die System-Section gilt **buffer-weit**
(Konfiguration pro Datei, nicht nur innerhalb des Topics).

---

## 5. Konfiguration (Customize)

| Option | Default | Bedeutung |
|--------|---------|-----------|
| `gptel-org-use-system-subtree` | `t` | Feature ein/aus |
| `gptel-org-system-subtree-property` | `"GPTEL_SYSTEM_MESSAGE_SUBTREE"` | Property-Name |
| `gptel-org-require-system-subtree-at-eof` | `t` | Section nur am Dateiende akzeptieren |

Es gibt **keine** separate Prioritäts-Option `gptel-org-system-subtree-priority`
(im Konzept erwähnt, nicht implementiert): Ist eine gültige Section da, setzt
sie die System-Message immer durch.

---

## 6. Relevante Lisp-Funktionen (`gptel-org.el`)

| Funktion | Rolle |
|----------|--------|
| `gptel-org--system-subtree-bounds` | `(beg . end)` des ersten markierten Subtrees oder `nil` |
| `gptel-org--system-subtree-message` | System-Text als String |
| `gptel-org--apply-buffer-system-message` | Setzt `gptel--system-message`, Log, Fehler bei Cursor in Section; return `t`/`nil` |
| `gptel-org--cap-prompt-end-for-system-subtree` | Begrenzt `prompt-end` vor Section-Beginn |
| `gptel-org--send-with-props` | Advice um `gptel-send` / `gptel--suffix-send` |
| `gptel-org--request-with-system-subtree` | Advice um `gptel-request` |

Bounds nutzen `org-back-to-heading` / `org-end-of-subtree` (nicht
`org-entry-begin`, fehlt in neueren Org-Versionen).

---

## 7. Log und Prüfen in Emacs

### Nach dem Senden

Bei Verwendung der Buffer-Section erscheint in **\*Messages\***:

```text
gptel: System message from buffer subtree (N chars)
```

- Anzeigen: `M-x view-echo-area-messages` oder `C-h e`

### Ausführlicher Log (optional)

```elisp
(setq gptel-log-level 'info)   ;; oder 'debug
```

Dann zusätzlich Eintrag in **\*gptel-log\*** (`gptel--log`, Typ
`system-subtree`). Im Transient-Menü (`C-u C-c RET`): Logging → **Inspect
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
/home/alex/git/clones/gptel/scripts/run-gptel-org-system-subtree-tests.sh
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
2. Direkt darunter eine Zeile: :GPTEL_SYSTEM_MESSAGE_SUBTREE: t
3. Darunter der System-Prompt-Text (mehrzeilig erlaubt).

Anforderungen an den System-Prompt:
- [HIER: Rolle, Sprache, Stil, Verbote, z. B. "Du bist …", "Antworte auf
  Deutsch", "Kein Code unless asked"]

Wichtig:
- Die Section muss das LETZTE Element der Datei sein (nur Leerzeilen danach).
- Bestehende Chat-Inhalte oben nicht löschen.
- Property-Name exakt GPTEL_SYSTEM_MESSAGE_SUBTREE, Wert t.
- Keine andere Property für die System-Message verwenden.

Wenn schon eine solche Section existiert, ersetze nur deren Prompt-Text und
lass Struktur und Property-Zeile korrekt.
```

### Kürzere Variante

```text
Am Dateiende: Org-Subtree "* System prompt" mit :GPTEL_SYSTEM_MESSAGE_SUBTREE: t
und diesem System-Prompt:

[HIER DEIN PROMPT]

Nichts am Chat darüber ändern. Section muss letztes Element der Datei sein.
```

### Nach der KI-Antwort prüfen

1. Datei scrollen: Section wirklich **ganz unten**?
2. Property-Zeile exakt `:GPTEL_SYSTEM_MESSAGE_SUBTREE: t`?
3. Cursor in den **Chat** setzen (über der Section).
4. `gptel-send` (`C-c RET`) → in \*Messages\* muss stehen:
   `gptel: System message from buffer subtree …`
5. Wenn **keine** Meldung: Section fehlt, falscher Property-Name, nicht am EOF,
   oder `gptel-org-use-system-subtree` ist `nil` / alter Code nicht geladen.

### Typische Fehler der KI (korrigieren lassen)

| Problem | Korrektur |
|---------|-----------|
| Section mitten in der Datei | „Ans Dateiende verschieben“ |
| Nur `:GPTEL_SYSTEM:` am Heading | Richtige Property + eigene Überschrift unten |
| `GPTEL_SYSTEM_SUBTREE` (ohne `MESSAGE`) | Exakter Name laut Tabelle |
| System-Prompt im Chat-Text | In die untere Section verschieben |
| Cursor in Section beim Senden | Cursor nach oben setzen |

### System-Prompt für den Assistenten in der Datei (Beispiel)

```text
Du bist ein Assistent für Org-Mode und gptel in Emacs.
Antworte knapp auf Deutsch.
Wenn der Nutzer eine System-Section anfordert, halte dich strikt an das
Format aus der Dokumentation (Überschrift, :GPTEL_SYSTEM_MESSAGE_SUBTREE: t,
am Dateiende).
```

(Diesen Text trägst du in die **System-Section** ein — nicht als normale
Chat-Nachricht.)

---

## 9. Tests

Datei: `scripts/gptel-org-system-subtree-tests.el`  
Runner: `scripts/run-gptel-org-system-subtree-tests.sh`

Abgedeckt u. a.: Bounds am EOF, Textextraktion, Prompt ohne Subtree-Inhalt,
Vorrang vor `GPTEL_SYSTEM`, Cursor-in-Section-Fehler, ignorieren wenn nicht
am EOF.

---

## 10. Geplante Weiterentwicklung (noch offen)

Aus Konzept/Prompt, **nicht** umgesetzt:

- `cl-defgeneric` `gptel--system-message-region` / `gptel--system-message-text`
  für andere Major Modes
- Emacs-Lisp: gültige Datei, ignorierte Markierung am Ende (z. B. `defvar` oder
  Kommentarblock)
- Befehle `gptel-org-insert-system-subtree`, `gptel-org-validate-system-subtree`
- README.org / NEWS upstream
- Escape-Hatch: Prefix → Subtree doch als normaler Prompt senden

---

## 11. Festgelegte Entscheidungen (Konzept §10)

1. System-Subtree **buffer-weit** (unabhängig von `GPTEL_TOPIC`).
2. Cursor **in** der Section → **harter Fehler**.
3. System-Text wie bei `GPTEL_SYSTEM` über `gptel--parse-directive` (in
   `gptel-request`).
4. Beim Org-Export bleibt die Section sichtbar (normale Überschrift).
5. **Erster** markierter Subtree in der Datei; bei mehreren → Warnung.

---

## 12. Kurzreferenz für KI-Entwickler

**Wenn du dieses Feature erweiterst:**

- Haupteinstieg: `gptel-org--apply-buffer-system-message` (muss **zuerst**
  laufen, bevor Heading-Properties die System-Message setzen).
- Prompt-Kappung: `gptel-org--cap-prompt-end-for-system-subtree` in
  `gptel-org--create-prompt-buffer`.
- Property-Erkennung: `gptel-org--system-subtree-marked-p` (entry-get,
  element-property, Regex auf Property-Zeile).
- Keine Abhängigkeit von `org-entry-begin` / `org-entry-end`.
- Tests nach Änderungen: `scripts/run-gptel-org-system-subtree-tests.sh`.
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
:GPTEL_SYSTEM_MESSAGE_SUBTREE: t
Du bist ein Mathe-Tutor. Antworte nur mit dem Ergebnis, ohne Erklärung,
außer der Nutzer fragt explizit danach.
```

Cursor in `** User` oder darunter (aber über `* System prompt`) → Senden nutzt
den Mathe-Tutor-Prompt als System-Message, die Frage als User-Inhalt.
