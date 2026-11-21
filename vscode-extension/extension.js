'use strict';

const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const data = require('./language-data');
const symbolIndex = require('./symbol-index');

const LANGUAGE_ID = 'hexo';
const SELECTOR = { language: LANGUAGE_ID };
const TYPE_COMPLETIONS = Object.entries(data.TYPE_NAMES);
const ALL_MEMBER_ENTRIES = mergeEntries(
  data.ARRAY_METHODS,
  data.STRING_METHODS,
  data.COMMON_PROPERTIES
);

// Sorgenti e analisi vengono memorizzati per evitare di rileggere e riparsare
// tutti i file ad ogni pressione di un tasto.
const sourceByUri = new Map();
const analysisByUri = new Map();
let workspaceScanPromise;
let extensionRootPath = null;

function mergeEntries(...objects) {
  const merged = new Map();
  for (const object of objects) {
    for (const [name, info] of Object.entries(object)) {
      if (!merged.has(name)) merged.set(name, []);
      merged.get(name).push(info);
    }
  }
  return merged;
}

function uriKey(uri) {
  return typeof uri === 'string' ? uri : uri.toString();
}

function setSource(uri, text) {
  const key = uriKey(uri);
  if (sourceByUri.get(key) === text) return;
  sourceByUri.set(key, text);
  analysisByUri.delete(key);
}

async function readWorkspaceFile(uri) {
  const key = uriKey(uri);
  try {
    const bytes = await vscode.workspace.fs.readFile(uri);
    setSource(key, Buffer.from(bytes).toString('utf8'));
  } catch {
    // File eliminato, non accessibile o fornito da un filesystem virtuale.
    sourceByUri.delete(key);
    analysisByUri.delete(key);
  }
}


function resolveModuleUri(document, importPath) {
  const folder = vscode.workspace.getWorkspaceFolder(document.uri);
  if (path.isAbsolute(importPath)) return vscode.Uri.file(path.normalize(importPath));
  if (folder && folder.uri.scheme === 'file') {
    return vscode.Uri.file(path.resolve(folder.uri.fsPath, importPath));
  }
  if (folder) {
    return vscode.Uri.joinPath(folder.uri, ...importPath.split(/[\\/]+/).filter(Boolean));
  }
  if (document.uri.scheme === 'file') {
    // Senza workspace, la directory del file aperto è la base statica più utile.
    return vscode.Uri.file(path.resolve(path.dirname(document.uri.fsPath), importPath));
  }
  return null;
}

async function analyzeUri(uri) {
  const key = uriKey(uri);
  const openDocument = vscode.workspace.textDocuments.find((item) => uriKey(item.uri) === key);
  let source;
  if (openDocument) {
    source = openDocument.getText();
    setSource(key, source);
  } else if (sourceByUri.has(key)) {
    source = sourceByUri.get(key);
  } else {
    try {
      const bytes = await vscode.workspace.fs.readFile(uri);
      source = Buffer.from(bytes).toString('utf8');
      setSource(key, source);
    } catch {
      sourceByUri.delete(key);
      analysisByUri.delete(key);
      return null;
    }
  }

  let analysis = analysisByUri.get(key);
  if (!analysis || analysis.source !== source) {
    analysis = symbolIndex.analyzeSymbols(source, key);
    analysisByUri.set(key, analysis);
  }
  return analysis;
}

function moduleExports(analysis) {
  if (!analysis) return [];
  return analysis.symbols.filter((symbol) => symbol.topLevel &&
    ['function', 'variable', 'constant', 'class', 'struct'].includes(symbol.kind));
}

async function resolveModule(document, importPath) {
  let uri = resolveModuleUri(document, importPath);
  let analysis = uri ? await analyzeUri(uri) : null;

  // Per i moduli standard inclusi nell'estensione, usa il bundle dell'estensione
  // quando il progetto non contiene una propria copia di stdlib/.
  if (!analysis && extensionRootPath && /^stdlib[\\/]/.test(importPath)) {
    const bundledPath = path.resolve(extensionRootPath, importPath);
    const stdlibRoot = path.resolve(extensionRootPath, 'stdlib');
    if (bundledPath.startsWith(stdlibRoot + path.sep) || bundledPath === stdlibRoot) {
      const bundledUri = vscode.Uri.file(bundledPath);
      analysis = await analyzeUri(bundledUri);
      if (analysis) uri = bundledUri;
    }
  }

  if (!analysis || !uri) return null;
  return { uri, analysis, exports: moduleExports(analysis), importPath };
}

function bundledStdlibFiles() {
  if (!extensionRootPath) return [];
  const root = path.join(extensionRootPath, 'stdlib');
  const found = [];
  function visit(directory) {
    let entries;
    try { entries = fs.readdirSync(directory, { withFileTypes: true }); }
    catch { return; }
    for (const entry of entries) {
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(fullPath);
      else if (entry.isFile() && entry.name.endsWith('.hexo')) {
        found.push(path.relative(extensionRootPath, fullPath).split(path.sep).join('/'));
      }
    }
  }
  visit(root);
  return found;
}

async function ensureWorkspaceSources() {
  if (!workspaceScanPromise) {
    workspaceScanPromise = (async () => {
      try {
        const files = await vscode.workspace.findFiles(
          '**/*.hexo',
          '**/{node_modules,.git}/**',
          500
        );
        await Promise.all(files.map(readWorkspaceFile));
      } catch {
        // L'estensione continua a funzionare anche senza una cartella workspace.
      }
    })();
  }
  await workspaceScanPromise;
}

async function buildProjectIndex(document) {
  await ensureWorkspaceSources();

  // Le versioni aperte (anche non salvate) hanno sempre precedenza sul disco.
  for (const openDocument of vscode.workspace.textDocuments) {
    if (openDocument.languageId === LANGUAGE_ID) {
      setSource(openDocument.uri, openDocument.getText());
    }
  }
  setSource(document.uri, document.getText());

  const currentUri = uriKey(document.uri);
  const orderedSources = [...sourceByUri.entries()].sort(([left], [right]) => {
    if (left === currentUri) return 1;
    if (right === currentUri) return -1;
    return left.localeCompare(right);
  });

  const analyses = [];
  for (const [uri, source] of orderedSources) {
    let analysis = analysisByUri.get(uri);
    if (!analysis || analysis.source !== source) {
      analysis = symbolIndex.analyzeSymbols(source, uri);
      analysisByUri.set(uri, analysis);
    }
    analyses.push(analysis);
  }

  const index = {
    analyses,
    symbols: [],
    symbolsByName: new Map(),
    classes: new Map(),
    functions: new Map(),
    variables: new Map(),
    currentAnalysis: analyses.find((item) => item.uri === currentUri),
    importedModules: new Map(),
    importedBindings: new Map(),
    importedClasses: new Map()
  };

  // L'ultimo file analizzato prevale in caso di nomi duplicati; il documento
  // corrente viene elaborato per ultimo e quindi ha la priorità massima.
  for (const analysis of analyses) {
    for (const symbol of analysis.symbols) {
      index.symbols.push(symbol);
      if (symbol.kind === 'class' || symbol.kind === 'struct') {
        index.classes.set(symbol.name, symbol);
      } else if (symbol.kind === 'function') {
        index.functions.set(symbol.name, symbol);
      } else if (symbol.kind === 'variable' || symbol.kind === 'constant') {
        index.variables.set(symbol.name, symbol);
      }
      if (symbol.kind !== 'method' && symbol.kind !== 'field') {
        index.symbolsByName.set(symbol.name, symbol);
      }
    }
  }
  // I moduli importati vengono analizzati separatamente: solo le dichiarazioni
  // top-level sono esportate, mentre i nomi importati vengono aggiunti all'indice
  // del documento corrente senza esporre indiscriminatamente tutti i file.
  for (const declaration of (index.currentAnalysis && index.currentAnalysis.imports) || []) {
    const moduleInfo = await resolveModule(document, declaration.path);
    if (!moduleInfo) continue;
    if (declaration.kind === 'module') {
      index.importedModules.set(declaration.alias, moduleInfo);
      for (const symbol of moduleInfo.exports) {
        if (symbol.kind === 'class' || symbol.kind === 'struct') {
          index.importedClasses.set(symbol.name, { symbol, moduleInfo });
        }
      }
      continue;
    }
    for (const requested of declaration.names) {
      const symbol = moduleInfo.exports.find((entry) => entry.name === requested.name);
      if (!symbol) continue;
      index.importedBindings.set(requested.name, { symbol, moduleInfo, importOffset: requested.offset });
      index.symbolsByName.set(requested.name, symbol);
      if (symbol.kind === 'class' || symbol.kind === 'struct') index.classes.set(symbol.name, symbol);
      else if (symbol.kind === 'function') index.functions.set(symbol.name, symbol);
      else if (symbol.kind === 'variable' || symbol.kind === 'constant') index.variables.set(symbol.name, symbol);
    }
  }
  resolveDeferredTypes(index);
  return index;
}

function inferProjectExpressionType(expression, index) {
  const value = String(expression || '').trim();
  if (!value) return null;

  const call = value.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
  if (call) {
    const classInfo = index.classes.get(call[1]);
    if (classInfo) return classInfo.name;
    const fn = index.functions.get(call[1]);
    if (fn && fn.returnType) return fn.returnType;
  }

  const memberCall = value.match(/^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
  if (memberCall) {
    const importedModule = index.importedModules && index.importedModules.get(memberCall[1]);
    if (importedModule) {
      const exportedClass = importedModule.exports.find((symbol) =>
        (symbol.kind === 'class' || symbol.kind === 'struct') && symbol.name === memberCall[2]);
      if (exportedClass) return exportedClass.name;
    }
    const receiver = index.variables.get(memberCall[1]);
    const receiverType = receiver && receiver.type ? String(receiver.type).replace(/\?$/, '') : null;
    if (receiverType === 'string') {
      const returns = { upper: 'string', lower: 'string', trim: 'string', contains: 'bool', startsWith: 'bool', endsWith: 'bool', indexOf: 'int', substring: 'string', split: 'string[]', replace: 'string', repeat: 'string' };
      if (returns[memberCall[2]]) return returns[memberCall[2]];
    }
    if (receiverType === 'array' || (receiverType && receiverType.endsWith('[]'))) {
      const returns = { push: 'int', pop: 'any', map: 'array', filter: 'array', forEach: 'nil', reduce: 'any', find: 'any', join: 'string', contains: 'bool', indexOf: 'int', slice: 'array', reverse: 'array', sort: 'array' };
      if (returns[memberCall[2]]) return returns[memberCall[2]];
    }
    const owner = index.classes.get(receiverType);
    if (owner) {
      const method = collectClassMembers(index, owner, false).find((item) => item.name === memberCall[2] && item.kind === 'method');
      if (method && method.returnType) return method.returnType;
    }
  }

  const fieldAccess = value.match(/^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)$/);
  if (fieldAccess) {
    const receiver = index.variables.get(fieldAccess[1]);
    const owner = receiver && receiver.type ? index.classes.get(String(receiver.type).replace(/\?$/, '')) : null;
    if (owner) {
      const field = collectClassMembers(index, owner, false).find((item) => item.name === fieldAccess[2]);
      if (field && field.type) return field.type;
    }
  }

  const identifier = value.match(/^([A-Za-z_][A-Za-z0-9_]*)$/);
  if (identifier) {
    const variable = index.variables.get(identifier[1]);
    if (variable && variable.type) return variable.type;
    const classInfo = index.classes.get(identifier[1]);
    if (classInfo) return classInfo.name;
  }
  return null;
}

function resolveDeferredTypes(index) {
  // Consente di risolvere inizializzatori che dipendono da funzioni o classi
  // dichiarate in un altro file del workspace, anche se vengono dopo.
  const allVariables = [
    ...index.variables.values(),
    ...[...index.classes.values()].flatMap((classInfo) => classInfo.members || [])
      .filter((member) => member.kind === 'field' || member.kind === 'constant')
  ];
  for (let pass = 0; pass < 4; pass += 1) {
    let changed = false;
    for (const variable of allVariables) {
      if (!variable.type && variable.initializer) {
        const inferred = inferProjectExpressionType(variable.initializer, index);
        if (inferred) {
          variable.type = inferred;
          variable.inferred = true;
          changed = true;
        }
      }
    }
    if (!changed) break;
  }
}

function markdown(text) {
  const value = new vscode.MarkdownString(text);
  value.isTrusted = false;
  return value;
}


function importPathContext(document, position) {
  const line = document.lineAt(position.line).text;
  const prefix = line.slice(0, position.character);
  const match = prefix.match(/\b(?:import|from)\s+(["'])([^"']*)$/);
  if (!match) return null;
  const pathStart = match.index + match[0].indexOf(match[1]) + 1;
  return { prefix: match[2], range: new vscode.Range(position.line, pathStart, position.line, position.character) };
}

function fromImportContext(document, position) {
  const line = document.lineAt(position.line).text;
  const prefix = line.slice(0, position.character);
  const match = prefix.match(/\bfrom\s+(["'])([^"']*)\1\s+import\s+((?:[A-Za-z_][A-Za-z0-9_]*\s*,\s*)*[A-Za-z_0-9]*\s*)$/);
  if (!match) return null;
  const namesText = match[3] || '';
  const parts = namesText.split(',');
  const currentToken = (parts.pop() || '').trim();
  const previousNames = parts.map((name) => name.trim()).filter(Boolean);
  const start = position.character - currentToken.length;
  return {
    path: match[2],
    currentToken,
    previousNames,
    range: new vscode.Range(position.line, start, position.line, position.character)
  };
}

function exportCompletion(symbol) {
  if (symbol.kind === 'function') return makeUserCallableCompletion(symbol);
  if (symbol.kind === 'class' || symbol.kind === 'struct') {
    const kind = symbol.kind === 'struct' ? vscode.CompletionItemKind.Struct : vscode.CompletionItemKind.Class;
    return completionItem(symbol.name, kind, symbol.kind, symbolDocumentation(symbol));
  }
  const kind = symbol.kind === 'constant' ? vscode.CompletionItemKind.Constant : vscode.CompletionItemKind.Variable;
  const type = symbol.type ? `: ${symbol.type}` : '';
  return completionItem(symbol.name, kind, `${symbol.kind}${type}`, symbolDocumentation(symbol));
}

async function modulePathCompletions(document, position, context) {
  const candidates = new Set();
  try {
    const folder = vscode.workspace.getWorkspaceFolder(document.uri);
    if (folder && folder.uri.scheme === 'file') {
      const files = await vscode.workspace.findFiles('**/*.hexo', '**/{node_modules,.git}/**', 500);
      for (const uri of files) {
        if (uri.scheme !== 'file') continue;
        const owner = vscode.workspace.getWorkspaceFolder(uri);
        if (!owner || owner.uri.toString() !== folder.uri.toString()) continue;
        candidates.add(path.relative(folder.uri.fsPath, uri.fsPath).split(path.sep).join('/'));
      }
    }
  } catch {
    // La lista del workspace è facoltativa; restano disponibili i moduli bundled.
  }

  for (const bundled of bundledStdlibFiles()) candidates.add(bundled);
  return [...candidates]
    .filter((relative) => relative && (!context.prefix || relative.toLowerCase().startsWith(context.prefix.toLowerCase())))
    .sort()
    .map((relative) => {
      const item = new vscode.CompletionItem(relative, vscode.CompletionItemKind.File);
      item.detail = relative.startsWith('stdlib/') ? 'Modulo standard Hexo' : 'Modulo Hexo';
      item.insertText = relative;
      item.range = context.range;
      item.filterText = relative;
      return item;
    });
}

function completionItem(label, kind, detail, documentation, insertText, command) {
  const item = new vscode.CompletionItem(label, kind);
  item.detail = detail;
  item.documentation = markdown(documentation);
  if (insertText) item.insertText = insertText;
  if (command) item.command = command;
  return item;
}

function makeCallableCompletion(name, info, kind) {
  const signature = data.signatureOf(name, info);
  const docs = `${signature}\n\n${info.doc}\n\n**Ritorno:** \`${info.returns || 'non specificato'}\``;
  return completionItem(
    name,
    kind,
    signature,
    docs,
    new vscode.SnippetString(`${name}($0)`),
    { command: 'editor.action.triggerParameterHints', title: 'Mostra i parametri' }
  );
}

function makeUserCallableCompletion(symbol, kind = vscode.CompletionItemKind.Function) {
  const info = symbol.info || { params: symbol.params || [], returns: symbol.returnType, doc: symbol.doc };
  const signature = symbol.signature || data.signatureOf(symbol.name, info);
  const returnInfo = symbol.returnType ? `\n\n**Ritorno:** \`${symbol.returnType}\`` : '\n\n**Ritorno:** non specificato';
  const docs = `**${symbol.kind === 'method' ? 'Metodo' : 'Funzione'} definito dall'utente**\n\n\`${signature}\`\n\n${symbol.doc || 'Dichiarazione utente.'}${returnInfo}`;
  return completionItem(
    symbol.name,
    kind,
    signature,
    docs,
    new vscode.SnippetString(`${symbol.name}($0)`),
    { command: 'editor.action.triggerParameterHints', title: 'Mostra i parametri' }
  );
}

function getMemberReceiver(document, position) {
  const line = document.lineAt(position.line).text.slice(0, position.character);
  const match = line.match(/((?:[A-Za-z_][A-Za-z0-9_]*|this|super)(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\.\s*[A-Za-z_0-9]*$/);
  return match ? match[1].replace(/\s*\.\s*/g, '.') : null;
}

function getMemberReceiverBeforeWord(document, wordRange) {
  const line = document.lineAt(wordRange.start.line).text.slice(0, wordRange.start.character);
  const match = line.match(/((?:[A-Za-z_][A-Za-z0-9_]*|this|super)(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\.\s*$/);
  return match ? match[1].replace(/\s*\.\s*/g, '.') : null;
}

function getWord(document, position) {
  const range = document.getWordRangeAtPosition(position, /[A-Za-z_][A-Za-z0-9_]*/);
  return range ? { text: document.getText(range), range } : undefined;
}

function getMemberInfos(name, typeName) {
  const type = String(typeName || '').replace(/\?$/, '');
  if (type === 'string') {
    const info = data.STRING_METHODS[name] || data.COMMON_PROPERTIES[name];
    return info ? [{ info, source: data.STRING_METHODS[name] ? 'string' : 'common' }] : [];
  }
  if (type === 'array' || type.endsWith('[]')) {
    const info = data.ARRAY_METHODS[name] || data.COMMON_PROPERTIES[name];
    return info ? [{ info, source: data.ARRAY_METHODS[name] ? 'array' : 'common' }] : [];
  }
  return [];
}

function memberDocumentation(name, entries) {
  const unique = [];
  const seen = new Set();
  for (const entry of entries) {
    const key = `${entry.info.returns}|${entry.info.doc}|${entry.source}`;
    if (!seen.has(key)) {
      seen.add(key);
      unique.push(entry);
    }
  }
  if (unique.length === 1) {
    const { info } = unique[0];
    const signature = info.params ? data.signatureOf(name, info) : name;
    const returnLine = info.returns ? `\n\n**Ritorno:** \`${info.returns}\`` : '';
    return `**Proprietà/metodo:** \`${name}\`\n\n**Firma:** \`${signature}\`\n\n${info.doc}${returnLine}`;
  }
  return `**Metodo:** \`${name}\`\n\n` + unique.map(({ info, source }) => {
    const signature = info.params ? data.signatureOf(name, info) : name;
    return `**${source}:** \`${signature}\`\n\n${info.doc}`;
  }).join('\n\n---\n\n');
}

function collectClassMembers(index, classInfo, staticMode, visited = new Set()) {
  if (!classInfo || visited.has(classInfo.name)) return [];
  visited.add(classInfo.name);
  const ownMembers = (classInfo.members || []).filter((member) => Boolean(member.isStatic) === Boolean(staticMode));
  const names = new Set(ownMembers.map((member) => member.name));
  const inherited = classInfo.base && index.classes.has(classInfo.base)
    ? collectClassMembers(index, index.classes.get(classInfo.base), staticMode, visited)
    : [];
  return [...ownMembers, ...inherited.filter((member) => !names.has(member.name))];
}


function collectModuleClassMembers(moduleInfo, classInfo, staticMode, visited = new Set()) {
  if (!classInfo || visited.has(classInfo.name)) return [];
  visited.add(classInfo.name);
  const own = (classInfo.members || []).filter((member) => Boolean(member.isStatic) === Boolean(staticMode));
  const names = new Set(own.map((member) => member.name));
  const base = classInfo.base && moduleInfo.exports.find((symbol) =>
    (symbol.kind === 'class' || symbol.kind === 'struct') && symbol.name === classInfo.base);
  const inherited = base ? collectModuleClassMembers(moduleInfo, base, staticMode, visited) : [];
  return [...own, ...inherited.filter((member) => !names.has(member.name))];
}

function nativeMembersForType(typeName) {
  const type = String(typeName || '').replace(/\?$/, '');
  if (type === 'string') {
    return [
      ...Object.entries(data.STRING_METHODS).map(([name, info]) => ({ name, info, source: 'string' })),
      { name: 'length', info: data.COMMON_PROPERTIES.length, source: 'common' }
    ].map((entry) => ({ ...entry, kind: entry.info.params ? 'method' : 'field', isStatic: false }));
  }
  if (type === 'array' || type.endsWith('[]')) {
    return [
      ...Object.entries(data.ARRAY_METHODS).map(([name, info]) => ({ name, info, source: 'array' })),
      { name: 'length', info: data.COMMON_PROPERTIES.length, source: 'common' }
    ].map((entry) => ({ ...entry, kind: entry.info.params ? 'method' : 'field', isStatic: false }));
  }
  return null;
}

function filterPrivateMembers(members, currentClass = null, moduleUri = null) {
  return members.filter((member) => !member.isPrivate || (
    currentClass && currentClass.name === member.owner && (!moduleUri || currentClass.uri === moduleUri)
  ));
}

function resolveModuleReceiverMembers(moduleInfo, expression, parts, currentClass = null) {
  if (parts.length === 1) {
    return {
      receiver: expression,
      type: 'module',
      members: moduleInfo.exports.map((symbol) => ({ ...symbol, source: 'module' }))
    };
  }

  const first = moduleInfo.exports.find((symbol) => symbol.name === parts[1]);
  if (!first) return { receiver: expression, members: [], type: null };

  let type = first.type || null;
  let classContext = null;
  let staticMode = false;
  if (first.kind === 'class' || first.kind === 'struct') {
    classContext = first;
    type = first.name;
    staticMode = true;
  }

  for (const memberName of parts.slice(2)) {
    const owner = moduleInfo.exports.find((symbol) =>
      (symbol.kind === 'class' || symbol.kind === 'struct') && symbol.name === String(type || '').replace(/\?$/, ''));
    if (!owner) return { receiver: expression, members: [], type };
    const member = collectModuleClassMembers(moduleInfo, owner, staticMode).find((item) => item.name === memberName);
    if (!member || member.kind === 'method') return { receiver: expression, members: [], type: null };
    type = member.type || null;
    staticMode = false;
    classContext = null;
  }

  const builtins = nativeMembersForType(type);
  if (builtins) return { receiver: expression, type: String(type).replace(/\?$/, ''), members: builtins };
  const customClass = moduleInfo.exports.find((symbol) =>
    (symbol.kind === 'class' || symbol.kind === 'struct') && symbol.name === String(type || '').replace(/\?$/, ''));
  if (customClass) {
    return {
      receiver: expression,
      type: customClass.name,
      members: filterPrivateMembers(collectModuleClassMembers(moduleInfo, customClass, staticMode), currentClass, moduleInfo.uri)
    };
  }
  return { receiver: expression, members: [], type };
}


function resolveImportedClassReceiver(importedClass, expression, parts) {
  const moduleInfo = importedClass.moduleInfo;
  let classInfo = importedClass.symbol;
  let type = classInfo.name;
  for (const memberName of parts.slice(1)) {
    const member = collectModuleClassMembers(moduleInfo, classInfo, false)
      .find((item) => item.name === memberName);
    if (!member || member.kind === 'method') return { receiver: expression, members: [], type: null };
    type = member.type || null;
    classInfo = moduleInfo.exports.find((symbol) =>
      (symbol.kind === 'class' || symbol.kind === 'struct') && symbol.name === String(type || '').replace(/\?$/, ''));
    if (!classInfo) {
      const builtins = nativeMembersForType(type);
      return { receiver: expression, type, members: builtins || [] };
    }
  }
  return {
    receiver: expression,
    type: classInfo.name,
    members: filterPrivateMembers(collectModuleClassMembers(moduleInfo, classInfo, false), null, moduleInfo.uri)
  };
}

function getEnclosingClass(index, document, position) {
  const analysis = index.currentAnalysis;
  if (!analysis) return null;
  return symbolIndex.findClassAt(analysis, document.offsetAt(position));
}

function resolveReceiverMembers(index, document, position, receiverExpression = null) {
  const expression = receiverExpression || getMemberReceiver(document, position);
  if (!expression) return { receiver: null, members: [], type: null };

  const parts = expression.split('.');
  const root = parts[0];
  const lexicalClass = getEnclosingClass(index, document, position);
  const importedModule = index.importedModules && index.importedModules.get(root);
  if (importedModule) return resolveModuleReceiverMembers(importedModule, expression, parts, lexicalClass);
  let type = null;
  let classContext = null;
  let staticMode = false;

  if (root === 'this' || root === 'super') {
    const currentClass = getEnclosingClass(index, document, position);
    if (!currentClass) return { receiver: expression, members: [], type: null };
    classContext = root === 'super'
      ? index.classes.get(currentClass.base)
      : index.classes.get(currentClass.name);
    if (!classContext) return { receiver: expression, members: [], type: null };
    type = classContext.name;
  } else if (index.classes.has(root)) {
    classContext = index.classes.get(root);
    type = classContext.name;
    staticMode = true;
  } else {
    const variable = index.variables.get(root);
    type = variable && variable.type ? String(variable.type).replace(/\?$/, '') : null;
    const importedClass = type && index.importedClasses && index.importedClasses.get(type);
    if (importedClass) return resolveImportedClassReceiver(importedClass, expression, parts);
  }

  // Risolve i campi intermedi in espressioni come `person.address.` o
  // `this.configuration.`. Le chiamate concatenate non vengono inferite.
  for (const memberName of parts.slice(1)) {
    const owner = index.classes.get(String(type || '').replace(/\?$/, ''));
    if (!owner) return { receiver: expression, members: [], type };
    const member = collectClassMembers(index, owner, staticMode).find((item) => item.name === memberName);
    if (!member || member.kind === 'method') return { receiver: expression, members: [], type: null };
    type = member.type || null;
    staticMode = false;
  }

  if (!type || type === 'any' || type === 'nil') {
    return { receiver: expression, members: [], type };
  }

  const normalizedType = String(type).replace(/\?$/, '');
  if (normalizedType === 'string') {
    const all = [
      ...Object.entries(data.STRING_METHODS).map(([name, info]) => ({ name, info, source: 'string' })),
      { name: 'length', info: data.COMMON_PROPERTIES.length, source: 'common' }
    ];
    return {
      receiver: expression,
      type: normalizedType,
      members: all.map((entry) => ({ ...entry, kind: entry.info.params ? 'method' : 'field', isStatic: false, info: entry.info }))
    };
  }
  if (normalizedType === 'array' || normalizedType.endsWith('[]')) {
    const all = [
      ...Object.entries(data.ARRAY_METHODS).map(([name, info]) => ({ name, info, source: 'array' })),
      { name: 'length', info: data.COMMON_PROPERTIES.length, source: 'common' }
    ];
    return {
      receiver: expression,
      type: normalizedType,
      members: all.map((entry) => ({ ...entry, kind: entry.info.params ? 'method' : 'field', isStatic: false, info: entry.info }))
    };
  }

  const customClass = index.classes.get(normalizedType);
  if (customClass) {
    return {
      receiver: expression,
      type: normalizedType,
      members: filterPrivateMembers(collectClassMembers(index, customClass, staticMode), lexicalClass)
    };
  }
  return { receiver: expression, members: [], type: normalizedType };
}

function memberCompletion(member) {
  if (member.kind === 'function') {
    return makeUserCallableCompletion(member, vscode.CompletionItemKind.Function);
  }
  if (member.kind === 'class' || member.kind === 'struct') {
    const kind = member.kind === 'struct' ? vscode.CompletionItemKind.Struct : vscode.CompletionItemKind.Class;
    return completionItem(member.name, kind, member.kind, symbolDocumentation(member));
  }
  if (member.kind === 'variable' || member.kind === 'constant') {
    const kind = member.kind === 'constant' ? vscode.CompletionItemKind.Constant : vscode.CompletionItemKind.Variable;
    const type = member.type ? `: ${member.type}` : '';
    return completionItem(member.name, kind, `${member.kind}${type}`, symbolDocumentation(member));
  }
  if (member.kind === 'method') {
    const info = member.info || { params: member.params || [], returns: member.returnType, doc: member.doc };
    if (member.signature && !member.info) {
      const item = makeUserCallableCompletion(member, vscode.CompletionItemKind.Method);
      if (member.isStatic) item.detail = `static ${item.detail}`;
      if (member.isPrivate) item.detail = `private ${item.detail}`;
      return item;
    }
    const item = makeCallableCompletion(member.name, info, vscode.CompletionItemKind.Method);
    if (member.isStatic) item.detail = `static ${item.detail}`;
    if (member.isPrivate) item.detail = `private ${item.detail}`;
    if (member.doc) item.documentation = markdown(`${item.documentation.value || ''}\n\n${member.doc}`);
    return item;
  }
  const type = member.type || (member.info && member.info.type) || 'any';
  const doc = member.doc || (member.info && member.info.doc) || 'Membro definito dall’utente.';
  const item = completionItem(
    member.name,
    member.kind === 'constant' ? vscode.CompletionItemKind.Constant : vscode.CompletionItemKind.Field,
    `${member.isPrivate ? 'private · ' : ''}${member.isStatic ? 'static · ' : ''}${type}`,
    `${doc}\n\n**Visibilità:** ${member.isPrivate ? 'privata' : 'pubblica'}\n\n**Tipo:** \`${type}\``
  );
  return item;
}

function symbolDocumentation(symbol) {
  if (symbol.kind === 'function') {
    const returnText = symbol.returnType ? `\n\n**Ritorno:** \`${symbol.returnType}\`` : '\n\n**Ritorno:** non specificato';
    return `**Funzione definita dall'utente**\n\n\`${symbol.signature}\`\n\n${symbol.doc || ''}${returnText}`;
  }
  if (symbol.kind === 'class' || symbol.kind === 'struct') {
    const members = symbol.members || [];
    const memberText = members.length
      ? `\n\n**Membri:**\n\n${members.map((member) => member.kind === 'method' ? `- \`${member.isPrivate ? 'private ' : ''}${member.signature}\`` : `- \`${member.isPrivate ? 'private ' : ''}${member.name}\` : \`${member.type || 'tipo non specificato'}\``).join('\n')}`
      : '';
    return `**${symbol.kind === 'class' ? 'Classe' : 'Struct'} definita dall'utente**\n\n${symbol.doc || ''}${symbol.base ? `\n\n**Classe base:** \`${symbol.base}\`` : ''}${memberText}`;
  }
  const typeText = symbol.type ? `\n\n**Tipo:** \`${symbol.type}\`` : '\n\n**Tipo:** non specificato';
  const inferredText = symbol.inferred ? ' (inferito dal valore iniziale)' : '';
  return `**${symbol.kind === 'constant' ? 'Costante' : 'Variabile'} definita dall'utente**\n\n${symbol.doc || ''}${typeText}${inferredText}`;
}


function sourcePosition(source, offset) {
  const before = source.slice(0, Math.max(0, offset));
  const lines = before.split('\n');
  return new vscode.Position(lines.length - 1, lines[lines.length - 1].length);
}

function locationForSymbol(symbol, moduleInfo = null, index = null) {
  if (!symbol || !symbol.uri) return null;
  const uri = vscode.Uri.parse(symbol.uri);
  let analysis = moduleInfo && moduleInfo.analysis;
  if (!analysis && index) analysis = index.analyses.find((item) => item.uri === symbol.uri);
  if (!analysis && index) {
    for (const info of index.importedModules.values()) {
      if (info.analysis.uri === symbol.uri) { analysis = info.analysis; break; }
    }
    if (!analysis) {
      for (const imported of index.importedBindings.values()) {
        if (imported.moduleInfo.analysis.uri === symbol.uri) { analysis = imported.moduleInfo.analysis; break; }
      }
    }
  }
  if (!analysis) return new vscode.Location(uri, new vscode.Position(0, 0));
  return new vscode.Location(uri, sourcePosition(analysis.source, symbol.offset || 0));
}

function locateModuleMember(moduleInfo, receiverParts, memberName) {
  if (receiverParts.length === 1) {
    const symbol = moduleInfo.exports.find((item) => item.name === memberName);
    return symbol ? locationForSymbol(symbol, moduleInfo) : null;
  }

  let classInfo = moduleInfo.exports.find((item) =>
    (item.kind === 'class' || item.kind === 'struct') && item.name === receiverParts[1]);
  if (!classInfo) return null;
  let staticMode = true;
  const segments = [...receiverParts.slice(2), memberName];
  let resolved = null;
  for (let index = 0; index < segments.length; index += 1) {
    resolved = collectModuleClassMembers(moduleInfo, classInfo, staticMode)
      .find((item) => item.name === segments[index]);
    if (!resolved) return null;
    if (index < segments.length - 1) {
      if (resolved.kind === 'method') return null;
      const nextClass = moduleInfo.exports.find((item) =>
        (item.kind === 'class' || item.kind === 'struct') && item.name === String(resolved.type || '').replace(/\?$/, ''));
      if (!nextClass) return null;
      classInfo = nextClass;
      staticMode = false;
    }
  }
  return locationForSymbol(resolved, moduleInfo);
}

function findCallContext(document, position) {
  const beforeCursor = document.getText(new vscode.Range(new vscode.Position(0, 0), position));
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  const stack = [];

  for (let index = 0; index < beforeCursor.length; index += 1) {
    const char = beforeCursor[index];
    const next = beforeCursor[index + 1];

    if (lineComment) {
      if (char === '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (char === '*' && next === '/') {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = null;
      continue;
    }
    if (char === '/' && next === '/') { lineComment = true; index += 1; continue; }
    if (char === '/' && next === '*') { blockComment = true; index += 1; continue; }
    if (char === '"' || char === "'") { quote = char; continue; }
    if (char === '(' || char === '[' || char === '{') stack.push({ char, index });
    else if (char === ')' || char === ']' || char === '}') {
      const expected = char === ')' ? '(' : char === ']' ? '[' : '{';
      for (let top = stack.length - 1; top >= 0; top -= 1) {
        if (stack[top].char === expected) { stack.length = top; break; }
      }
    }
  }

  const openParen = [...stack].reverse().find((entry) => entry.char === '(');
  if (!openParen) return undefined;

  const calleePrefix = beforeCursor.slice(0, openParen.index).trimEnd();
  const memberMatch = calleePrefix.match(/((?:[A-Za-z_][A-Za-z0-9_]*|this|super)(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*$/);
  const calleeMatch = calleePrefix.match(/([A-Za-z_][A-Za-z0-9_]*)\s*$/);
  if (!calleeMatch) return undefined;

  const name = memberMatch ? memberMatch[2] : calleeMatch[1];
  const currentArgs = beforeCursor.slice(openParen.index + 1);
  let activeParameter = 0;
  let nested = 0;
  quote = null;
  escaped = false;
  lineComment = false;
  blockComment = false;

  for (let index = 0; index < currentArgs.length; index += 1) {
    const char = currentArgs[index];
    const next = currentArgs[index + 1];
    if (lineComment) { if (char === '\n') lineComment = false; continue; }
    if (blockComment) {
      if (char === '*' && next === '/') { blockComment = false; index += 1; }
      continue;
    }
    if (quote) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = null;
      continue;
    }
    if (char === '/' && next === '/') { lineComment = true; index += 1; continue; }
    if (char === '/' && next === '*') { blockComment = true; index += 1; continue; }
    if (char === '"' || char === "'") { quote = char; continue; }
    if (char === '(' || char === '[' || char === '{') nested += 1;
    else if (char === ')' || char === ']' || char === '}') nested = Math.max(0, nested - 1);
    else if (char === ',' && nested === 0) activeParameter += 1;
  }

  return {
    name,
    isMember: Boolean(memberMatch),
    receiver: memberMatch ? memberMatch[1].replace(/\s*\.\s*/g, '.') : null,
    activeParameter
  };
}

function getCallInfos(call, index, document, position) {
  if (call.isMember) {
    const resolved = resolveReceiverMembers(index, document, position, call.receiver);
    const member = resolved.members.find((item) => item.name === call.name &&
      ['method', 'function', 'class', 'struct'].includes(item.kind));
    if (member && (member.kind === 'function' || member.kind === 'method')) {
      return [member.info || { params: member.params || [], returns: member.returnType, doc: member.doc }];
    }
    if (member && (member.kind === 'class' || member.kind === 'struct')) {
      const init = (member.members || []).find((item) => item.name === 'init' && item.kind === 'method' && !item.isStatic);
      if (init) return [init.info || { params: init.params || [], returns: init.returnType, doc: init.doc }];
    }
    return getMemberInfos(call.name, resolved.type).map((entry) => entry.info).filter((info) => info.params);
  }

  const native = data.GLOBAL_FUNCTIONS[call.name];
  if (native) return [native];
  const userFunction = index.functions.get(call.name);
  if (userFunction) return [userFunction.info];

  const constructor = index.classes.get(call.name);
  if (constructor) {
    const init = (constructor.members || []).find((member) => member.name === 'init' && member.kind === 'method' && !member.isStatic);
    if (init) return [init.info];
  }
  return [];
}

function createSignatureHelp(context, infos) {
  const help = new vscode.SignatureHelp();
  help.signatures = infos.map((info, index) => {
    const signatureName = context.name || '';
    const signature = new vscode.SignatureInformation(data.signatureOf(signatureName, info), info.doc || '');
    signature.parameters = (info.params || []).map((param) => {
      const label = `${param.name}${param.optional ? '?' : ''}${param.type !== 'any' && !param.name.startsWith('...') ? `: ${param.type}` : ''}`;
      return new vscode.ParameterInformation(label);
    });
    return signature;
  });
  help.activeSignature = 0;
  const info = infos[0];
  const lastParameter = Math.max(0, (info.params || []).length - 1);
  help.activeParameter = Math.min(context.activeParameter, lastParameter);
  return help;
}

function activate(context) {
  extensionRootPath = context.extensionPath || (context.extensionUri && context.extensionUri.fsPath) || null;
  const subscriptions = context.subscriptions;

  subscriptions.push(vscode.workspace.onDidChangeTextDocument((event) => {
    if (event.document.languageId === LANGUAGE_ID) setSource(event.document.uri, event.document.getText());
  }));
  subscriptions.push(vscode.workspace.onDidSaveTextDocument((document) => {
    if (document.languageId === LANGUAGE_ID) setSource(document.uri, document.getText());
  }));
  const watcher = vscode.workspace.createFileSystemWatcher('**/*.hexo');
  watcher.onDidCreate((uri) => { void readWorkspaceFile(uri); });
  watcher.onDidChange((uri) => { void readWorkspaceFile(uri); });
  watcher.onDidDelete((uri) => {
    sourceByUri.delete(uriKey(uri));
    analysisByUri.delete(uriKey(uri));
  });
  subscriptions.push(watcher);

  subscriptions.push(vscode.languages.registerCompletionItemProvider(SELECTOR, {
    async provideCompletionItems(document, position) {
      const pathContext = importPathContext(document, position);
      if (pathContext) return modulePathCompletions(document, position, pathContext);

      const namedImport = fromImportContext(document, position);
      if (namedImport) {
        const moduleInfo = await resolveModule(document, namedImport.path);
        if (!moduleInfo) return [];
        return moduleInfo.exports
          .filter((symbol) => !namedImport.previousNames.includes(symbol.name))
          .map(exportCompletion)
          .map((item) => { item.range = namedImport.range; return item; });
      }

      const index = await buildProjectIndex(document);
      const items = [];
      const receiver = getMemberReceiver(document, position);
      if (receiver) {
        const resolved = resolveReceiverMembers(index, document, position, receiver);
        for (const member of resolved.members) items.push(memberCompletion(member));
        return items;
      }

      const labels = new Set();
      const add = (item) => {
        if (!labels.has(item.label)) {
          labels.add(item.label);
          items.push(item);
        }
      };

      for (const [name, doc] of Object.entries(data.KEYWORDS)) {
        add(completionItem(name, vscode.CompletionItemKind.Keyword, 'Parola chiave Hexo', doc));
      }
      for (const [name, doc] of TYPE_COMPLETIONS) {
        add(completionItem(name, vscode.CompletionItemKind.TypeParameter, 'Tipo Hexo', doc));
      }
      for (const [name, info] of Object.entries(data.GLOBAL_FUNCTIONS)) {
        add(makeCallableCompletion(name, info, vscode.CompletionItemKind.Function));
      }
      for (const [name, info] of Object.entries(data.GLOBAL_CONSTANTS)) {
        add(completionItem(name, vscode.CompletionItemKind.Constant, info.type, `${info.doc}\n\n**Tipo:** \`${info.type}\``));
      }
      for (const [alias, moduleInfo] of index.importedModules) {
        add(completionItem(alias, vscode.CompletionItemKind.Module, `Modulo · ${moduleInfo.importPath}`, `Namespace del modulo \`${moduleInfo.importPath}\`. Esportazioni rilevate: ${moduleInfo.exports.length}.`));
      }

      for (const classInfo of index.classes.values()) {
        const kind = classInfo.kind === 'struct' ? vscode.CompletionItemKind.Struct : vscode.CompletionItemKind.Class;
        const inheritance = classInfo.base ? ` extends ${classInfo.base}` : '';
        add(completionItem(classInfo.name, kind, `${classInfo.kind}${inheritance}`, symbolDocumentation(classInfo)));
      }
      for (const fn of index.functions.values()) add(makeUserCallableCompletion(fn));
      for (const variable of index.variables.values()) {
        const kind = variable.kind === 'constant' ? vscode.CompletionItemKind.Constant : vscode.CompletionItemKind.Variable;
        const type = variable.type ? `: ${variable.type}` : '';
        add(completionItem(
          variable.name,
          kind,
          `${variable.kind}${type}`,
          symbolDocumentation(variable)
        ));
      }
      return items;
    }
  }, '.', '/', '"', "'", ','));

  subscriptions.push(vscode.languages.registerDefinitionProvider(SELECTOR, {
    async provideDefinition(document, position) {
      const word = getWord(document, position);
      if (!word) return undefined;
      const index = await buildProjectIndex(document);
      const receiver = getMemberReceiverBeforeWord(document, word.range);
      if (receiver) {
        const parts = receiver.split('.');
        const moduleInfo = index.importedModules.get(parts[0]);
        if (moduleInfo) {
          const location = locateModuleMember(moduleInfo, parts, word.text);
          if (location) return location;
        }
      }

      const imported = index.importedBindings.get(word.text);
      if (imported) return locationForSymbol(imported.symbol, imported.moduleInfo, index);

      const moduleInfo = index.importedModules.get(word.text);
      if (moduleInfo) return new vscode.Location(moduleInfo.uri, new vscode.Position(0, 0));
      return undefined;
    }
  }));

  subscriptions.push(vscode.languages.registerHoverProvider(SELECTOR, {
    async provideHover(document, position) {
      const word = getWord(document, position);
      if (!word) return undefined;
      const { text: name, range } = word;

      // In un accesso `oggetto.membro`, la definizione del membro del tipo
      // ricevente prevale sulle eventuali API globali con lo stesso nome.
      const receiver = getMemberReceiverBeforeWord(document, range);
      if (receiver) {
        const index = await buildProjectIndex(document);
        const resolved = resolveReceiverMembers(index, document, range.start, receiver);
        const member = resolved.members.find((item) => item.name === name);
        if (member) {
          const isCallable = member.kind === 'method' || member.kind === 'function';
          const detail = isCallable
            ? `**${member.kind === 'method' ? 'Metodo' : 'Funzione del modulo'}**\n\n\`${member.signature || data.signatureOf(name, member.info || member)}\`\n\n${member.doc || (member.info && member.info.doc) || ''}${member.returnType || (member.info && member.info.returns) ? `\n\n**Ritorno:** \`${member.returnType || member.info.returns}\`` : ''}`
            : (member.kind === 'class' || member.kind === 'struct' || member.kind === 'variable' || member.kind === 'constant')
              ? symbolDocumentation(member)
              : `**Membro**\n\n**Tipo:** \`${member.type || (member.info && member.info.type) || 'non specificato'}\`\n\n${member.doc || (member.info && member.info.doc) || ''}`;
          return new vscode.Hover(markdown(detail), range);
        }
        const nativeMemberInfos = getMemberInfos(name, resolved.type).map((entry) => entry.info);
        if (nativeMemberInfos.length) {
          return new vscode.Hover(markdown(memberDocumentation(name, nativeMemberInfos.map((info) => ({ info, source: resolved.type })))), range);
        }
      }

      if (data.KEYWORDS[name]) return new vscode.Hover(markdown(`**Parola chiave Hexo**\n\n${data.KEYWORDS[name]}`), range);
      if (data.TYPE_NAMES[name]) return new vscode.Hover(markdown(`**Tipo Hexo** \`${name}\`\n\n${data.TYPE_NAMES[name]}`), range);
      if (data.GLOBAL_FUNCTIONS[name]) {
        const info = data.GLOBAL_FUNCTIONS[name];
        return new vscode.Hover(markdown(`**Funzione globale**\n\n\`${data.signatureOf(name, info)}\`\n\n${info.doc}\n\n**Ritorno:** \`${info.returns}\``), range);
      }
      if (data.GLOBAL_CONSTANTS[name]) {
        const info = data.GLOBAL_CONSTANTS[name];
        return new vscode.Hover(markdown(`**Costante globale** \`${name}\`\n\n**Tipo:** \`${info.type}\`\n\n${info.doc}`), range);
      }
      if (data.COMMON_PROPERTIES[name]) {
        const info = data.COMMON_PROPERTIES[name];
        return new vscode.Hover(markdown(`**Proprietà** \`${name}\`\n\n**Tipo:** \`${info.type}\`\n\n${info.doc}`), range);
      }
      const index = await buildProjectIndex(document);
      const enclosingClass = getEnclosingClass(index, document, position);
      if (enclosingClass) {
        const declarationMember = enclosingClass.members.find((member) => member.name === name);
        if (declarationMember) {
          const detail = declarationMember.kind === 'method'
            ? `**Metodo di ${enclosingClass.name}**\n\n\`${declarationMember.signature}\`\n\n${declarationMember.doc || ''}${declarationMember.returnType ? `\n\n**Ritorno:** \`${declarationMember.returnType}\`` : ''}`
            : `**Campo di ${enclosingClass.name}**\n\n**Tipo:** \`${declarationMember.type || 'non specificato'}\``;
          return new vscode.Hover(markdown(detail), range);
        }
      }
      const imported = index.importedBindings.get(name);
      if (imported) return new vscode.Hover(markdown(symbolDocumentation(imported.symbol)), range);
      const moduleInfo = index.importedModules.get(name);
      if (moduleInfo) {
        return new vscode.Hover(markdown(`**Namespace del modulo**\n\n\`${moduleInfo.importPath}\`\n\n**Esportazioni rilevate:** ${moduleInfo.exports.length}`), range);
      }
      const symbol = index.symbolsByName.get(name);
      if (symbol) return new vscode.Hover(markdown(symbolDocumentation(symbol)), range);
      return undefined;
    }
  }));

  subscriptions.push(vscode.languages.registerSignatureHelpProvider(SELECTOR, {
    async provideSignatureHelp(document, position) {
      const call = findCallContext(document, position);
      if (!call) return undefined;
      const index = await buildProjectIndex(document);
      const infos = getCallInfos(call, index, document, position);
      return infos.length ? createSignatureHelp(call, infos) : undefined;
    }
  }, '(', ','));
}

function deactivate() {
  sourceByUri.clear();
  analysisByUri.clear();
  workspaceScanPromise = undefined;
  extensionRootPath = null;
}

module.exports = { activate, deactivate };
