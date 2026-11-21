# Hexo 0.5.3 — Standard library

I moduli standard sono sorgenti `.hexo` che usano il bridge nativo incluso nel kit. I percorsi degli import sono relativi alla working directory del processo:

```hexo
import "stdlib/json.hexo" as json;
import "stdlib/tabular.hexo" as table;
```

| Modulo | Dipendenze | Stato reale |
|---|---|---|
| `math` | `libm` | Funzioni matematiche integrate e testate |
| `random` | C runtime | PRNG pseudo-casuale non crittografico |
| `system/os` | C runtime / filesystem | File, directory, ambiente e process helpers |
| `json` | Bridge incluso | Parser e serializer JSON, oggetti e array |
| `tabular` | Bridge incluso | CSV RFC 4180 e tabelle row-oriented con analytics di base |
| `sqlite` | SQLite 3 | Query, prepared statements, bind e transazioni |
| `mysql` | MariaDB Connector/C opzionale | Driver client MySQL/MariaDB con prepared statements e TLS opzionale |
| `mariadb` | MariaDB Connector/C opzionale | Facade compatibile che riesporta il driver `mysql` |
| `hexoweb` | Socket POSIX / bridge incluso | Server HTTP locale sincrono per sviluppo |
| `animath` | SVG / HTML / filesystem | Grafici, primitive SVG, scene container, easing, keyframe e animazioni SVG/SMIL |
| `game` | SDL2 opzionale | Adapter low-level SDL2 con finestra, input ed elementi 2D |
| `simple_game` | raylib opzionale | Facade raylib 2D per finestra, primitive, testo, texture e input |
| `game_3d` | raylib opzionale | Camera, primitive 3D e funzioni vettoriali |
| `simple_game3d` | raylib opzionale | Facade 3D semplificata sopra `game_3d` |

## math

Esporta costanti `PI`, `E`, `TAU`, `DEG_TO_RAD`, `RAD_TO_DEG`; funzioni numeriche (`abs`, `sqrt`, `pow`, `floor`, `ceil`, `round`, `min`, `max`, `trunc`, `sign`); trigonometria (`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`); logaritmi/esponenziali (`log`, `log10`, `exp`); e helper `fmod`, `hypot`, `clamp`, `lerp`, `mapRange`, `toRadians`, `toDegrees`, `factorial`, `gcd`, `lcm`, `distance2D`, `distance3D`, `smoothstep`, `wrap`. Le funzioni trigonometriche accettano radianti.

## random

`random`, `randomInt(min, max)`, `seed(seed)`, `choice(array)`, `uniform(min, max)`, `boolean`, `chance`, `shuffle`, `sample`, `normal(mean, standardDeviation)`, `weightedChoice(values, weights)`. `random()` restituisce un numero in `[0,1)`; `randomInt` include gli estremi. Il generatore non è crittograficamente sicuro.

## system/os

`envGet`, `envSet`, `envUnset`, `currentDirectory`, `fileExists`, `fileSize`, `isDirectory`, `createDirectory`, `removeDirectory`, `listDirectory`, `readText`, `writeText`, `appendText`, `removeFile`, `renameFile`, `pathJoin`, `sleepMs`, `processId`. File I/O testuale sincrono; lettura limitata a 64 MiB. `listDirectory` è attualmente disponibile sui target POSIX (Linux/macOS); nel build Windows restituisce un errore esplicito.

## json

`parse`, `stringify`, `object`, `array`, `get`, `set`, `has`, `keys`, `isObject`, `remove`, `clone`, `parseFile`, `writeFile`, `entries`, `fromPairs`, `getString`, `getNumber`, `getBool`, `merge`, `stringifyPretty`. Gli oggetti sono rappresentati da array interni marcati: usare le funzioni del modulo e non accedere direttamente al marker. Parsing UTF-8/escape Unicode e surrogate pair; limite input 64 MiB e nesting 128.

## tabular

`parseCSV`, `stringifyCSV`, `fromRows`, `readCSV`, `toCSV`, `writeCSV`, `columns`, `rows`, `shape`, `head`, `tail`, `column`, `select`, `sortBy`, `filterEquals`, `inferTypes`, `rowCount`, `columnCount`, `renameColumns`, `castColumn`, `countBy`, `distinct`, `groupByCount`, `dropMissing`, `fillMissing`, `mapColumn`, `numericStats`, `sum`, `mean`, `min`, `max`, `describe`, `toObjects`, `fromObjects`, `unique`, `valueCounts`, `renameColumn`, `dropColumn`, `addColumn`, `join` (inner/left/right/full), `groupByAggregate`, `pivot`, `melt`, `filterRows`, `dropDuplicates`, `rollingMean`.

Il nome scelto è `tabular` (non `pandas`). La struttura è row-oriented, non un DataFrame colonnare ad alte prestazioni. Il parser CSV gestisce campi quotati, quote raddoppiate, CRLF e newline interni ai campi secondo il formato RFC 4180.

## sqlite

`open`, `close`, `exec`/`execute`, `query`/`all`, `prepare`, `bindInt`, `bindFloat`, `bindText`, `bindNull`, `bindBool`, `bindValue`, `bindValues`, `step`, `columnCount`, `columnName`, `column`, `columnType`, `reset`, `finalize`, `changes`, `lastInsertId`, `begin`, `commit`, `rollback`, `transaction`, `withTransaction`, `withDatabase`, `first`, `scalar`, `rows`, `columns`, `queryPrepared`, `executePrepared`, `executeMany`, `queryObjects`, `scalarPrepared`. Chiudere tutti gli statement prima della connessione; `step` restituisce `true` se è disponibile una riga e `false` a fine statement.

## mysql e mariadb

`mysql` usa MariaDB Connector/C, che supporta server MariaDB e MySQL compatibili. `mariadb` riesporta le stesse funzioni come nome alternativo. API: `open`, `openTLS`, `close`, `exec`/`execute`, `query`/`all`, `first`, `scalar`, `error`, `prepare`, `bindInt`, `bindFloat`, `bindText`, `bindNull`, `bindBool`, `bindValue`, `bindValues`, `executeStatement`, `queryStatement`, `closeStatement`, `executePrepared`, `queryPrepared`, `executeMany`, `queryObjects`, `withConnectionTLS`, `begin`, `commit`, `rollback`, `transaction`, `withTransaction`, `withConnection`. `openTLS(host,user,password,database,port,ca,cert,key)` configura la validazione TLS tramite CA e, facoltativamente, certificato/client key. La build è opzionale e richiede `pkg-config libmariadb`; il kit non include il server. Non sono stati eseguiti test end-to-end verso un server remoto nel rilascio.

Utilizzare prepared statements per i valori non attendibili. Chiudere gli statement prima di chiudere la connessione.

## hexoweb

`createApp`, `serve`, `response`, `html`, `text`, `json`, `redirect`, `notFound`, `badRequest`, `serverError`, `escapeHTML`, `urlEncode`, `urlDecode`, `parseQuery`, `parseForm`, `parseJSON`, `parseCookies`, `mimeType`, `render`, `routeParams`, `htmlPage`, `requestInfo`, `jsonBody`, `formBody`, `header`, `cookie`. `App` espone `add`, `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `use`, `serveStatic`, `dispatch`, `listen`. È possibile restituire HTML completo e creare siti con route dinamiche; il template `render` fa solo sostituzione di `{{chiave}}` con escaping, non esegue codice.

**Limiti:** il server si lega esclusivamente a `127.0.0.1`, è sincrono e processa una richiesta per volta; impone limiti a header e body. Non implementa TLS, HTTP/2, chunked request body, worker concorrenti, sessioni/autenticazione, rate limiting o hardening da produzione. È adatto a sviluppo e prototipi locali, non a esporre un servizio su Internet.

## animath

Primitive SVG (`svg`, `line`, `circle`, `ellipse`, `rectangle`, `polygon`, `path`, `text`, `group`), composizione (`axes`, `grid`, `polyline`, `plot`), scene (`Scene`, `createScene`, `add`, `addAll`, `clear`, `content`, `render`, `html`, `save`, `saveHTML`) e output (`saveSVG`, `htmlDocument`, `animationDocument`). Animazione: `animate`, `animateTransform`, `animateMotion`, `keyframe`, `interpolate`, `lerp`, `mapRange`, easing lineari/quadratici/cubici, `scatterPlot`, `parametricPlot`, `barChart`, `histogram`, `lineChart`, `translate`, `rotate`, `scaleElement`. Produce SVG/HTML e animazioni SMIL. Non è un clone completo di Manim: non esegue rendering nativo PNG/video, non ha timeline audio né un renderer 3D.

## game, simple_game, game_3d e simple_game3d

`game` usa SDL2 ed espone lifecycle finestra, eventi di base, input tastiera/mouse, primitive 2D, BMP texture, fullscreen, game controller (ordinali di controller riconosciuti da SDL) e timer. `simple_game` usa raylib e offre finestra, draw cycle, rettangoli/triangoli/ellissi/linee spesse/rounded rect, testo, input tastiera/mouse, camera 2D, timing, texture, font custom, render texture/off-screen rendering, input gamepad e audio (Sound/Music: load/play/pause/resume/stop/unload, volume/pitch/pan e seek per Music; pan normalizzato da -1 a 1), font custom, render texture e input gamepad di base. `game_3d` offre camera prospettica, cubi pieni/wireframe, sfere piene/wireframe, cilindri, piani, griglia, caricamento/rilascio di modelli e disegno di modelli pieni/wireframe con o senza trasformazione (DrawModel/DrawModelEx/DrawModelWires/DrawModelWiresEx), e helper vettoriali `vec3`, `add`, `subtract`, `scale`, `dot`, `cross`, `length`, `normalize`, `distance`, `distanceSquared`, `hadamard`, `rotateX/Y/Z`, `angleBetween`, `project`, `reflect`, `lerp`; `simple_game3d` riesporta queste API con `drawGround` e `withCamera`.

Questi backend sono sottoinsiemi utilizzabili, non implementazioni complete equivalenti a SDL2/SDL3 o raylib. Restano fuori SDL3, SDL_image/SDL_ttf, mixer SDL, font custom, shader, materiali/luci completi, collisioni/fisica, render target, hot-plug controller avanzato, mesh editing/animazione scheletrica e asset pipeline. Le API audio e model-loading di raylib sono presenti, ma richiedono il backend raylib compilato e non sono state collaudate su hardware audio/GPU in questo ambiente. SDL3 non è implementato. Gli SDK sono opzionali e devono essere installati separatamente.

Le risorse native raylib (texture, font, render texture, suoni, stream musicali e modelli) restituiscono handle interi opachi. Ogni handle deve essere rilasciato una sola volta con la funzione `unload*` corrispondente; dopo il rilascio non deve essere riutilizzato. Il bridge audio di Hexo accetta pan in `[-1, 1]` (sinistra-centro-destra) e lo converte per raylib 5.x, che usa la scala `[0, 1]`.
