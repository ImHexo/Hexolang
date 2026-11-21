# Hexo Language Support — VS Code 0.5.3

Supporto editor per Hexo 0.5.3: evidenziazione, snippet, completamento, hover, Signature Help e navigazione tra moduli. La cartella `stdlib/` è sincronizzata con la libreria standard del Development Kit 0.5.3 e consente IntelliSense anche quando il workspace non contiene una propria copia di `stdlib/`.

## Funzionalità

- Syntax highlighting per keyword, tipi, puntatori (`*`/`&`), interi esadecimali, visibilità `public`/`private` e import.
- Snippet per funzioni, classi, cicli, gestione errori, import, puntatori e file I/O.
- Completamento delle API esportate da `math`, `random`, `system/os`, `json`, `tabular`, `sqlite`, `mysql`, `mariadb`, `hexoweb`, `animath`, `game`, `simple_game`, `game_3d` e `simple_game3d`.
- Completamento dei percorsi `.hexo`, dei nomi dopo `from ... import` e dei membri dopo `alias.`.
- Hover e Go to Definition per simboli importati e funzioni/metodi definiti nei moduli bundled.
- Signature Help per funzioni e metodi i cui sorgenti sono indicizzati.

## Avvio

Apri questa cartella in VS Code e premi `F5`. La nuova finestra Extension Development Host contiene l'estensione in esecuzione. Gli esempi aggiornati sono nella cartella `examples/`.

Per controllare il codice e i dati:

```sh
npm run check
```

Per creare un pacchetto VSIX, con Node.js/npm e accesso al registry configurati:

```sh
npm run package
```

## Libreria standard bundled

Il bundle `stdlib/` è usato per analisi statica e IntelliSense. Per il Development Kit 0.5.3 è copiato dai sorgenti `stdlib/` nella radice del kit. Se il workspace contiene un modulo allo stesso percorso, la copia del workspace ha precedenza; altrimenti viene usata la copia bundled. Questo fallback dell'editor non cambia la risoluzione dei percorsi nel runtime: per eseguire il programma, Hexo deve avere la directory `stdlib/` raggiungibile dalla working directory del processo.

I backend grafici e MariaDB sono opzionali: VS Code mostra gli export descritti dai sorgenti, ma non installa SDK, non compila adapter nativi e non rende disponibile un backend non presente nella build di Hexo. I moduli SDL2/raylib sono sottoinsiemi documentati, non binding completi equivalenti agli SDK originali. `hexoweb` è un server locale sincrono per sviluppo; `animath` produce SVG/SMIL e non è un renderer video completo.

## Limiti

L'estensione non è un language server completo: non esegue il codice, non fa type checking semantico globale, non offre debugger o refactoring. L'indicizzazione è statica e basata sulle forme di dichiarazione riconosciute dal parser dell'estensione; non risolve in generale scope complessi, alias dinamici, import riesportati ricorsivi o espressioni arbitrarie. La diagnostica semantica e il debugging sono fuori ambito.
