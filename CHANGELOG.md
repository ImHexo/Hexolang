# Hexo Runtime Changelog

## 0.5.3

- Esteso `simple_game` con Sound/Music, master volume, font custom, render texture e input gamepad.
- Esteso `game_3d`/`simple_game3d` con load/unload model, DrawModelEx e varianti wireframe.
- Normalizzato il pan audio fra raylib 5.x e 6.x e aggiornati i controlli di validità delle risorse per l’API raylib 6.
- Aumentata la capacità dell’indice dei nomi internati e aggiunta una guardia automatica contro gli overflow.
- Aggiunti esempi di render target/audio e caricamento di modelli OBJ.
- Allineata l'estensione VS Code alla 0.5.3 con bundle standard library ed esempi sincronizzati; aggiunti test sugli export raylib, database, Animath, tabular e Hexoweb.

## 0.5.2

- Aggiunti helper typed per query, batch e materializzazione a oggetti nei driver SQLite e MySQL/MariaDB.
- Esteso `tabular` con group-by aggregato, pivot/unpivot, filter callback, deduplicazione e rolling mean.
- Esteso `animath` con scatter plot, curve parametriche, bar chart, istogrammi e line chart.
- Estesi `simple_game`/`game_3d` con primitive 2D, camera 2D, primitive 3D wireframe e cilindri/piani.
- Esteso `game` SDL2 con texture BMP, fullscreen e controller base.
- Aggiornati esempi, test e IntelliSense VS Code alla standard library 0.5.2.

## 0.5.1

- Estesi i moduli `json`, `tabular`, `sqlite`, `mysql` e `mariadb` con helper di uso comune.
- Esteso `system/os` con directory, variabili d’ambiente e funzioni di processo.
- Esteso `hexoweb` con routing HTTP, HTML, cookie, status e header; server locale sincrono per sviluppo.
- Aggiunti helper 2D/3D e funzioni di input/evento per gli adapter SDL2/raylib.
- Esteso `animath` con easing, keyframe, timeline helpers e classe `Scene` per composizione SVG/HTML.
- Sincronizzata la libreria standard bundled dell’estensione VS Code.
- Corretto `make clean` in modo che rimuova il target runtime effettivo.

## 0.5.0

- Aggiunti binding nativi per JSON, CSV/tabular, SQLite, MariaDB Connector/C, HTTP locale, SDL2 e raylib.

## 0.4.0

- Aggiunti puntatori gestiti, letterali esadecimali e visibilità `public`/`private`.


## 0.5.3 — macOS / MacPorts compatibility fix

- Use the IPv4 loopback address directly so the Hexoweb socket backend builds
  when Darwin hides `INADDR_LOOPBACK` under `_POSIX_C_SOURCE`.
- Detect raylib's `Is*Valid` versus legacy `Is*Ready` API by compiling a small
  declaration probe against the installed header. This supports packaged
  raylib 5.5+ headers that do not define `RAYLIB_VERSION_MAJOR`.
- Apply the selected validation function consistently to textures, sounds,
  music, fonts, and render textures.
- Remove the SDL scancode signedness warning.


## 0.5.3 — Makefile portability follow-up

- Move the raylib API feature probe into `native/raylib_api_probe.c`.
- Avoid embedding C parentheses and multiline quoted source inside a Make
  `$(shell ...)` expression, fixing GNU make parse failures on macOS.
