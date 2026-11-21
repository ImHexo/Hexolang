# Changelog

## 0.5.3

- Sincronizzato il bundle `stdlib/` con Hexo Runtime 0.5.3.
- Aggiornati `game_3d`, `simple_game` e `simple_game3d` con gli export raylib aggiunti nel runtime: modelli 3D, trasformazioni, audio Sound/Music, font, render texture e input gamepad.
- Aggiornati gli esempi dell'estensione con i programmi e gli asset del kit 0.5.3.
- Allineati manifest, documentazione e test alla versione 0.5.3.

## 0.5.2

- Aggiornato il catalogo IntelliSense alla libreria standard 0.5.2.
- Aggiunti helper prepared per SQLite e MySQL/MariaDB (`bindValue`, `queryPrepared`, `executeMany`, `queryObjects`).
- Esteso `tabular` con aggregazioni group-by, pivot/unpivot, filtri callback, deduplicazione e rolling mean.
- Esteso `animath` con scatter/parametric plot, bar chart, histogram e line chart.
- Aggiunti esempi e test automatici per le nuove API.

## 0.5.0

- Aggiornata l'estensione al runtime Hexo 0.5.0.
- Bundled e indicizzati i moduli standard: JSON, tabular/CSV, SQLite, MySQL/MariaDB, Hexoweb, Animath, SDL2 adapter, raylib 2D e 3D.
- Aggiunto fallback IntelliSense sui moduli standard bundled quando il workspace non contiene una propria cartella `stdlib/`.
- Completamento dei path dei moduli standard e risoluzione Go to Definition verso i file bundled.
- Aggiornata la documentazione sui backend opzionali e sui limiti dei moduli.

## 0.4.0

- Aggiunti supporto ai puntatori Hexo, letterali esadecimali e modificatori `public`/`private`.
- Migliorata l'inferenza per membri di classi e moduli.

## 0.3.0

- Aggiunte keyword `import`, `from` e `as`, snippet e completamenti per moduli.
- Aggiunti hover e Go to Definition per i simboli importati.
