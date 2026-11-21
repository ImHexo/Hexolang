'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const data = require('../language-data');

const root = path.resolve(__dirname, '..');

 test('catalog contains the documented keyword and native API groups', () => {
  assert.ok(data.KEYWORD_SET.has('let'));
  assert.ok(data.KEYWORD_SET.has('finally'));
  assert.ok(data.KEYWORD_SET.has('import'));
  assert.ok(data.KEYWORD_SET.has('from'));
  assert.ok(data.KEYWORD_SET.has('as'));
  assert.ok(data.KEYWORD_SET.has('public'));
  assert.ok(data.KEYWORD_SET.has('private'));
  assert.ok(data.TYPE_NAMES.int);
  assert.ok(data.TYPE_NAMES.nil);
  assert.ok(data.TYPE_NAMES.ptr);
  assert.ok(data.TYPEOF_NAMES.includes('ptr'));
  assert.ok(data.GLOBAL_FUNCTIONS.print);
  assert.ok(data.GLOBAL_FUNCTIONS.range);
  assert.ok(data.GLOBAL_FUNCTIONS.sin);
  assert.ok(data.GLOBAL_FUNCTIONS.atan2);
  assert.ok(data.GLOBAL_FUNCTIONS.log10);
  assert.ok(data.GLOBAL_FUNCTIONS.readText);
  assert.ok(data.GLOBAL_FUNCTIONS.writeText);
  assert.ok(data.GLOBAL_FUNCTIONS.currentDirectory);
  assert.ok(data.GLOBAL_FUNCTIONS.random);
  assert.ok(data.GLOBAL_FUNCTIONS.randomInt);
  assert.ok(data.GLOBAL_CONSTANTS.PI);
  assert.ok(data.ARRAY_METHODS.map);
  assert.ok(data.STRING_METHODS.replace);
  assert.ok(data.COMMON_PROPERTIES.length);
});

test('signatureOf formats required, optional, typed and variadic parameters', () => {
  assert.equal(data.signatureOf('input', data.GLOBAL_FUNCTIONS.input), 'input(prompt?: string) -> string');
  assert.equal(data.signatureOf('range', data.GLOBAL_FUNCTIONS.range), 'range(inizio: int, fine?: int, passo?: int) -> int[]');
  assert.equal(data.signatureOf('print', data.GLOBAL_FUNCTIONS.print), 'print(...valori) -> nil');
  assert.equal(data.signatureOf('pow', data.GLOBAL_FUNCTIONS.pow), 'pow(base: number, esponente: number) -> number');
});

test('contribution files are valid JSON and the language is registered', () => {
  const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const grammar = JSON.parse(fs.readFileSync(path.join(root, 'syntaxes/hexo.tmLanguage.json'), 'utf8'));
  const languageConfig = JSON.parse(fs.readFileSync(path.join(root, 'language-configuration.json'), 'utf8'));
  const snippets = JSON.parse(fs.readFileSync(path.join(root, 'snippets/hexo.json'), 'utf8'));

  assert.equal(packageJson.contributes.languages[0].id, 'hexo');
  assert.deepEqual(packageJson.contributes.languages[0].extensions, ['.hexo']);
  assert.equal(grammar.scopeName, 'source.hexo');
  assert.ok(languageConfig.brackets.length >= 3);
  assert.ok(snippets['Function declaration']);
  assert.ok(snippets['Pointer address']);
  assert.ok(snippets['Private method']);
  assert.ok(grammar.repository.numbers.patterns[0].match.includes('0[xX]'));
  assert.match(grammar.repository.operators.patterns[0].match, /&/);
});


test('catalog documents the Hexo 0.5.3 libm math API', () => {
  for (const name of ['sin', 'cos', 'tan', 'atan2', 'log', 'log10', 'exp', 'fmod', 'hypot']) {
    assert.ok(data.GLOBAL_FUNCTIONS[name], `missing ${name}`);
  }
});

test('extension manifest and documentation target the runtime 0.5.3 release', () => {
  const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
  assert.equal(packageJson.version, '0.5.3');
  assert.match(packageJson.description, /0\.5\.3/);
  assert.match(readme, /0\.5\.3/);
});

test('bundled standard library matches the Development Kit source tree', () => {
  const sourceRoot = path.resolve(root, '..', 'stdlib');
  if (!fs.existsSync(sourceRoot)) return;
  const bundleRoot = path.join(root, 'stdlib');
  const collect = (base, directory = base) => {
    const result = [];
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) result.push(...collect(base, full));
      else if (entry.isFile()) result.push(path.relative(base, full).split(path.sep).join('/'));
    }
    return result;
  };
  const sourceFiles = collect(sourceRoot).sort();
  const bundleFiles = collect(bundleRoot).sort();
  assert.deepEqual(bundleFiles, sourceFiles, 'bundled standard-library file list differs from runtime');
  for (const relative of sourceFiles) {
    assert.deepEqual(
      fs.readFileSync(path.join(bundleRoot, relative)),
      fs.readFileSync(path.join(sourceRoot, relative)),
      `bundled file is stale: ${relative}`
    );
  }
});
