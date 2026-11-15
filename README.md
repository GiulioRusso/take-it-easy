# take-it-easy

Toolkit macOS da menu bar che toglie di mezzo le operazioni meccaniche fastidiose.

| Modulo | Cosa fa |
|---|---|
| **Grab** | Copia testo (OCR) e QR da qualsiasi punto dello schermo; contagocce che copia il colore in HEX |
| **Clipboard** | Storico appunti con ricerca, voci fissate, incolla come testo semplice |
| **Wheel** | Rotella di azioni sui file selezionati nel Finder (PDF, conversioni, compressione, zip, Terminale…) |
| **Mixer** | Volume per app, microfono on/off e push-to-talk, luminosità di display e tastiera |
| **Glance** | Anteprime delle finestre sopra le icone del Dock |
| **Switch** | Anteprime nel ⌘Tab, ⌥` per passare tra le finestre della stessa app |
| **Resource Manager** | CPU e memoria (anche per app), batterie Bluetooth, potenza, GPU, rete, dischi esterni |
| **Gesture** | Un tocco di un modificatore = una gesture del trackpad (es. ⌘ destro → Mostra Scrivania) |
| **Stay Up** | Tiene sveglio il Mac per il tempo che scegli |
| **Pulizia** | Blocca la tastiera per pulirla |

Richiede **macOS 14.2** o successivo, Mac Apple Silicon o Intel. Niente rete, niente telemetria.

---

## Installazione (utenti)

1. Scarica `TakeItEasy-<versione>.zip` dall'ultima [Release](../../releases) e aprilo.
2. Trascina **TakeItEasy.app** in **Applicazioni**.
3. **Primo avvio.** L'app non è notarizzata da Apple, quindi macOS la blocca:
   1. apri l'app una volta e chiudi l'avviso;
   2. vai in **Impostazioni di Sistema › Privacy e sicurezza**, scorri in basso e clicca **Apri comunque**;
   3. conferma con la password.

   In alternativa, da Terminale: `xattr -dr com.apple.quarantine /Applications/TakeItEasy.app`
4. Clicca l'icona 🔧 nella barra dei menu: in alto i controlli rapidi, in basso i riquadri dei moduli.
   Clicca un riquadro per accenderlo; i permessi (Accessibilità, Registrazione schermo, …) vengono chiesti solo allora.
   Clic destro su un riquadro → impostazioni del modulo.
5. Facoltativo: in **Impostazioni › Generali** attiva **Avvia al login**.

### Aggiornare

Scarica la nuova versione, sostituisci quella in Applicazioni e ripeti il passo 3.
**I permessi già concessi restano**: ogni versione è firmata con lo stesso certificato.

### Disinstallare

Trascina l'app nel Cestino. Per togliere anche permessi e dati:
```
tccutil reset All russogiulio.TakeItEasy
rm -rf ~/Library/Application\ Support/take-it-easy ~/Library/Preferences/russogiulio.TakeItEasy.plist
```

---

## Pubblicare una versione (sviluppatore)

Tutto passa da un unico script: **`scripts/release.sh <versione>`**.

### Una volta sola

1. Installa ed esegui il login di GitHub CLI:
   ```
   brew install gh
   gh auth login
   ```
2. Nient'altro: il certificato di firma e il repo GitHub li crea lo script al primo giro.

### Ogni release

1. Fai il commit di tutte le modifiche (lo script si ferma se ci sono modifiche non salvate).
2. Lancia:
   ```
   scripts/release.sh 1.1
   ```

Lo script fa, in ordine:

| Passo | Cosa succede |
|---|---|
| 1. Certificato | Se manca, crea «TakeItEasy Self-Signed» (10 anni) nel portachiavi e un backup in `~/TakeItEasy-signing/` (`signing.p12` + `password.txt`) |
| 2. Controlli | `gh` installato e loggato, nessuna modifica non committata, tag `v<versione>` non ancora usato |
| 3. Build | Release universale (Apple Silicon + Intel), firmata con il certificato, zippata in `build/release/TakeItEasy-<versione>.zip`; verifica che la firma sia quella stabile |
| 4. GitHub | Se non c'è un remote chiede conferma e crea il repo **pubblico** `take-it-easy` (serve pubblico perché gli utenti possano scaricare); altrimenti fa il push |
| 5. Release | Crea e pubblica il tag `v<versione>` e la Release GitHub con lo zip e le note generate dai commit |

Opzioni:
- `scripts/release.sh 1.1 --no-publish` — solo certificato + build dello zip, senza toccare GitHub.
- `REPO_NAME=altro-nome scripts/release.sh 1.1` — nome diverso per il repo creato al primo giro.

### Il certificato: importante

- Firmare sempre con **lo stesso** certificato è ciò che fa ricordare i permessi agli utenti tra un aggiornamento e l'altro.
- Dopo il primo giro **sposta la password** da `~/TakeItEasy-signing/password.txt` al tuo gestore di password e conserva `signing.p12` in un posto sicuro (non nel repo, non su iCloud in chiaro).
- Su un altro Mac: importa `signing.p12` nel portachiavi (doppio clic, inserisci la password) e lo script lo userà.
- Se lo perdi: crea un nuovo certificato (cancella quello vecchio dal portachiavi e rilancia lo script). Funziona tutto, ma gli utenti dovranno riconcedere i permessi una volta.

### Icona

Generata da `scripts/make-icon.swift` (simbolo SF «wrench.and.screwdriver» su sfondo blu). Per rigenerarla dopo una modifica:
```
swift scripts/make-icon.swift
```

---

## Sviluppo

- Xcode 16+, Swift 6. Apri `TakeItEasy.xcodeproj` e premi ▶︎.
- Build da terminale: `xcodebuild -project TakeItEasy.xcodeproj -scheme TakeItEasy -configuration Debug build`
- Architettura, moduli e roadmap: `PLAN.md`. Regole di progetto: `CLAUDE.md`.
- Dopo una ricompilazione i permessi possono invalidarsi: `tccutil reset All russogiulio.TakeItEasy` e riconcedili.
  Le build di Xcode sono firmate con il certificato di sviluppo, quelle di `release.sh` con quello autofirmato:
  sul tuo Mac le due versioni si "rubano" i permessi a vicenda.
