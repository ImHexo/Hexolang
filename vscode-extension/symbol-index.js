'use strict';

const IDENTIFIER = '[A-Za-z_][A-Za-z0-9_]*';
const TYPE_EXPRESSION = `${IDENTIFIER}(?:\\[\\])?\\??`;

function maskSource(source) {
  const chars = source.split('');
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;

  const blank = (index) => {
    if (chars[index] !== '\n' && chars[index] !== '\r') chars[index] = ' ';
  };

  for (let index = 0; index < chars.length; index += 1) {
    const char = source[index];
    const next = source[index + 1];

    if (lineComment) {
      blank(index);
      if (char === '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      blank(index);
      if (char === '*' && next === '/') {
        blank(index + 1);
        index += 1;
        blockComment = false;
      }
      continue;
    }
    if (quote) {
      blank(index);
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = null;
      continue;
    }
    if (char === '/' && next === '/') {
      blank(index);
      blank(index + 1);
      index += 1;
      lineComment = true;
    } else if (char === '/' && next === '*') {
      blank(index);
      blank(index + 1);
      index += 1;
      blockComment = true;
    } else if (char === '"' || char === "'") {
      quote = char;
      blank(index);
    }
  }
  return chars.join('');
}


function decodeImportPath(literal) {
  const body = literal.slice(1, -1);
  return body.replace(/\\([\\"'nrt0])/g, (_match, escaped) => ({
    '\\': '\\', '"': '"', "'": "'", n: '\n', r: '\r', t: '\t', 0: '\0'
  })[escaped]);
}

// Estrae esclusivamente le due forme supportate dal parser Hexo:
// import "file.hexo" as alias;
// from "file.hexo" import Nome, Altro;
function parseImports(source) {
  const mask = maskSource(source);
  const imports = [];
  const importRegex = /\bimport\s+("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')\s+as\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let match;
  while ((match = importRegex.exec(source)) !== null) {
    if (mask.slice(match.index, match.index + 6) !== 'import') continue;
    const pathOffset = match.index + match[0].indexOf(match[1]);
    const aliasOffset = match.index + match[0].lastIndexOf(match[2]);
    imports.push({
      kind: 'module',
      path: decodeImportPath(match[1]),
      alias: match[2],
      names: [],
      offset: match.index,
      pathOffset,
      aliasOffset
    });
  }

  const fromRegex = /\bfrom\s+("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')\s+import\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)/g;
  while ((match = fromRegex.exec(source)) !== null) {
    if (mask.slice(match.index, match.index + 4) !== 'from') continue;
    const pathOffset = match.index + match[0].indexOf(match[1]);
    const namesTextOffset = match.index + match[0].lastIndexOf(match[2]);
    const names = [];
    const nameRegex = /[A-Za-z_][A-Za-z0-9_]*/g;
    let nameMatch;
    while ((nameMatch = nameRegex.exec(match[2])) !== null) {
      names.push({ name: nameMatch[0], offset: namesTextOffset + nameMatch.index });
    }
    imports.push({
      kind: 'named',
      path: decodeImportPath(match[1]),
      alias: null,
      names,
      offset: match.index,
      pathOffset
    });
  }

  return imports.sort((left, right) => left.offset - right.offset);
}

function findMatching(mask, openIndex, openChar, closeChar) {
  let depth = 0;
  for (let index = openIndex; index < mask.length; index += 1) {
    if (mask[index] === openChar) depth += 1;
    else if (mask[index] === closeChar) {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function splitTopLevel(source, delimiter = ',') {
  const parts = [];
  let start = 0;
  const stack = [];
  let quote = null;
  let escaped = false;
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = null;
      continue;
    }
    if (char === '"' || char === "'") { quote = char; continue; }
    if (char === '(' || char === '[' || char === '{' || char === '<') stack.push(char);
    else if (char === ')' || char === ']' || char === '}' || char === '>') stack.pop();
    else if (char === delimiter && stack.length === 0) {
      parts.push(source.slice(start, index).trim());
      start = index + 1;
    }
  }
  const last = source.slice(start).trim();
  if (last) parts.push(last);
  return parts;
}

function parseParameters(source) {
  return splitTopLevel(source).map((part, index) => {
    let match = part.match(/^(\.\.\.)?([A-Za-z_][A-Za-z0-9_]*)(\?)?\s*(?::\s*(.+))?$/);
    if (match) {
      return {
        name: `${match[1] || ''}${match[2]}`,
        type: (match[4] || 'any').trim(),
        optional: Boolean(match[3])
      };
    }

    match = part.match(new RegExp(`^(${TYPE_EXPRESSION})\\s+([A-Za-z_][A-Za-z0-9_]*)(\\?)?$`));
    if (match) return { name: match[2], type: match[1], optional: Boolean(match[3]) };

    // Alcune dichiarazioni possono omettere il nome del parametro e indicare
    // soltanto il tipo. In quel caso manteniamo comunque la firma utile.
    if (new RegExp(`^${TYPE_EXPRESSION}$`).test(part)) {
      return { name: `arg${index + 1}`, type: part, optional: false };
    }
    return { name: part || `arg${index + 1}`, type: 'any', optional: false };
  });
}

function signatureOf(name, info) {
  const params = (info.params || []).map((param) => {
    const optionalMark = param.optional ? '?' : '';
    const typePart = param.type && param.type !== 'any' && !param.name.startsWith('...')
      ? `: ${param.type}`
      : '';
    return `${param.name}${optionalMark}${typePart}`;
  });
  return `${name}(${params.join(', ')})${info.returns ? ` -> ${info.returns}` : ''}`;
}

function isInsideClassBody(classInfo, offset, mask) {
  if (offset <= classInfo.open || offset >= classInfo.close) return false;
  let depth = 0;
  for (let index = classInfo.open + 1; index < offset; index += 1) {
    if (mask[index] === '{') depth += 1;
    else if (mask[index] === '}') depth = Math.max(0, depth - 1);
  }
  return depth === 0;
}

function braceDepthBefore(mask, offset) {
  let depth = 0;
  for (let index = 0; index < offset; index += 1) {
    if (mask[index] === '{') depth += 1;
    else if (mask[index] === '}') depth = Math.max(0, depth - 1);
  }
  return depth;
}

function findEnclosingClass(classes, offset) {
  return classes
    .filter((item) => offset > item.open && offset < item.close)
    .sort((a, b) => (a.close - a.open) - (b.close - b.open))[0];
}

function inferLiteralType(expression, knownFunctions, knownClasses, knownVariables) {
  const value = expression.trim();
  if (!value) return null;
  if (/^(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')/.test(value)) return 'string';
  if (/^(?:true|false)\b/.test(value)) return 'bool';
  if (/^nil\b/.test(value)) return 'nil';
  if (/^[+-]?\d+\b/.test(value) && !/^[+-]?\d+\s*\./.test(value)) return 'int';
  if (/^[+-]?(?:\d+\.\d*|\d*\.\d+)(?:[eE][+-]?\d+)?/.test(value) || /^[+-]?\d+[eE][+-]?\d+/.test(value)) return 'float';
  if (/^\[/.test(value)) return 'array';
  if (/^fn\b/.test(value)) return 'function';
  if (/^(?:PI|E)$/.test(value)) return 'float';

  const call = value.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
  if (call) {
    const classInfo = knownClasses.get(call[1]);
    if (classInfo) return classInfo.name;
    const functionInfo = knownFunctions.get(call[1]);
    if (functionInfo && functionInfo.returns) return functionInfo.returns;
    const nativeReturns = { input: 'string', len: 'int', typeof: 'string', int: 'int', float: 'float', string: 'string', bool: 'bool', range: 'int[]', abs: 'number', sqrt: 'float', pow: 'number', floor: 'number', ceil: 'number', round: 'number', min: 'number', max: 'number', clock: 'float' };
    if (nativeReturns[call[1]]) return nativeReturns[call[1]];
  }
  const identifier = value.match(/^([A-Za-z_][A-Za-z0-9_]*)$/);
  if (identifier && knownVariables.has(identifier[1])) return knownVariables.get(identifier[1]);
  return null;
}

function analyzeSymbols(source, uri = '') {
  const mask = maskSource(source);
  const classes = [];
  const symbols = [];
  const functions = [];
  const variables = [];

  const classRegex = new RegExp(`\\b(class|struct)\\s+(${IDENTIFIER})(?:\\s+extends\\s+(${IDENTIFIER}))?\\s*\\{`, 'g');
  let classMatch;
  while ((classMatch = classRegex.exec(mask)) !== null) {
    const open = mask.indexOf('{', classMatch.index + classMatch[0].length - 1);
    const close = findMatching(mask, open, '{', '}');
    if (close < 0) continue;
    classes.push({
      name: classMatch[2],
      kind: classMatch[1],
      base: classMatch[3] || null,
      start: classMatch.index,
      topLevel: braceDepthBefore(mask, classMatch.index) === 0,
      open,
      close,
      uri,
      members: []
    });
    classRegex.lastIndex = open + 1;
  }

  const functionRegex = new RegExp(`\\bfn\\s+(?:(${TYPE_EXPRESSION})\\s+)?(${IDENTIFIER})\\s*\\(`, 'g');
  let functionMatch;
  while ((functionMatch = functionRegex.exec(mask)) !== null) {
    const openParen = mask.indexOf('(', functionMatch.index + functionMatch[0].length - 1);
    const closeParen = findMatching(mask, openParen, '(', ')');
    if (closeParen < 0) continue;

    const tail = mask.slice(closeParen + 1, closeParen + 100).match(/^\s*->\s*([A-Za-z_][A-Za-z0-9_]*(?:\[\])?\??)/);
    const returnType = tail ? tail[1] : (functionMatch[1] || null);
    const paramsText = source.slice(openParen + 1, closeParen);
    const params = parseParameters(paramsText);
    const name = functionMatch[2];
    const fullInfo = { params, min: params.filter((param) => !param.optional).length, max: params.length, returns: returnType, doc: 'Funzione definita dall’utente.' };
    const memberOf = classes
      .filter((item) => isInsideClassBody(item, functionMatch.index, mask))
      .sort((a, b) => (a.close - a.open) - (b.close - b.open))[0];
    const memberPrefix = mask.slice(Math.max(0, functionMatch.index - 64), functionMatch.index);
    const isStatic = /\bstatic\s+$/.test(memberPrefix);
    const isPrivate = /\bprivate\s+(?:static\s+)?$/.test(memberPrefix);
    const symbol = {
      name,
      kind: memberOf ? 'method' : 'function',
      type: 'function',
      returnType,
      params,
      info: fullInfo,
      signature: signatureOf(name, fullInfo),
      uri,
      offset: functionMatch.index,
      topLevel: !memberOf && braceDepthBefore(mask, functionMatch.index) === 0,
      owner: memberOf ? memberOf.name : null,
      isStatic,
      isPrivate,
      visibility: isPrivate ? 'private' : 'public',
      doc: memberOf ? `Metodo ${isPrivate ? 'privato' : 'pubblico'} di ${memberOf.kind} \`${memberOf.name}\`.` : 'Funzione definita dall’utente.'
    };
    if (memberOf) memberOf.members.push(symbol);
    else functions.push(symbol);
    symbols.push(symbol);
    functionRegex.lastIndex = closeParen + 1;
  }

  // Le dichiarazioni let/const vengono raccolte anche dentro i blocchi
  // funzione: ciò permette di suggerire le variabili locali nel file.
  const variableRegex = new RegExp(`\\b(let|const)\\s+(?:(${TYPE_EXPRESSION})\\s+)?(${IDENTIFIER})(?:\\s*:\\s*(${TYPE_EXPRESSION}))?`, 'g');
  let variableMatch;
  while ((variableMatch = variableRegex.exec(mask)) !== null) {
    const kind = variableMatch[1] === 'const' ? 'constant' : 'variable';
    const explicitType = variableMatch[4] || variableMatch[2] || null;
    const lineEnd = mask.indexOf('\n', variableRegex.lastIndex) < 0 ? mask.length : mask.indexOf('\n', variableRegex.lastIndex);
    const afterDeclaration = mask.slice(variableRegex.lastIndex, lineEnd);
    const initializerMatch = afterDeclaration.match(/^\s*=\s*([^;]+)/);
    let initializer = '';
    if (initializerMatch) {
      const equalsOffset = variableRegex.lastIndex + afterDeclaration.indexOf('=');
      const rawInitializer = source.slice(equalsOffset + 1, lineEnd);
      const rawEnd = rawInitializer.indexOf(';');
      initializer = (rawEnd >= 0 ? rawInitializer.slice(0, rawEnd) : rawInitializer).trim();
    }
    const memberOf = classes
      .filter((item) => isInsideClassBody(item, variableMatch.index, mask))
      .sort((a, b) => (a.close - a.open) - (b.close - b.open))[0];
    const memberPrefix = mask.slice(Math.max(0, variableMatch.index - 64), variableMatch.index);
    const isStatic = /\bstatic\s+$/.test(memberPrefix);
    const isPrivate = /\bprivate\s+(?:static\s+)?$/.test(memberPrefix);
    const symbol = {
      name: variableMatch[3],
      kind: memberOf ? (kind === 'constant' ? 'constant' : 'field') : kind,
      type: explicitType,
      explicitType,
      initializer,
      uri,
      offset: variableMatch.index,
      topLevel: !memberOf && braceDepthBefore(mask, variableMatch.index) === 0,
      owner: memberOf ? memberOf.name : null,
      isStatic,
      isPrivate,
      visibility: isPrivate ? 'private' : 'public',
      doc: memberOf ? `Membro ${isPrivate ? 'privato' : 'pubblico'} di ${memberOf.kind} \`${memberOf.name}\`.` : `${kind === 'constant' ? 'Costante' : 'Variabile'} definita dall’utente.`
    };
    if (memberOf) memberOf.members.push(symbol);
    else variables.push(symbol);
    symbols.push(symbol);
  }

  // Hexo 0.5 also allows direct typed fields such as `private int token = 1`.
  const directFieldRegex = new RegExp(`\\b(public|private)\\s+(?:(static)\\s+)?(${TYPE_EXPRESSION})\\s+(${IDENTIFIER})(?=\\s*(?:=|;|,|\\}))`, 'g');
  let directFieldMatch;
  while ((directFieldMatch = directFieldRegex.exec(mask)) !== null) {
    const memberOf = classes
      .filter((item) => isInsideClassBody(item, directFieldMatch.index, mask))
      .sort((a, b) => (a.close - a.open) - (b.close - b.open))[0];
    if (!memberOf || memberOf.members.some((member) => member.name === directFieldMatch[4])) continue;
    const afterDeclaration = mask.slice(directFieldRegex.lastIndex);
    const initializerMatch = afterDeclaration.match(/^\s*=\s*([^;\n}]+)/);
    const initializer = initializerMatch ? source.slice(directFieldRegex.lastIndex + afterDeclaration.indexOf('=') + 1,
      directFieldRegex.lastIndex + afterDeclaration.indexOf('=') + 1 + initializerMatch[1].length).trim() : '';
    const isPrivate = directFieldMatch[1] === 'private';
    memberOf.members.push({
      name: directFieldMatch[4], kind: 'field', type: directFieldMatch[3], explicitType: directFieldMatch[3],
      initializer, uri, offset: directFieldMatch.index, topLevel: false, owner: memberOf.name,
      isStatic: Boolean(directFieldMatch[2]), isPrivate, visibility: isPrivate ? 'private' : 'public',
      doc: `Campo ${isPrivate ? 'privato' : 'pubblico'} di ${memberOf.kind} \`${memberOf.name}\`.`
    });
  }

  const classByName = new Map(classes.map((item) => [item.name, item]));
  const functionByName = new Map(functions.map((item) => [item.name, item.info]));
  for (const item of classes) {
    for (const member of item.members) {
      if (member.kind === 'method') functionByName.set(member.name, member.info);
    }
  }
  const variableByName = new Map();
  for (const variable of variables) if (variable.type) variableByName.set(variable.name, variable.type);

  // Risolvi tipi derivabili da valori letterali, costruttori e funzioni con
  // tipo di ritorno esplicito. Non tentiamo inferenze arbitrarie.
  for (const variable of variables) {
    if (!variable.type) {
      variable.type = inferLiteralType(variable.initializer, functionByName, classByName, variableByName);
      if (variable.type) variable.inferred = true;
    }
    if (variable.type) variableByName.set(variable.name, variable.type);
  }
  for (const item of classes) {
    for (const member of item.members) {
      if (member.kind === 'field' || member.kind === 'constant') {
        if (!member.type) {
          member.type = inferLiteralType(member.initializer, functionByName, classByName, variableByName);
          if (member.type) member.inferred = true;
        }
      }
    }
  }

  for (const classInfo of classes) {
    const symbol = {
      name: classInfo.name,
      kind: classInfo.kind,
      type: classInfo.name,
      base: classInfo.base,
      members: classInfo.members,
      uri,
      offset: classInfo.start,
      topLevel: classInfo.topLevel,
      doc: `${classInfo.kind === 'class' ? 'Classe' : 'Struct'} definita dall’utente.${classInfo.base ? ` Estende \`${classInfo.base}\`.` : ''}`
    };
    symbols.push(symbol);
  }

  return { uri, source, mask, symbols, classes, functions, variables, imports: parseImports(source) };
}

function findClassAt(analysis, offset) {
  return findEnclosingClass(analysis.classes, offset);
}

module.exports = {
  analyzeSymbols,
  parseImports,
  maskSource,
  parseParameters,
  signatureOf,
  findClassAt
};
