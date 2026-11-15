# CLAUDE.md — take-it-easy

App macOS da menu bar, modulare. Leggi `PLAN.md` prima di ogni task: architettura, moduli (Grab, Wheel, Mixer, Glance, Switch, Resource Manager, Gesture, Stay Up, Clipboard, Pulizia) e fasi.

## Stack
- Swift 6, SwiftUI + AppKit, target **macOS 14.2+**.
- App Sandbox **disattivata**, Hardened Runtime attivo, `LSUIElement = YES`.
- Dipendenze via Swift Package Manager; unica ammessa di default: `KeyboardShortcuts`. Chiedi prima di aggiungerne altre.
- API private consentite solo dove indicato in `PLAN.md` (DisplayServices, IOAVService per DDC, CoreBrightness per la luminosità tastiera). Isolale in un unico file per modulo (`PrivateAPI.swift`) caricandole con `dlopen`/`dlsym`, con fallback se mancano.

## Build e verifica
- Compila sempre prima di dire che un task è finito:
  `xcodebuild -project TakeItEasy.xcodeproj -scheme TakeItEasy -configuration Debug build`
- Se la build fallisce, leggi l'errore e correggi; non lasciare codice che non compila.
- Permessi (Accessibilità, Registrazione schermo, Automazione Finder, Registrazione audio) non sono testabili da terminale: alla fine di ogni task scrivi una checklist di test manuali.
- Ricorda all'utente che dopo una ricompilazione i permessi TCC possono invalidarsi: `tccutil reset All <bundle-id>` e riconcederli.

## Regole di codice
- Ogni modulo vive in `Modules/<Nome>/` e implementa `TIEModule`. Nessun modulo importa un altro modulo; il codice condiviso sta in `Core/`.
- `start()` / `stop()` idempotenti; `stop()` ripristina tutto (event tap rimossi, tap audio distrutti e volumi a 100%, luminosità/gamma originali).
- Mai chiedere permessi all'avvio: solo all'attivazione del modulo, passando da `PermissionCenter`.
- Una sola icona in menu bar (il pannello principale): i moduli espongono controlli rapidi con `quickView()`; un'icona propria solo come opzione (`PinnableStatusItem`, spenta di default).
- Pannelli/overlay: `NSPanel` non attivanti, posizionati sul cursore tramite `CursorPanel` (eccezioni volute: i fumetti di Glance/⌘Tab ancorati all'icona, lo switcher ⌥` e l'overlay di Pulizia al centro dello schermo); devono funzionare su più display e con Spaces a schermo intero.
- UI e stato su `@MainActor`; OCR, conversioni, cattura miniature e audio fuori dal main thread. Il callback IOProc audio non deve allocare né bloccare.
- Mai sovrascrivere i file originali (Wheel): output accanto con suffisso, es. `nome (take-it-easy).pdf`.
- Niente rete, niente telemetria.
- Codice e commenti in inglese; testi UI in italiano con `String(localized:)`.

## Modo di lavorare
- Una fase o un sotto-punto alla volta, seguendo `PLAN.md`; spunta le checkbox completate.
- Modifiche piccole e incrementali; se un task tocca più moduli o `Core/`, proponi prima un piano.
