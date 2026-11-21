'use strict';

// Riferimento statico alle parole chiave e alle API native e moduli standard descritti
// nella documentazione dell'interprete Hexo 0.5.3.
const KEYWORDS = {
  import: 'Carica un modulo: `import \"percorso.hexo\" as alias;`. Il modulo è esposto tramite il namespace indicato.',
  from: 'Importa nomi specifici da un modulo: `from \"percorso.hexo\" import funzione, Classe;`.',
  as: 'Assegna un alias al namespace creato da `import`.',
  public: 'Dichiara esplicitamente pubblico un campo o metodo di classe. I membri sono pubblici per impostazione predefinita.',
  private: 'Rende privato un campo o metodo di classe: è accessibile soltanto dai metodi della classe che lo dichiara.',
  let: 'Dichiara una variabile: `let [Tipo] nome [= valore]`.',
  const: 'Dichiara una costante (richiede sempre un inizializzatore).',
  fn: 'Dichiara una funzione: `fn [TipoRitorno] nome(params) [-> Tipo] { ... }` oppure `fn nome(params) => espressione`. Senza nome è una funzione anonima.',
  return: 'Termina la funzione restituendo un valore.',
  if: 'Esecuzione condizionale: `if (cond) { ... } else { ... }`.',
  else: 'Ramo alternativo di un `if`.',
  while: 'Ciclo: `while (cond) { ... }`.',
  for: 'Ciclo `for (init; cond; incr) { ... }` oppure `for (let x in iterabile) { ... }`.',
  in: 'Usato nei cicli `for (x in iterabile)`.',
  break: 'Esce dal ciclo corrente.',
  continue: 'Passa all’iterazione successiva del ciclo.',
  class: 'Dichiara una classe: `class Nome [extends Base] { campi e metodi }`. Il costruttore è il metodo `init`.',
  struct: 'Dichiara uno struct (come `class`, con semantica di struttura dati).',
  extends: 'Indica la classe base: `class B extends A { ... }`.',
  super: 'Accede ai metodi della classe base: `super.metodo(...)`.',
  this: 'L’istanza corrente all’interno di un metodo.',
  static: 'Rende statico un campo o metodo di classe.',
  is: 'Controllo di tipo: `valore is Tipo`.',
  try: 'Blocco protetto: `try { ... } catch (e) { ... } finally { ... }`.',
  catch: 'Gestisce un errore sollevato nel `try`: `catch (e) { ... }`.',
  finally: 'Blocco eseguito sempre dopo `try`/`catch`.',
  throw: 'Solleva un errore: `throw valore`.',
  true: 'Valore booleano vero.',
  false: 'Valore booleano falso.',
  nil: 'Il valore nullo.'
};

const KEYWORD_SET = new Set(Object.keys(KEYWORDS));

const TYPE_NAMES = {
  int: 'Intero a 64 bit.',
  float: 'Numero in virgola mobile (double).',
  number: 'Unione di `int` e `float`.',
  string: 'Stringa di testo.',
  bool: 'Booleano (`true` / `false`).',
  any: 'Qualsiasi valore (nessun controllo di tipo).',
  void: 'Nessun valore restituito.',
  function: 'Qualsiasi funzione. Per un tipo preciso: `fn(int, string) -> bool`.',
  ptr: 'Puntatore Hexo a un l-value. `&variabile` ottiene l’indirizzo e `*puntatore` legge o modifica il valore referenziato.',
  nil: 'Il tipo del valore `nil`. `T?` equivale a `T | nil`.'
};

const TYPEOF_NAMES = ['nil', 'bool', 'int', 'float', 'string', 'array', 'function', 'class', 'instance', 'module', 'ptr'];

const P = (name, type = 'any', optional = false) => ({ name, type, optional });

const GLOBAL_FUNCTIONS = {
  print: { params: [P('...valori')], min: 0, max: -1, returns: 'nil', doc: 'Stampa i valori su stdout (separati da spazio) e va a capo.' },
  input: { params: [P('prompt', 'string', true)], min: 0, max: 1, returns: 'string', doc: 'Legge una riga da stdin, mostrando facoltativamente un prompt.' },
  len: { params: [P('valore')], min: 1, max: 1, returns: 'int', doc: 'Lunghezza di una stringa o di un array.' },
  typeof: { params: [P('valore')], min: 1, max: 1, returns: 'string', doc: 'Nome del tipo di un valore: `nil`, `bool`, `int`, `float`, `string`, `array`, `function`, `class`, `instance`.' },
  int: { params: [P('valore')], min: 1, max: 1, returns: 'int', doc: 'Converte un valore (numero o stringa) in intero.' },
  float: { params: [P('valore')], min: 1, max: 1, returns: 'float', doc: 'Converte un valore (numero o stringa) in float.' },
  string: { params: [P('valore')], min: 1, max: 1, returns: 'string', doc: 'Converte un valore in stringa.' },
  bool: { params: [P('valore')], min: 1, max: 1, returns: 'bool', doc: 'Converte un valore in booleano.' },
  range: { params: [P('inizio', 'int'), P('fine', 'int', true), P('passo', 'int', true)], min: 1, max: 3, returns: 'int[]', doc: 'Genera un array di interi. `range(stop)`, `range(start, stop)` o `range(start, stop, step)`.' },
  abs: { params: [P('x', 'number')], min: 1, max: 1, returns: 'number', doc: 'Valore assoluto.' },
  sqrt: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Radice quadrata.' },
  pow: { params: [P('base', 'number'), P('esponente', 'number')], min: 2, max: 2, returns: 'number', doc: 'Elevamento a potenza.' },
  sin: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Seno di x espresso in radianti.' },
  cos: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Coseno di x espresso in radianti.' },
  tan: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Tangente di x espresso in radianti.' },
  asin: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Arcoseno, risultato in radianti.' },
  acos: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Arcocoseno, risultato in radianti.' },
  atan: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Arcotangente, risultato in radianti.' },
  atan2: { params: [P('y', 'number'), P('x', 'number')], min: 2, max: 2, returns: 'float', doc: 'Arcotangente a due argomenti, risultato in radianti.' },
  sinh: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Seno iperbolico.' },
  cosh: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Coseno iperbolico.' },
  tanh: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Tangente iperbolica.' },
  log: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Logaritmo naturale.' },
  log10: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Logaritmo in base 10.' },
  exp: { params: [P('x', 'number')], min: 1, max: 1, returns: 'float', doc: 'Esponenziale e elevato a x.' },
  fmod: { params: [P('a', 'number'), P('b', 'number')], min: 2, max: 2, returns: 'float', doc: 'Resto in virgola mobile, secondo la semantica di fmod.' },
  hypot: { params: [P('x', 'number'), P('y', 'number')], min: 2, max: 2, returns: 'float', doc: 'Ipotenusa calcolata in modo numericamente stabile.' },
  envGet: { params: [P('nome', 'string')], min: 1, max: 1, returns: 'string | nil', doc: 'Legge una variabile d’ambiente; restituisce nil se non è definita.' },
  fileExists: { params: [P('percorso', 'string')], min: 1, max: 1, returns: 'bool', doc: 'Verifica se il percorso può essere aperto come file in lettura.' },
  readText: { params: [P('percorso', 'string')], min: 1, max: 1, returns: 'string', doc: 'Legge un file di testo (limite runtime: 64 MiB).' },
  writeText: { params: [P('percorso', 'string'), P('contenuto', 'string')], min: 2, max: 2, returns: 'int', doc: 'Sovrascrive un file di testo e restituisce i byte scritti.' },
  appendText: { params: [P('percorso', 'string'), P('contenuto', 'string')], min: 2, max: 2, returns: 'int', doc: 'Aggiunge testo in fondo a un file e restituisce i byte scritti.' },
  removeFile: { params: [P('percorso', 'string')], min: 1, max: 1, returns: 'bool', doc: 'Rimuove un file; restituisce false se l’operazione fallisce.' },
  renameFile: { params: [P('origine', 'string'), P('destinazione', 'string')], min: 2, max: 2, returns: 'bool', doc: 'Rinomina o sposta un file.' },
  currentDirectory: { params: [], min: 0, max: 0, returns: 'string', doc: 'Restituisce la working directory del processo.' },
  floor: { params: [P('x', 'number')], min: 1, max: 1, returns: 'number', doc: 'Arrotonda per difetto (restituisce `int` quando rappresentabile).' },
  ceil: { params: [P('x', 'number')], min: 1, max: 1, returns: 'number', doc: 'Arrotonda per eccesso (restituisce `int` quando rappresentabile).' },
  round: { params: [P('x', 'number')], min: 1, max: 1, returns: 'number', doc: 'Arrotonda al più vicino (restituisce `int` quando rappresentabile).' },
  min: { params: [P('a', 'number'), P('...altri', 'number')], min: 1, max: -1, returns: 'number', doc: 'Il minimo tra i valori (o tra gli elementi di un array).' },
  max: { params: [P('a', 'number'), P('...altri', 'number')], min: 1, max: -1, returns: 'number', doc: 'Il massimo tra i valori (o tra gli elementi di un array).' },
  clock: { params: [], min: 0, max: 0, returns: 'float', doc: 'Tempo di CPU in secondi, utile per misurare la durata del codice.' },
  assert: { params: [P('condizione', 'bool'), P('messaggio', 'string', true)], min: 1, max: 2, returns: 'nil', doc: 'Solleva `Assertion failed` (con il messaggio opzionale) se la condizione è falsa.' },
  random: { params: [], min: 0, max: 0, returns: 'float', doc: 'Numero pseudo-casuale uniforme nell’intervallo [0, 1).' },
  randomInt: { params: [P('min', 'int'), P('max', 'int')], min: 2, max: 2, returns: 'int', doc: 'Intero pseudo-casuale tra min e max, estremi inclusi. L’ampiezza massima è RAND_MAX + 1.' },
  seedRandom: { params: [P('seed', 'int')], min: 1, max: 1, returns: 'nil', doc: 'Inizializza il generatore pseudo-casuale.' },
  randomChoice: { params: [P('array', 'array')], min: 1, max: 1, returns: 'any', doc: 'Restituisce un elemento casuale di un array non vuoto.' },
  exit: { params: [P('codice', 'int', true)], min: 0, max: 1, returns: 'void', doc: 'Termina il programma con il codice di uscita indicato (default 0).' }
};

const GLOBAL_CONSTANTS = {
  PI: { type: 'float', doc: 'π = 3.14159…' },
  E: { type: 'float', doc: 'Numero di Nepero e = 2.71828…' }
};

const ARRAY_METHODS = {
  push: { params: [P('...valori')], min: 0, max: -1, returns: 'int', doc: 'Aggiunge elementi in coda; restituisce la nuova lunghezza.' },
  pop: { params: [], min: 0, max: 0, returns: 'any', doc: 'Rimuove e restituisce l’ultimo elemento (`nil` se vuoto).' },
  map: { params: [P('fn', 'function')], min: 1, max: 1, returns: 'array', doc: 'Nuovo array con `fn(elemento)` applicata a ogni elemento.' },
  filter: { params: [P('fn', 'function')], min: 1, max: 1, returns: 'array', doc: 'Nuovo array con gli elementi per cui `fn(elemento)` è vera.' },
  forEach: { params: [P('fn', 'function')], min: 1, max: 1, returns: 'nil', doc: 'Chiama `fn(elemento)` per ogni elemento.' },
  reduce: { params: [P('fn', 'function'), P('iniziale', 'any', true)], min: 1, max: 2, returns: 'any', doc: 'Riduce l’array a un solo valore: `fn(accumulatore, elemento)`.' },
  find: { params: [P('fn', 'function')], min: 1, max: 1, returns: 'any', doc: 'Primo elemento per cui `fn(elemento)` è vera, altrimenti `nil`.' },
  join: { params: [P('separatore', 'string', true)], min: 0, max: 1, returns: 'string', doc: 'Unisce gli elementi in una stringa.' },
  contains: { params: [P('valore')], min: 1, max: 1, returns: 'bool', doc: 'Vero se l’array contiene il valore.' },
  indexOf: { params: [P('valore')], min: 1, max: 1, returns: 'int', doc: 'Indice della prima occorrenza (o -1).' },
  slice: { params: [P('inizio', 'int', true), P('fine', 'int', true)], min: 0, max: 2, returns: 'array', doc: 'Sotto-array da `inizio` a `fine` (escluso).' },
  reverse: { params: [], min: 0, max: 0, returns: 'array', doc: 'Inverte l’ordine degli elementi.' },
  sort: { params: [P('confronto', 'function', true)], min: 0, max: 1, returns: 'array', doc: 'Ordina l’array (ordinamento stabile), con funzione di confronto opzionale.' }
};

const STRING_METHODS = {
  upper: { params: [], min: 0, max: 0, returns: 'string', doc: 'Stringa in maiuscolo.' },
  lower: { params: [], min: 0, max: 0, returns: 'string', doc: 'Stringa in minuscolo.' },
  trim: { params: [], min: 0, max: 0, returns: 'string', doc: 'Rimuove gli spazi a inizio e fine.' },
  contains: { params: [P('sottostringa', 'string')], min: 1, max: 1, returns: 'bool', doc: 'Vero se la stringa contiene la sottostringa.' },
  startsWith: { params: [P('prefisso', 'string')], min: 1, max: 1, returns: 'bool', doc: 'Vero se la stringa inizia con il prefisso.' },
  endsWith: { params: [P('suffisso', 'string')], min: 1, max: 1, returns: 'bool', doc: 'Vero se la stringa finisce con il suffisso.' },
  indexOf: { params: [P('sottostringa', 'string')], min: 1, max: 1, returns: 'int', doc: 'Indice della prima occorrenza (o -1).' },
  substring: { params: [P('inizio', 'int'), P('fine', 'int', true)], min: 1, max: 2, returns: 'string', doc: 'Parte della stringa da `inizio` a `fine` (escluso).' },
  split: { params: [P('separatore', 'string')], min: 1, max: 1, returns: 'string[]', doc: 'Divide la stringa in un array di stringhe.' },
  replace: { params: [P('vecchio', 'string'), P('nuovo', 'string')], min: 2, max: 2, returns: 'string', doc: 'Sostituisce le occorrenze di `vecchio` con `nuovo`.' },
  repeat: { params: [P('n', 'int')], min: 1, max: 1, returns: 'string', doc: 'Ripete la stringa `n` volte.' }
};

const COMMON_PROPERTIES = {
  length: { type: 'int', doc: 'Lunghezza di una stringa o di un array.' }
};

function signatureOf(name, info) {
  const params = info.params.map((param) => {
    const optionalMark = param.optional ? '?' : '';
    const typePart = param.type && param.type !== 'any' && !param.name.startsWith('...')
      ? `: ${param.type}`
      : '';
    return `${param.name}${optionalMark}${typePart}`;
  });
  return `${name}(${params.join(', ')})${info.returns ? ` -> ${info.returns}` : ''}`;
}

module.exports = {
  KEYWORDS,
  KEYWORD_SET,
  TYPE_NAMES,
  TYPEOF_NAMES,
  GLOBAL_FUNCTIONS,
  GLOBAL_CONSTANTS,
  ARRAY_METHODS,
  STRING_METHODS,
  COMMON_PROPERTIES,
  signatureOf
};
