# Hexo 0.5.3 — Runtime, librerie standard e toolchain

Hexo è un linguaggio di scripting gradualmente tipizzato con interprete x86-64 Assembly e bridge nativo C. Questo kit riunisce runtime, moduli `.hexo`, adapter nativi, esempi, test automatici ed estensione VS Code.

**Nota sul livello di completezza:** la libreria standard contiene moduli operativi per math, random, filesystem/OS, JSON, CSV/tabular, SQLite, driver MySQL/MariaDB, server HTTP locale e generazione SVG. I backend grafici SDL2/raylib e 3D sono sottoinsiemi concreti, ma non coprono ancora l'intero SDK di riferimento. `animath` produce SVG/SMIL ma non è un renderer video completo. `hexoweb` è un server locale per sviluppo, non un server production.

## Build

Requisiti base: GCC o Clang, SQLite 3, `libm`, `make` e `pkg-config` (per rilevare i backend opzionali).

```sh
make TARGET=hexo
make TARGET=hexo config
./hexo --version
make TARGET=hexo test
```

Per build manuale senza adapter opzionali:

```sh
clang -O2 -Wall -Wextra Hexo_0.5.3.S native/hexo_native.c native/hexo_game.c \
  -o hexo -lm -lsqlite3
```

Il Makefile abilita automaticamente i componenti per cui trova i file `.pc`:

- `libmariadb` → driver client `mysql`/`mariadb`;
- `sdl2` → backend low-level `game`;
- `raylib` → `simple_game`, `game_3d` e `simple_game3d`.

Su macOS Intel il target è x86-64. Con MacPorts, verifica che i file `pkg-config` siano visibili; se necessario:

```sh
export PKG_CONFIG_PATH="/opt/local/lib/pkgconfig:/opt/local/share/pkgconfig:${PKG_CONFIG_PATH:-}"
make TARGET=hexo config
make TARGET=hexo
```

Puoi usare `port search sqlite3`, `port search mariadb-connector-c`, `port search sdl2` e `port search raylib` per trovare i nomi esatti dei port disponibili nella tua installazione MacPorts. Gli SDK grafici e MariaDB sono opzionali. Senza il relativo SDK, le funzioni native del modulo restituiscono un errore esplicito oppure `backend()` indica che il backend non è disponibile.

Il runtime è x86-64: su MacBook Intel è l'architettura prevista. Il kit è stato compilato e testato in Linux x86-64; la build macOS nativa deve ancora essere verificata sul Mac di destinazione.

## Esecuzione

Esegui i programmi dalla radice del kit, così gli import relativi a `stdlib/` vengono risolti correttamente:

```sh
./hexo examples/pointers_visibility.hexo
./hexo examples/json_extended.hexo
./hexo examples/tabular_analytics.hexo
./hexo examples/tabular_advanced.hexo
./hexo examples/animath_advanced.hexo
./hexo examples/sqlite.hexo
./hexo examples/animath_timeline.hexo
```

## Linguaggio

- Puntatori gestiti a l-value: `ptr p = &value;`, dereferenziazione e assegnazione con `*p`. Non sono indirizzi C grezzi: niente pointer arithmetic o accesso arbitrario alla memoria.
- Letterali interi esadecimali, ad esempio `0xff0000` e `0XFF0000`.
- Modificatori `public` e `private` per membri di classi; i membri sono pubblici per default.
- Moduli con `import "stdlib/math.hexo" as math;` e `from "stdlib/random.hexo" import choice;`.

## Librerie

| Modulo | Stato | API e limiti |
|---|---|---|
| `math` | Integrato | `libm`, trigonometria, logaritmi, funzioni iperboliche, interpolazione, statistiche elementari e vettori 2D/3D |
| `random` | Integrato | PRNG, seed, scelta, shuffle, sample, uniforme, normale; non crittografico |
| `system/os` | Integrato | File testuali, directory, env vars, cwd, path, process ID e sleep; su Windows `listDirectory` non è ancora implementato |
| `json` | Integrato | Parsing/serializzazione RFC 8259, oggetti, array, file, merge, pretty stringify; gli oggetti sono array marcati interni |
| `tabular` | Integrato | CSV RFC 4180, tabelle row-oriented, filtri, sorting, cast, raggruppamento e statistiche; non è Pandas/Arrow |
| `sqlite` | Integrato | Query, prepared statements, binding tipizzato e transazioni su SQLite 3 |
| `mysql` | Opzionale | Driver MariaDB Connector/C per server MySQL/MariaDB compatibili, prepared statements e apertura TLS; nessun server incluso |
| `mariadb` | Opzionale | Facade con gli stessi binding del driver `mysql` |
| `hexoweb` | Integrato, solo sviluppo locale | Server HTTP sincrono su `127.0.0.1`, route GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS, middleware, form/JSON/query/cookie, HTML, redirect e file statici |
| `animath` | Integrato, SVG/SMIL | Forme, assi, griglie, plot, scene container (`Scene`), easing, keyframe e documenti SVG/HTML; non esporta video o PNG nativamente |
| `game` | SDL2 opzionale | Finestra, eventi base, tastiera/mouse, primitive 2D e timing; non equivale all'intera SDL2 e non implementa SDL3 |
| `simple_game` | raylib opzionale | Finestra, primitive 2D, font custom, render texture, gamepad, audio Sound/Music e input; sottoinsieme raylib |
| `game_3d` | raylib opzionale | Camera prospettica, primitive 3D, caricamento modelli, DrawModel/Ex/Wires e helper vettoriali |
| `simple_game3d` | raylib opzionale | Facade 3D semplificata, camera, modelli, trasformazioni e cleanup tramite `withCamera` |

API complete e firme sono documentate in [`stdlib/README.md`](stdlib/README.md); prerequisiti e funzionalità mancanti dei backend sono in [`BACKENDS_ROADMAP.md`](BACKENDS_ROADMAP.md).

### Esempi raylib avanzati

Con raylib installato e rilevato da `pkg-config`, puoi provare gli esempi interattivi:

```sh
./hexo examples/simple_game_advanced.hexo
./hexo examples/simple_game3d_models.hexo
```

Il primo usa render texture, audio e gamepad; il secondo carica il modello OBJ incluso negli asset. Le risorse native devono essere rilasciate esplicitamente (`unloadSound`, `unloadRenderTexture`, `unloadModel`, `unloadFont`). I pan audio di Hexo accettano `-1` (sinistra), `0` (centro) e `1` (destra); il bridge normalizza il valore per le versioni precedenti di raylib.

### JSON e tabular

```hexo
import "stdlib/json.hexo" as json;
import "stdlib/tabular.hexo" as table;

let value = json.parse("{\\"name\\":\\"Hexo\\",\\"ok\\":true}");
print(json.stringifyPretty(value));

let rows = table.parseCSV("name,score\\nAda,9\\nLinus,8\\n");
let data = table.fromRows(rows, true);
print(table.describe(data));
```

`tabular` è il nome scelto al posto di `pandas`: include tabelle row-oriented, CSV RFC 4180, filtri, join, group-by con aggregazioni, pivot/unpivot, rolling mean e statistiche. Non promette la semantica o le prestazioni di Pandas/Arrow.

### SQLite e MySQL/MariaDB

Chiudi statement e connessioni esplicitamente. Per dati esterni usa prepared statements e bind, non concatenazione SQL. SQLite espone `bindValue`/`bindValues`, `queryPrepared`, `executePrepared`, `executeMany`, `queryObjects` e `scalarPrepared`; i driver MySQL/MariaDB forniscono `bindValue`, `queryPrepared`, `executePrepared`, `executeMany`, `queryObjects` e `withConnectionTLS`. SQLite usa la libreria `sqlite3`; MySQL/MariaDB usa il client Connector/C opzionale. `mysql.openTLS(host,user,password,database,port,ca,cert,key)` abilita TLS con CA e, facoltativamente, certificato client e chiave. Il test della connessione TLS contro server live resta da effettuare.

### Hexoweb

`hexoweb` può creare siti HTML, route, middleware e gestire i metodi HTTP principali. Il listener nativo è intenzionalmente locale: si lega a `127.0.0.1`, è sincrono e serve una richiesta per volta. Non ha TLS, HTTP/2, chunked body, worker, session store, autenticazione, rate limiting o hardening da produzione. Non esporlo direttamente su Internet. L'helper `render` sostituisce `{{chiave}}` con escaping; non esegue template code.

### Animath e grafica

`animath` genera disegni e animazioni vettoriali SVG/SMIL e include un contenitore `Scene` per comporre, renderizzare e salvare scene. Non è un clone completo di Manim: manca un motore di rendering raster/video e una timeline audio. `game` è un adapter SDL2, mentre i moduli `simple_game*` e `game_3d` usano raylib se installato. Restano fuori diverse parti avanzate come SDL3, shader, sprite batching, mesh editing, materiali/luci completi, collisioni, fisica e asset pipeline. Il backend raylib espone audio Sound/Music, font custom, render texture, gamepad di base e caricamento/disegno modelli, ma non è un binding completo dell’intero SDK. Vedi `BACKENDS_ROADMAP.md`.

## Test

```sh
make TARGET=hexo test
```

I test runtime verificano import, puntatori/visibilità, math, random, filesystem/OS, JSON, CSV/tabular, SQLite, Animath (primitive, easing, timeline e `Scene`), 2D/3D helper, import MySQL/MariaDB e stato dei backend. Il test HTTP avvia il server locale e verifica GET, POST form, POST JSON, PUT, PATCH, DELETE, HEAD, redirect, file statici, HTML, cookie/header, 405 e OPTIONS. La suite VS Code è separata:

```sh
cd vscode-extension
npm run check
```

## VS Code

L'estensione è in `vscode-extension/`. Apri quella cartella in VS Code e premi `F5` per usare l'Extension Development Host. Puoi anche creare un VSIX quando `@vscode/vsce` è disponibile:

```sh
npm run package
```

L'estensione include una copia della standard library per completion, hover e Go to Definition; non installa né compila il runtime o gli SDK nativi.

## Estensione 0.5.3

Il backend raylib espone ora audio `Sound`/`Music`, font custom, render texture/off-screen drawing, input gamepad, caricamento/rilascio modelli 3D e varianti `DrawModelEx`/wireframe. Le API sono condizionate alla build con raylib; in questo ambiente sono state verificate le stub e l’importabilità, non una sessione grafica/audio reale.

## macOS (MacPorts) build notes

Hexo's native adapters use `pkg-config` to discover optional dependencies. On a
MacPorts installation, make sure the MacPorts pkg-config directory is visible:

```sh
export PKG_CONFIG_PATH="/opt/local/lib/pkgconfig:/opt/local/share/pkgconfig:${PKG_CONFIG_PATH}"
make config
make clean
make CC=clang
```

For raylib 5.5 and later, the resource-validation API is named `Is*Valid`
(`IsTextureValid`, `IsSoundValid`, `IsMusicValid`, `IsFontValid`, and
`IsRenderTextureValid`). Older releases use the corresponding `Is*Ready`
functions. The Makefile compiles `native/raylib_api_probe.c` in syntax-only mode against
the installed `raylib.h` and sets `HX_RAYLIB_VALID_API` automatically, rather
than embedding a multi-line C snippet inside `$(shell ...)` (which older GNU
make builds on macOS can fail to parse). `make config` prints the selected API
family. If the probe cannot find the MacPorts header, check `PKG_CONFIG_PATH`
or explicitly pass `RAYLIB_VALID_API=1` when using raylib 5.5+.

The HTTP server binds to the IPv4 loopback address `127.0.0.1` directly. This
avoids relying on `INADDR_LOOPBACK`, which can be hidden by Darwin's feature
profile when `_POSIX_C_SOURCE` is enabled.

**License**

Hexolang is licensed under the Apache License 2.0.
Originally created by ImHexo.
Copyright (c) 2026 ImHexo.
