# Hexo 0.5.3 — stato dei backend nativi e funzionalità ancora mancanti

Questo documento separa le API reali incluse nel kit dalle parti non ancora implementate. Un modulo importabile non implica che replichi l'intero SDK a cui si ispira.

## Database e dati

| Modulo | Implementato | Ancora da completare / verificare |
|---|---|---|
| `json` | Parser e serializer RFC 8259, UTF-8, escape/surrogate, oggetti e array, file, merge e pretty stringify | Tipo Map/Dictionary nativo, streaming di JSON grandi, serializer incrementale |
| `tabular` | Parser/writer CSV RFC 4180, row storage, select/sort/filter, inferenza/cast, join inner/left/right/full, group-by aggregato, pivot/unpivot, rolling mean e statistiche | Storage colonnare, indici, query engine e grandi dataset |
| `sqlite` | Query, prepared statements tipizzati, bindValues, queryPrepared, executePrepared, executeMany transazionale, queryObjects e transazioni | Test di stress multi-connessione, streaming risultati e gestione avanzata blob |
| `mysql` / `mariadb` | MariaDB Connector/C opzionale, query/exec, prepared statements tipizzati, queryPrepared, executePrepared, executeMany transazionale, queryObjects e `openTLS` | Test end-to-end con server live MariaDB e MySQL, CA/client cert in ambienti reali, reconnect, timeout configurabili, cancellation, più result set e mapping tipi binari/decimal |

Il kit non include un server MySQL/MariaDB. Il connector client è disponibile solo se il build trova `libmariadb` tramite `pkg-config`.

## Web

### `hexoweb` — server HTTP locale per sviluppo

Implementato: server socket sincrono, bind esclusivo a `127.0.0.1`, route con parametri, middleware, GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS, 405 con `Allow`, parsing query/form/JSON/cookie, response status/header, redirect, escaping HTML, template interpolation semplice e static file.

Manca: TLS, HTTPS, HTTP/2, body chunked, keep-alive, worker/async I/O, request timeout configurabile, upload streaming, sessioni, auth, CSRF, rate limit, compressione, reverse-proxy awareness e hardening per deployment pubblici. Il server non è un sostituto production-ready di Django/Flask; non esporlo direttamente su Internet.

## Animazione e grafica

### `animath` — generazione SVG/SMIL

Implementato: primitive SVG, gruppi, assi/griglia, plot via callback, scatter/parametric plot, bar chart, histogram, line chart, interpolazione, keyframe, easing lineari/quadratici/cubici, animate/animateTransform/animateMotion, output SVG/HTML.

Manca: scene graph generale simile a Manim, camera/coordinate system estese, renderer raster frame-by-frame, compositing, audio timeline, esportazione PNG/MP4 integrata e test visual regression. `ffmpeg` può essere usato esternamente da una pipeline futura, ma il modulo corrente non lo chiama.

### `game` — SDL2 (non SDL3)

Implementato: apertura/chiusura finestra, polling eventi base, tastiera/mouse, resize/quit, clear/present, line/rect/circle, BMP texture, fullscreen, controller SDL_GameController (count/open/button/axis/close, ordinati per controller riconosciuto) e timer/delay.

Manca: backend SDL3 dedicato, PNG/JPEG (SDL_image), font/TTF, render target, audio/mixer, clipboard, touch, display enumeration, controller hot-plug/event mapping avanzato e binding per il set completo di eventi/risorse SDL.

### `simple_game` — raylib 2D

Implementato: window lifecycle, begin/end drawing, clear, rectangle/line/circle/triangle/ellipse/line-thick/rounded-rectangle/text, input tastiera e mouse, camera 2D, FPS/frame time, target FPS, texture load/draw/unload, title/fullscreen e resize; audio raylib (device lifecycle, Sound e Music stream con play/pause/resume/stop, volume/pitch/pan e seek); font custom; render target/off-screen drawing; input gamepad (availability, button state, axis and name).

Manca: shader, sprite batching, animazioni, gamepad hot-plug/eventi estesi, gesture, file/image loading esteso, GUI controls e gestione automatica delle risorse. Render targets, custom font e input base gamepad sono presenti ma richiedono test su backend raylib reale. Le API audio sono presenti ma la riproduzione su device reale non è stata testata qui.

### `game_3d` e `simple_game3d` — raylib 3D

Implementato: camera prospettica, begin/end 3D, DrawCube/DrawSphere/DrawGrid e primitive addizionali (plane, wireframe cube/sphere, cylinder); caricamento/rilascio modelli e disegno pieno/wireframe con trasformazione (DrawModel, DrawModelEx, DrawModelWires, DrawModelWiresEx), oltre a helper vettoriali `vec3`, `add`, `subtract`, `scale`, `dot`, `cross`, `length`, `normalize`, `distance`, `lerp`.

Manca: matrix/quaternion API completa, gestione materiali e luci, shader, skybox, render textures, collision detection/ray casting, fisica, animazione scheletrica e GPU resource manager. Le API Model sono esposte, ma non sono ancora coperte animazioni scheletriche e gestione dei materiali/texture dei modelli.

Gli SDK SDL2/raylib sono opzionali, rilevati con `pkg-config`. Le API native grafiche di questo ambiente non sono state collaudate perché gli SDK non erano installati; soltanto la compilazione degli stub e i test di import/backend availability sono stati verificati. SDL3 non è presente.

## Criteri per chiamare una libreria “completa”

1. Specifica pubblica dell'API, senza stub non documentati.
2. Copertura dei principali sottosistemi e lifecycle delle risorse.
3. Test automatici su backend nativi reali, non solo compile check o import.
4. Test per errori, input limite, ripetizione create/use/destroy e leaks.
5. Build/test su ogni OS e versione SDK dichiarata supportata.
6. Documentazione di dipendenze, ABI, thread-safety, limiti e sicurezza.

Hexo 0.5.3 non dichiara SDL2/3, raylib, Animath o Hexoweb completi rispetto ai framework di riferimento. Le API presenti sono utilizzabili entro i limiti sopra descritti.
