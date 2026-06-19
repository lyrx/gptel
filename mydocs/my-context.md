# gptel – Arbeitskontext (für künftige Chats)

Dieses Dokument fasst Umgebung, Konventionen, Fund- und Fixstellen sowie
offene Punkte aus der bisherigen Arbeit am gptel-Fork zusammen. Es dient
als Kontext für weitere gptel-Chats.

## Umgebung

- Repo: `/home/alex/git/clones/gptel` (Fork von `karthink/gptel`).
- Emacs: **GNU Emacs 31.0.50** (lokaler Dev-Build). Liegt **nicht** im PATH.
- Für Batch/Tests/Byte-Compile immer dieses Binary nutzen:
  `/home/alex/git/clones/emacs/src/emacs`
  (kein Docker, kein `apt install emacs`).
- Transient: interaktiv **0.13.3** (ELPA), eingebaut 0.12.0. gptel braucht
  ≥ 0.7.4 → erfüllt. Kein `package-install-upgrade-built-in` nötig.
- User-Init für gptel: `/home/alex/.emacs.d/lisp/gptel-init.el`.
  Enthält u.a. `(add-hook 'org-mode-hook #'gptel-mode)` (saubere Form,
  kein `run-at-time`-Workaround mehr nötig).

## Git-Workflow (WICHTIG, harte Regel)

- **Niemals committen, niemals pushen** – globale Regel in
  `~/.cursor/rules/no-git-commit-push.mdc` (`alwaysApply: true`), gilt für
  ALLE Projekte. Lesende git-Befehle (`status`, `diff`, `log`) sind ok.
- Bei Merges: `git merge --no-commit --no-ff …` vorbereiten, Konflikte
  lösen, Tests laufen lassen – **der User committet selbst**.
- Remotes: `origin` = Upstream `karthink/gptel` (HTTPS),
  `fork` = `lyrx/gptel` (auf SSH umgestellt). Der User pusht selbst.
- Commit-Stil im Fork ist informell (z.B. "Der Knilch hat nachgebessert!").

## System-Message-Section-Feature (Fork-spezifisch)

Eigene Erweiterung in `gptel-org.el`: eine per Klartext-Marker
abgegrenzte System-Message-Section am Datei-/Bufferende. Wird per
Rückwärtssuche gefunden (zuerst End-, dann Begin-Marker).

- Defcustoms:
  - `gptel-org-use-system-section` (t)
  - `gptel-org-system-section-property` → **Begin-Marker**
  - `gptel-org-system-section-end-property` → End-Marker
  - `gptel-org-require-system-section-at-eof` (t): nach dem End-Marker darf
    nur Whitespace oder ein `Local Variables`-Trailer folgen.
- **Marker-Namen (nach Umbenennung in diesem Chat):**
  - Begin: `GPTEL_SYSTEM_MESSAGE_BEGIN`  (früher `GPTEL_SYSTEM_MESSAGE`)
  - End:   `GPTEL_SYSTEM_MESSAGE_END`
  - Das war eine **harte Umbenennung** (kein Fallback). Bestehende Dateien
    mit altem `:GPTEL_SYSTEM_MESSAGE:` muss der User selbst migrieren.
- Marker-Zeilensyntax (mode-übergreifend): Org `:NAME: t`, oder Kommentar-
  Präfix `#`, `;`, `;;`, `%` vor `NAME` (siehe
  `gptel-org--system-section-marker-regexp`). `\b` nach dem Namen
  verhindert, dass der Begin-Marker den `_END`/`_BEGIN`-Marker matcht.
- Priorität: Die Section ist die **Quelle der Wahrheit**. Beim Restore
  überschreibt sie eine `GPTEL_SYSTEM`-Property; beim Speichern wird eine
  vorhandene `GPTEL_SYSTEM`-Property gelöscht, wenn eine Section existiert.
  Folge: interaktive Änderungen via `gptel-system-prompt` persistieren
  nicht, solange eine Section existiert (gewolltes Verhalten).

## Behobener Hauptbug: Buffer-Leak → "keymapp nil"

Symptom (interaktiv): Beim Öffnen von Org-Dateien
`File mode specification error: (wrong-type-argument keymapp nil)`.

Echte Ursache (per Backtrace reproduziert, NICHT geraten):

- `gptel-org--system-section-message` parst die Section via
  `gptel--with-buffer-copy`. Das Makro erzeugt einen Temp-Buffer
  ` *gptel-prompt*`, setzt dessen `major-mode`-Variable auf `org-mode`
  (ohne `org-mode` wirklich auszuführen → `current-local-map` = nil) und
  **killt ihn nicht**. Die Funktion gab nur einen String zurück → Leak.
- Beim nächsten Org-`find-file` durchläuft Orgs
  `org-install-agenda-files-menu` die `buffer-list`, findet den geleakten
  Pseudo-Org-Buffer und ruft `define-key nil …` → `keymapp nil`.
- Akkumuliert: tritt erst nach dem ersten Section-Parse beim nächsten
  Öffnen auf.

Fix in `gptel-org--system-section-message`: Copy-Buffer mit
`unwind-protect` + `kill-buffer` selbst aufräumen (Kommentar im Code:
"kill the copy ourselves").

Send-/Dry-Run-Pfad ist sauber: `gptel--realize-query` killt den
` *gptel-prompt*`-Buffer am Ende (auch im Dry-Run, vor dem `:dry-run`-
Check). Verifiziert per Test (Fall L). Einziger theoretischer Restleak:
ein **fehlerhafter synchroner** `gptel-prompt-transform-functions`-Hook
würde vor `realize-query` abbrechen (vorbestehend, nicht gptel-org,
nicht eigenmächtig gefixt).

## Zurückgenommene Fehl-"Fixes"

- Frühere Annahme "Fehler lag am Local-Variables-Block unten im Buffer"
  war **falsch** (Korrelation, nicht Kausalität): Ein Trailer allein
  verursacht keinen `keymapp`-Fehler.
- Daher entfernt: automatisches Löschen eines `;; Local Variables:`-
  Trailers beim Speichern (`gptel-org--delete-gptel-local-variables-
  trailer` + Helper). War destruktiv (löschte auch Fremdzeilen wie
  `mode: org`). Ebenso toter Code `gptel-org--only-whitespace-after-p`.
- Behalten: `gptel-org--system-section-at-file-end-p` (erlaubt einen
  Trailer nach dem End-Marker, legitim).

## Tests (alle grün, lokal mit dem Dev-Build laufen lassen)

- `scripts/gptel-org-system-section-tests.el` (29 Tests)
  Runner: `bash scripts/run-gptel-org-system-section-tests.sh`
- `scripts/gptel-org-realistic-tests.el` (12 Tests, End-to-End:
  `find-file → org-mode-hook → gptel-mode → save → reopen`)
  Runner: `bash scripts/run-gptel-org-realistic-tests.sh`
  Fälle A–L; J = kein geleakter Temp-Buffer, K = viele Section-Opens
  ohne Crash, L = Dry-Run ohne Buffer-Leak.
- `scripts/gptel-org-merge-tests.el`
  Run: `EMACS=… $EMACS --batch -Q -L . -l scripts/gptel-org-merge-tests.el
  -f gptel-org-merge-tests-run`
- `scripts/run-gptel-org-merge-regression.sh` — Parent vs. Working Tree
  (alte `gptel-org.el` muss scheitern, aktuelle Datei muss passen).
- Voller Recompile: `make force` (nutzt automatisch den lokalen Build).
- Verifikationsprinzip: Tests müssen den Bug fangen. Belegt: gegen
  Vor-Fix-Stand `a942c92` werden D/E/H/J/K rot, mit Fix alle grün.
- Häufige Test-Falle: Nach `find-file` ist der Buffer unverändert →
  `basic-save-buffer` tut nichts → `before-save-hook`/`gptel--save-state`
  läuft nicht. Im Harness Buffer vor dem Speichern als modifiziert
  markieren (ohne Inhaltsänderung, sonst Idempotenz-Test bricht).

## Upstream-Merges

Chronologie der `origin/master`-Integrationen in den Fork (`master`).
Remote heißt upstream-seitig `master` (kein `main`).

### Merge 1 — `6dac86d` (vorheriger Chat)

- Befehl: `git merge origin/master` (konfliktfrei).
- **8 Upstream-Commits** integriert, u. a.:
  - `f342b30` gptel-org: Copy tab-width into the prompt buffer
  - `4817e6c` gptel-bedrock: System-Prompt- und Tool-Caching
  - Gemini 3.5-flash, OAuth gpt-5.5, Tool-Call-Reject vor Inspektion
- Eigener Code intakt: Leak-Fix, Marker-Rename, keine Trailer-Löschung.

### Merge 2 — `689848e` (19. Jun 2026)

- Befehl: `git fetch origin` + `git merge origin/master`.
- **15 Upstream-Commits** (`f342b30..983cb1f`), Schwerpunkte:
  - `c35b7d8` Umbenennung `gptel--system-message` → `gptel-system-prompt`
  - Claude Opus 4.8, Claude Fable, Copilot-Modelle
  - `gptel-request`: vereinheitlichtes Error-Handling
  - `gptel-rewrite`: Reasoning-Buffer-Fix
  - Tool-Call-Anzeige auf 256 Zeichen gekürzt
- **1 Konflikt** in `gptel-org.el` (`gptel-org--send-with-props`,
  `gptel-org--restore-state`, `gptel-org-set-properties`):
  System-Section-Logik und Merge-Helper **behalten**, Variablen auf
  `gptel-system-prompt` umgestellt (Upstream-`seq-mapn`-Variante nicht
  blind übernommen).
- Merge-Commit: `689848e` — *Merge origin/master into master*.
- Stand danach: lokaler `master` **19 Commits** vor `origin/master`.

### Verifikation nach Merge 2

Alle grün mit `/home/alex/git/clones/emacs/src/emacs`:

- `make force`
- `scripts/run-gptel-org-system-section-tests.sh` (29/29)
- `scripts/run-gptel-org-realistic-tests.sh` (12/12)
- `scripts/gptel-org-merge-tests.el` (`gptel-org-merge-tests-run`)
- `scripts/run-gptel-org-merge-regression.sh` (alte `gptel-org.el` fail,
  Working Tree pass)
- Upstream-Submodule `test/`: 147 ERT (144 pass, 3 skip) — `make test`
  braucht explizites `EMACS=…` (Binary nicht im PATH).

## Anthropic-Modelle

- Liste: `defconst gptel--anthropic-models` in `gptel-anthropic.el`
  (ab Z. 568), genutzt von `gptel-make-anthropic`.
- gptel sendet `:temperature` nur, wenn `gptel-temperature` non-nil ist
  (Default 1.0) – `gptel-anthropic.el` Z. 247–248.

### Claude Opus 4.8 (nicht in der Liste enthalten)

- API-Modell-ID: **`claude-opus-4-8`** (Bedrock:
  `anthropic.claude-opus-4-8`). Release 2026-05-28.
- Kontext 1M Tokens (Claude API), max. Output 128k,
  Preis $5 In / $25 Out (Fast-Mode $10/$50).
- **Wichtig:** `temperature`, `top_p`, `top_k` → **400-Fehler**. In gptel
  daher `gptel-temperature` auf `nil` setzen (global oder buffer-lokal).
- Adaptive Thinking (`thinking: {"type":"adaptive"}`) und Fast-Mode
  (`speed: "fast"`) bildet gptel nicht automatisch ab → ggf. über
  `:request-params` im Modell-Spec ergänzen.
- Registrieren via Init-Snippet (an `gptel-backend-models` der "Claude"-
  Backend anhängen) oder fest in die Liste eintragen.

## Hilfsfunktion: Section-Trenner einfügen (User-Init)

Minimaler, leicht auf andere Dateitypen erweiterbarer Generator (nutzt die
gptel-Marker-Variablen, bleibt also synchron mit dem Rename):

```emacs-lisp
(defvar my-gptel-section-line-format-alist
  '((org-mode        . ":%s: t")
    (markdown-mode   . "# %s")
    (emacs-lisp-mode . ";; %s"))
  "Zeilenformat der gptel-Section-Trenner pro Major-Mode (%s = Markername).")

(defun my-gptel-section-line-format ()
  (or (cdr (assq major-mode my-gptel-section-line-format-alist)) ":%s: t"))

(defun my-gptel-insert-system-section ()
  "Füge leere gptel-System-Message-Trenner ein; Punkt landet dazwischen."
  (interactive)
  (let ((fmt (my-gptel-section-line-format)))
    (unless (bolp) (insert "\n"))
    (insert (format fmt gptel-org-system-section-property) "\n")
    (save-excursion
      (insert "\n" (format fmt gptel-org-system-section-end-property) "\n"))))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map "C-c s" #'my-gptel-insert-system-section))
```

Hinweis: `C-c C-s` ist in `org-mode-map` durch `org-schedule` belegt;
daher `C-c s` (für Nutzer reservierter Bereich) oder `C-c M-s`.

## Sonstiges Wissen

- gptel speichert Org-State in Properties (`GPTEL_MODEL`, `GPTEL_BACKEND`,
  `GPTEL_SYSTEM`, `GPTEL_BOUNDS`, …), nicht in Local-Variables-Blöcken.
  Ein Local-Variables-Block in einer Org-Datei ist Alt-/Fremdartefakt.
- `gptel-menu`/`gptel-system-prompt` brauchen geladenes `gptel-transient`.
  Optionen wie "Dry Run"/"Logging" erscheinen erst mit
  `gptel-expert-commands` = t bzw. `gptel-log-level` (`info`/`debug`).
- API-Calls inspizieren: `gptel-log-level` auf `info`/`debug`, Log-Buffer
  `*gptel-log*`.
