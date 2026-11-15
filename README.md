# take-it-easy

Toolkit macOS da menu bar che toglie di mezzo le operazioni meccaniche fastidiose:
OCR e contagocce (Grab), storico appunti (Clipboard), rotella di azioni sui file (Wheel),
volume per app, microfono e luminosità (Mixer), anteprime nel Dock e nel ⌘Tab (Glance, Switch),
monitor di sistema (Resource Manager), gesture via tasti (Gesture), Stay Up, Pulizia tastiera.

Richiede macOS 14.2 o successivo. Niente rete, niente telemetria.

## Installazione

1. Scarica `TakeItEasy-<versione>.zip` dall'ultima [Release](../../releases) e aprilo.
2. Trascina **TakeItEasy.app** in **Applicazioni**.
3. Primo avvio: l'app non è notarizzata da Apple, quindi macOS la blocca.
   - Apri l'app una volta (comparirà l'avviso), poi vai in **Impostazioni di Sistema › Privacy e sicurezza**
     e clicca **Apri comunque**.
   - Oppure da Terminale: `xattr -dr com.apple.quarantine /Applications/TakeItEasy.app`
4. Clicca l'icona 🔧 nella barra dei menu e accendi i moduli che ti servono: i permessi
   (Accessibilità, Registrazione schermo, …) vengono chiesti solo allora.

## Aggiornare

Scarica la nuova versione e sostituisci quella in Applicazioni (ripeti il passo 3).
I permessi già concessi restano: ogni versione è firmata con lo stesso certificato.

## Per lo sviluppo

- Una volta: `scripts/make-signing-cert.sh` (crea il certificato di firma autofirmato).
- Ogni release: `scripts/release.sh 1.0`, poi il comando `gh release create …` che stampa.
