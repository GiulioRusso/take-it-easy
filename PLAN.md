# take-it-easy — PLAN

Toolkit macOS da menu bar che toglie di mezzo le operazioni meccaniche fastidiose.
Un'unica app, tanti **moduli** indipendenti che l'utente accende/spegne dalle Impostazioni.
Regola d'oro: **meno movimenti del mouse possibili** — le azioni compaiono dove si trova già il cursore.

---

## Principi

1. **Modulare davvero**: un modulo spento non gira, non registra hotkey/event tap, non chiede permessi.
2. **Permessi on-demand**: si chiedono solo all'attivazione del modulo che li richiede, spiegando perché.
3. **Vicino al cursore**: pannelli e menu si aprono nel punto in cui si trova il mouse.
4. **Leggero e locale**: nessuna rete, nessuna telemetria, niente processi inutili.
5. **Reversibile**: spegnere un modulo ripristina lo stato di sistema (volumi, luminosità, event tap…).

---

## Architettura

- **Target**: macOS 14.2+ (serve per i Core Audio process tap), Swift 6, SwiftUI + AppKit.
- **App**: una sola icona in menu bar (`MainPanel`, NSStatusItem + pannello stile Centro di Controllo: controlli rapidi dei moduli accesi via `quickView()`, griglia di riquadri per accenderli/spegnerli; clic destro → impostazioni del modulo). Impostazioni in una finestra con barra laterale (`SettingsWindow`). Mixer, Resource Manager e Stay Up possono avere anche un'icona propria (`PinnableStatusItem`, spenta di default). `LSUIElement = YES`, **App Sandbox disattivata**, Hardened Runtime attivo.
  Distribuzione fuori dal Mac App Store (GitHub + notarizzazione): alcuni moduli usano API private.
- **Avvio al login**: `SMAppService.mainApp`. **Hotkey**: package `KeyboardShortcuts`.
- **Overlay/pannelli**: `NSPanel` non attivante (`.nonactivatingPanel`, livello `.popUpMenu`) per non rubare il focus.

### Contratto di un modulo

```swift
protocol TIEModule: AnyObject, Identifiable {
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    var symbol: String { get }                         // SF Symbol
    var requiredPermissions: [TIEPermission] { get }   // .accessibility, .screenRecording, .appleEvents(Finder), .audioCapture
    func start() throws                                // idempotente
    func stop()                                        // idempotente, ripristina lo stato
    @MainActor func settingsView() -> AnyView
}
```

- `ModuleRegistry`: elenco moduli, stato on/off persistito, start/stop.
- `PermissionCenter`: stato e richiesta permessi per modulo.
- `CursorPanel`: helper condiviso per mostrare un NSPanel centrato sul cursore (usato da Wheel e Grab).

### Info.plist / entitlements necessari
- `NSAppleEventsUsageDescription` + entitlement `com.apple.security.automation.apple-events` (Wheel → Finder).
- `NSAudioCaptureUsageDescription` (Mixer → volume per app).
- Registrazione schermo e Accessibilità: gestite da TCC, verificate da `PermissionCenter`.

### Struttura cartelle
```
TakeItEasy/
  App/        TakeItEasyApp.swift, MainPanel.swift
  Core/       TIEModule.swift, ModuleRegistry.swift, PermissionCenter.swift, CursorPanel.swift
  Modules/
    Grab/       (OCR al volo)
    Wheel/      (rotella azioni sui file)
    Mixer/      (volume per app + luminosità per display)
    Glance/     (anteprime finestre nel Dock)
    Switch/     (switcher app e finestre con anteprime)
    ResourceManager/ (monitor di sistema compatto)
    Gesture/    (azioni delle gesture via tasti)
    StayUp/     (tiene sveglio il Mac)
    Clipboard/  (storico appunti)
    Clean/      (blocca la tastiera per pulirla)
  Settings/
```

---

## Moduli principali

### 1. Grab — OCR al volo
**Problema**: copiare testo da immagini, video, PDF scansionati, slide in call, app che non permettono la selezione.
**Flusso**: hotkey (es. ⌃⇧2) → schermo congelato con overlay → trascini un rettangolo → testo negli appunti + toast "Copiato · 42 parole".
**Twist**:
- Se l'area contiene un **QR/barcode** → copia il contenuto (o apre il link con ⌘).
- **Ri-cattura rapida**: hotkey + ⇧ ripete l'ultima area (utile per sottotitoli/slide che cambiano).
- Opzioni: mantieni gli a capo o unisci in un paragrafo, rimuovi la sillabazione. Lingua rilevata automaticamente.
**API**: ScreenCaptureKit (`SCScreenshotManager.captureImage`), Vision (`VNRecognizeTextRequest` accurate + `VNDetectBarcodesRequest`).
**Permessi**: Registrazione schermo. **Difficoltà**: media-bassa. **Primo da fare.**

### 2. Wheel — rotella azioni sui file
**Problema**: per convertire/unire/comprimere file serve aprire app diverse o trascinare file in giro.
**Flusso**: selezioni uno o più file in Finder/Scrivania → **trigger** → compare una **rotella radiale centrata sul cursore** → muovi leggermente il mouse verso uno spicchio e rilasci/clicchi → l'azione parte, il risultato viene salvato accanto ai file originali.
**Trigger configurabile** (via `CGEventTap`, attivo solo se l'app in primo piano è Finder):
- tasto centrale del mouse, oppure
- tasto laterale del mouse (button 4/5), oppure
- hotkey, oppure
- tieni premuto ⌥ + clic destro.
**Selezione**: letta dal Finder via Apple Events (`tell application "Finder" to get selection as alias list`, o ScriptingBridge).
**Spicchi contestuali** (max 6-8, dipendono dal tipo di file selezionato):
| Selezione | Azioni |
|---|---|
| Immagini | → PDF (un file), Ridimensiona, Comprimi, Converti (JPEG/PNG/HEIC), Ruota, Rimuovi metadati |
| PDF | Unisci, Comprimi, Estrai pagine, → immagini |
| Video | → MP4 (H.264), → GIF, Estrai audio, Comprimi |
| Audio | → M4A/MP3, Taglia silenzi |
| Qualsiasi | Copia percorso, Zip, Rinomina in serie, Nuovo file qui |
- Spicchio centrale = annulla. Sottomenu: tieni il cursore su uno spicchio → si apre un secondo anello (es. Converti → JPEG / PNG / HEIC).
- **Ricette**: l'utente può salvare preset ("PDF A4 < 5 MB", "Ridimensiona 1080px") che diventano spicchi.
- Progressi nel toast; i file originali non vengono mai sovrascritti.
**API**: CGEventTap, NSAppleScript/ScriptingBridge, PDFKit, ImageIO, AVFoundation (`AVAssetExportSession`) per video/audio.
**Permessi**: Accessibilità (event tap), Automazione → Finder. **Difficoltà**: media.

### 3. Mixer — volume e luminosità in un unico pannello
**Problema**: volume per app inesistente, luminosità dei monitor esterni non controllabile, tutto sparso tra Centro di Controllo e impostazioni.
**Flusso**: clic sull'icona Mixer in menu bar (o hotkey) → un pannello unico:
```
DISPLAY
  MacBook Pro        [■■■■■■□□□□]
  Dell U2723QE       [■■■■□□□□□□]   (DDC)
  LG (HDMI)          [■■■□□□□□□□]   (software)
AUDIO — uscita: AirPods Pro ▾
  Sistema            [■■■■■■■□□□]
  Spotify            [■■■■■□□□□□]  🔇
  Zoom               [■■■■■■■■■□]  🔇
  Safari             [■■□□□□□□□□]  🔇
```
**Twist**:
- Rotella del mouse sopra uno slider = regolazione fine, senza dover cliccare.
- **Memoria per contesto**: i volumi per app vengono ricordati per dispositivo di uscita (cuffie ≠ altoparlanti).
- Tasti luminosità/volume della tastiera agiscono sul display/dispositivo sotto il cursore (opzionale).
**API — luminosità**:
- Display integrato e display Apple: `DisplayServices` (framework privato, `DisplayServicesSetBrightness`).
- Monitor esterni: **DDC/CI** su Apple Silicon via `IOAVService` (API IOKit private, come MonitorControl); VCP code 0x10.
- Fallback se il monitor non supporta DDC: dimming software via gamma table (`CGSetDisplayTransferByFormula`).
**API — audio**:
- Volume/uscita di sistema: CoreAudio (`kAudioDevicePropertyVolumeScalar`, default output device).
- Volume per app: **Core Audio process tap** (macOS 14.2+): `CATapDescription` per processo con `muteBehavior = .mutedWhenTapped`, aggregate device con il tap, IOProc che riscrive i campioni moltiplicati per il gain verso l'uscita. Un tap per app con volume ≠ 100%.
- Elenco app che producono audio: `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningOutput`.
**Permessi**: Registrazione audio di sistema (TCC), nessuno per la luminosità.
**Difficoltà**: luminosità media, volume per app **alta** (latenza, cambio dispositivo, sample rate diversi). Fare prima la parte display + volume di sistema, poi il volume per app.

### 4. Glance — anteprime finestre nel Dock
**Problema**: dal Dock non vedi quali finestre ha un'app; ⌘` è cieco e non funziona bene tra Spaces.
**Flusso**: cursore sopra un'icona del Dock → dopo ~300 ms compare un fumetto (rettangolo con la punta sull'icona) con le miniature delle finestre di quell'app → clic su una miniatura = porta in primo piano quella finestra; clic centrale = chiudi; scroll = scorri.
**Twist**:
- Miniature anche delle finestre **minimizzate** (contrassegnate) e di quelle su altri Spaces quando disponibili.
- Digitazione mentre l'anteprima è aperta = filtra per titolo finestra.
- Lo switcher con ⌥Tab è il modulo Switch e condivide il catalogo finestre (`Core/WindowCatalog.swift`).
**API**:
- Icona sotto il cursore: Accessibility sul processo Dock (`AXUIElementCreateApplication(pid Dock)`, `AXObserver` su `kAXSelectedChildrenChangedNotification` della lista del Dock), dimensione/posizione icona da `kAXPositionAttribute`/`kAXSizeAttribute`.
- Finestre e miniature: ScreenCaptureKit (`SCShareableContent` con `onScreenWindowsOnly: false`, `SCScreenshotManager.captureImage` per finestra), cache delle miniature.
- Portare in primo piano: AX (`kAXRaiseAction`, `kAXMinimizedAttribute = false`) + `NSRunningApplication.activate`.
**Permessi**: Accessibilità + Registrazione schermo. **Difficoltà**: alta. **Ultimo dei quattro.**

### 5. Switch — anteprime nel ⌘Tab e finestre della stessa app
**Problema**: ⌘Tab mostra solo icone e non passa tra le finestre della stessa app (più finestre di VS Code o Safari).
**Flusso**:
- ⌘Tab di sistema invariato: mentre è aperto, sopra l'app selezionata compare il fumetto di Glance con le sue finestre (selezione e posizione lette dall'AX del Dock; se non disponibili, stima dall'ordine di uso recente e fumetto al centro).
- ⌥` → griglia delle finestre dell'app in primo piano, **sempre al centro dello schermo** (eccezione voluta alla regola "vicino al cursore"); ` / ⇧` / ← → scorrono, rilasci ⌥ → finestra in primo piano, Esc annulla.
**Non fatto**: sostituire ⌘Tab di sistema (richiede `CGSSetSymbolicHotKeyEnabled`, API privata non approvata).
**API**: CGEventTap (tasti, senza bloccare ⌘Tab), AX, ScreenCaptureKit. **Permessi**: Accessibilità + Registrazione schermo.

### 6. Resource Manager — monitor di sistema compatto
**Flusso**: icona chip in menu bar → pannello al cursore con CPU (totale, per core e, a tendina, per app con gli helper sommati all'app), memoria (totale e, a tendina, per app: `ri_phys_footprint`), potenza (W, batteria), GPU, rete ↓↑, dischi esterni (spazio libero, espelli). Campiona ogni secondo solo mentre il pannello è aperto.
**API** (tutte pubbliche): `host_processor_info`, `host_statistics64`, IORegistry (`AppleSmartBattery`, `IOAccelerator` → `PerformanceStatistics`), `getifaddrs`, `FileManager.mountedVolumeURLs`. **Permessi**: nessuno.

### 7. Gesture — gesture del trackpad via tasti
**Flusso**: un tocco da solo di un tasto modificatore (es. ⌘ destro) esegue l'azione di una gesture: Mostra Scrivania (4 dita verso l'esterno), Mission Control, Finestre dell'app (App Exposé), Apps/Launchpad, Scrivania a sinistra/destra. Mappature configurabili.
**API**: CGEventTap su flagsChanged (tocco = premuto e rilasciato entro 350 ms senza altri tasti); le azioni premono la scorciatoia configurata in Impostazioni › Tastiera (`com.apple.symbolichotkeys`), Mission Control e App si aprono direttamente. Niente API private. **Permessi**: Accessibilità.

### 8. Stay Up — tiene sveglio il Mac
**Flusso**: tazza in menu bar (piena = attivo) → pannello: 15 min, 1 h, 2 h, 5 h, finché non lo spengo; opzione "lascia spegnere lo schermo"; conto alla rovescia.
**API**: `IOPMAssertionCreateWithName` (PreventUserIdleDisplaySleep / PreventUserIdleSystemSleep), rilasciata alla scadenza e in `stop()`. **Permessi**: nessuno.
**Non fatto**: regole automatiche (app aperta, in carica, download) e coperchio chiuso senza monitor (richiede root).

### 9. Clipboard — storico appunti
**Flusso**: ⌃⇧V → lista al cursore, digita per filtrare, ↑↓, ↩ incolla nell'app in primo piano (⌘V simulato), ⇧↩ come testo semplice; clic destro: fissa/elimina. 50 voci + fissate, salvate in `~/Library/Application Support/take-it-easy/clipboard.json` (0600). Salta i tipi `org.nspasteboard.Concealed/Transient/AutoGeneratedType` (password manager). Nel pannello principale: ultime 3 voci.
**API**: polling `NSPasteboard.changeCount` ogni 0,5 s, CGEvent per ⌘V. **Permessi**: Accessibilità. **Non fatto**: immagini e file nello storico.

### 10. Pulizia — tastiera bloccata
**Flusso**: dal pannello principale → overlay al centro con conto alla rovescia; tastiera, modificatori e tasti media bloccati (event tap su keyDown/keyUp/flagsChanged/NX_SYSDEFINED) per 30 s/1 min/2 min; "Fine" col mouse. **Permessi**: Accessibilità.

### Grab — contagocce
⌃⇧C → lente di sistema (`NSColorSampler`) → colore copiato in HEX.

### Mixer — microfono (Hush Mic)
Riga Microfono nel pannello; ⌃⇧M on/off, push-to-talk configurabile (tieni premuto). Mute di `kAudioDevicePropertyMute` sull'ingresso predefinito, fallback volume 0. Microfono rosso in menu bar mentre è spento (clic = riaccendi). `stop()` riaccende quello che abbiamo spento.

### Resource Manager — batterie
Sezione Batterie: dispositivi Bluetooth connessi (AirPods sinistra/destra/custodia, mouse, tastiera) da `system_profiler SPBluetoothDataType -json`, letto ogni 30 s.

### Wheel — Altro
Aggiunte "Terminale" (apre la cartella in Terminale) e "File nascosti" (⌘⇧. del Finder).

### Mixer — luminosità tastiera
Slider "Tastiera" nella sezione Display tramite `KeyboardBrightnessClient` (CoreBrightness, privata, in `PrivateAPI.swift` con fallback: se manca, lo slider non compare).

---

## Backlog (moduli futuri, accendibili quando pronti)
- **Stay Up, regole** — attivazione automatica (app aperta, in carica, download in corso).
- **Split Scroll** — scroll separato mouse/trackpad.
- **Scenes** — layout finestre salvati per configurazione di monitor.
- **Tidy Bar** — separatore minimale per nascondere icone in menu bar.

---

## Fasi

### Fase 0 — Scheletro
- [x] Progetto Xcode, menu bar app, sandbox off, Hardened Runtime, `LSUIElement`.
- [x] `TIEModule`, `ModuleRegistry`, `PermissionCenter`, Settings con lista moduli e toggle persistenti.
- [x] `CursorPanel` + componente toast.
- [x] Avvio al login.
**Done**: compila con `xcodebuild`, i toggle dei moduli (finti) persistono al riavvio.

### Fase 1 — Grab
- [x] Hotkey → overlay di selezione su tutti i display → OCR → appunti → toast.
- [x] QR/barcode, ri-cattura ultima area, opzioni a capo/lingue.
**Done**: testo corretto da un PDF scansionato e da un video in pausa; funziona su monitor esterno.

### Fase 2 — Wheel
- [x] Trigger configurabile via event tap (solo con Finder in primo piano), lettura selezione Finder.
- [x] Rotella radiale al cursore (selezione per direzione, annulla al centro, sottoanello).
- [x] Azioni immagini + PDF; poi "Qualsiasi"; poi video/audio.
- [x] Ricette personalizzate.
**Done**: 5 immagini selezionate → trigger → "→ PDF" → PDF accanto agli originali, senza trascinare nulla.

### Fase 3 — Mixer
- [x] 3a: pannello unico, luminosità display integrato + DDC esterni + fallback software, volume/uscita di sistema.
- [x] 3b: lista app con audio, volume e mute per app tramite process tap, memoria per dispositivo.
**Done**: abbassi solo Spotify mentre Zoom resta al 100%; cambi luminosità del monitor esterno dallo stesso pannello.

### Fase 4 — Peek (ora Glance)
- [x] Rilevamento icona Dock sotto il cursore, miniature finestre, clic per portare in primo piano.
- [x] Finestre minimizzate, filtro per titolo, chiusura con clic centrale.
**Done**: hover sull'icona di Safari con 3 finestre → 3 miniature → clic → finestra giusta in primo piano.

### Fase 5 — Rifinitura e distribuzione
- [ ] Onboarding permessi, icona, firma Developer ID + notarizzazione, pagina GitHub, Sparkle per gli aggiornamenti.

---

## Fuori scopo (per ora)
- Mac App Store (sandbox incompatibile).
- Sync cloud delle impostazioni.
- Manipolare le icone di altre app nella menu bar.

### Fase 6 — Glance, Switch, Resource Manager, Gesture
- [x] Peek → Glance: fumetto con punta sull'icona del Dock.
- [x] Mixer: luminosità tastiera (CoreBrightness).
- [x] Resource Manager: pannello CPU/memoria/potenza/GPU/rete/dischi esterni.
- [x] Switch: anteprime nel ⌘Tab di sistema, ⌥` finestre della stessa app al centro.
- [x] Gesture: tocco di un modificatore → azione gesture, mappature configurabili.
- [x] Resource Manager: memoria per app.
- [x] Stay Up: tiene sveglio il Mac con durata.
**Done**: ⌘Tab mostra le finestre dell'app selezionata sopra la sua icona; ⌥` passa tra due finestre di Safari; tocco ⌘ destro mostra la Scrivania.

### Fase 7 — Menu unico e nuovi moduli
- [x] Pannello principale con controlli rapidi e riquadri; impostazioni con barra laterale; icone proprie opzionali.
- [x] Clipboard, contagocce in Grab, microfono in Mixer, batterie in Resource Manager, Pulizia tastiera, nuove azioni Wheel.
**Done**: una sola icona in menu bar; dal pannello cambi volume, spegni il microfono, vedi CPU e AirPods, accendi Stay Up senza aprire altro.
