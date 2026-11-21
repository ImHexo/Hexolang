'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { analyzeSymbols, parseImports, parseParameters } = require('../symbol-index');

function byName(items, name) {
  return items.find((item) => item.name === name);
}

test('indexes user functions, typed variables, constants, classes and structs', () => {
  const source = `
    fn string greet(name: string, count: int) -> string { return name }
    class Person { let string name = "Ada"; fn string label() { return name } }
    struct Point { let float x = 1.5 }
    let int age = 18
    const title = "Hexo"
    let greeting = greet("Ada", 1)
    let person = Person()
  `;
  const result = analyzeSymbols(source, 'test.hexo');
  assert.equal(byName(result.functions, 'greet').returnType, 'string');
  assert.equal(byName(result.variables, 'age').type, 'int');
  assert.equal(byName(result.variables, 'title').type, 'string');
  assert.equal(byName(result.variables, 'greeting').type, 'string');
  assert.equal(byName(result.variables, 'person').type, 'Person');
  assert.equal(byName(result.classes, 'Person').kind, 'class');
  assert.equal(byName(result.classes, 'Point').kind, 'struct');
});

test('collects class and struct fields and methods, including static members', () => {
  const source = `
    class Base { fn void baseMethod() {} }
    class Person extends Base {
      let string name = "Ada"
      static let int population = 0
      fn string getName() { return name }
      static fn int count() { return population }
      fn void update() { let int localValue = 1 }
    }
  `;
  const result = analyzeSymbols(source, 'test.hexo');
  const person = byName(result.classes, 'Person');
  assert.ok(person);
  assert.equal(byName(person.members, 'name').type, 'string');
  assert.equal(byName(person.members, 'getName').returnType, 'string');
  assert.equal(byName(person.members, 'population').isStatic, true);
  assert.equal(byName(person.members, 'count').isStatic, true);
  assert.equal(byName(person.members, 'update').kind, 'method');
  assert.equal(byName(result.variables, 'localValue').type, 'int');
});

test('does not invent a type for an untyped identifier initializer', () => {
  const result = analyzeSymbols('let mystery = anotherVariable\nconst alsoMystery = callUnknown()', 'test.hexo');
  assert.equal(byName(result.variables, 'mystery').type, null);
  assert.equal(byName(result.variables, 'alsoMystery').type, null);
});

test('does not index declarations inside comments or string literals', () => {
  const source = `
    // let int commented = 1
    /* fn string hidden() {} */
    let string visible = "class Fake { fn void fake() {} }"
  `;
  const result = analyzeSymbols(source, 'test.hexo');
  assert.ok(byName(result.variables, 'visible'));
  assert.equal(byName(result.variables, 'commented'), undefined);
  assert.equal(byName(result.functions, 'hidden'), undefined);
  assert.equal(byName(result.classes, 'Fake'), undefined);
});

test('parses typed, optional and variadic parameters', () => {
  assert.deepEqual(parseParameters('name: string, count?: int, ...values'), [
    { name: 'name', type: 'string', optional: false },
    { name: 'count', type: 'int', optional: true },
    { name: '...values', type: 'any', optional: false }
  ]);
});


test('parses both module import forms and ignores strings/comments', () => {
  const source = `
    // import "comment.hexo" as ignored;
    const text = "from \\\"string.hexo\\\" import Hidden";
    import "lib/geometry.hexo" as geometry;
    from 'lib/geometry.hexo' import Rectangle, calculateArea;
  `;
  const imports = parseImports(source);
  assert.equal(imports.length, 2);
  assert.deepEqual(imports[0], {
    kind: 'module', path: 'lib/geometry.hexo', alias: 'geometry', names: [],
    offset: source.indexOf('import "lib/geometry.hexo"'),
    pathOffset: source.indexOf('"lib/geometry.hexo"'),
    aliasOffset: source.indexOf('geometry;')
  });
  assert.equal(imports[1].kind, 'named');
  assert.equal(imports[1].path, 'lib/geometry.hexo');
  assert.deepEqual(imports[1].names.map((item) => item.name), ['Rectangle', 'calculateArea']);
});

test('marks only top-level declarations as module exports', () => {
  const result = analyzeSymbols(`
    fn visible() {
      let local = 1;
      fn nested() {}
    }
    let exported = 2;
    class Box { let field = 1; fn method() {} }
  `, 'module.hexo');
  assert.equal(byName(result.functions, 'visible').topLevel, true);
  assert.equal(byName(result.functions, 'nested').topLevel, false);
  assert.equal(byName(result.variables, 'local').topLevel, false);
  assert.equal(byName(result.variables, 'exported').topLevel, true);
  assert.equal(byName(result.classes, 'Box').topLevel, true);
});


test('indexes public/private typed fields and methods in Hexo 0.5.3', () => {
  const result = analyzeSymbols(`
    class Vault {
      private int secret = 41;
      public int visible = 1;
      private static int key = 9;
      private fn hidden() { return this.secret; }
      public static fn getKey() { return Vault.key; }
    }
  `, 'vault.hexo');
  const vault = byName(result.classes, 'Vault');
  assert.equal(byName(vault.members, 'secret').type, 'int');
  assert.equal(byName(vault.members, 'secret').visibility, 'private');
  assert.equal(byName(vault.members, 'visible').visibility, 'public');
  assert.equal(byName(vault.members, 'key').isStatic, true);
  assert.equal(byName(vault.members, 'key').isPrivate, true);
  assert.equal(byName(vault.members, 'hidden').isPrivate, true);
  assert.equal(byName(vault.members, 'getKey').isStatic, true);
});


test('indexes the bundled standard-library exports for import completion', () => {
  const stdlib = path.join(__dirname, '..', 'stdlib');
  const math = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'math.hexo'), 'utf8'), 'stdlib/math.hexo');
  const os = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'system', 'os.hexo'), 'utf8'), 'stdlib/system/os.hexo');
  assert.equal(byName(math.functions, 'toDegrees').topLevel, true);
  assert.equal(byName(math.variables, 'sin').topLevel, true);
  assert.equal(byName(math.variables, 'TAU').topLevel, true);
  assert.equal(byName(os.functions, 'pathJoin').topLevel, true);
  assert.equal(byName(os.variables, 'readText').topLevel, true);
});


test('bundles every Hexo 0.5.3 standard-library module for IntelliSense', () => {
  const stdlib = path.join(__dirname, '..', 'stdlib');
  const moduleFiles = [
    'math.hexo', 'random.hexo', 'system/os.hexo', 'json.hexo',
    'tabular.hexo', 'sqlite.hexo', 'mysql.hexo', 'mariadb.hexo', 'hexoweb.hexo',
    'animath.hexo', 'game.hexo', 'simple_game.hexo',
    'game_3d.hexo', 'simple_game3d.hexo'
  ];
  for (const relative of moduleFiles) {
    const file = path.join(stdlib, relative);
    assert.ok(fs.existsSync(file), `missing bundled module: ${relative}`);
    const analysis = analyzeSymbols(fs.readFileSync(file, 'utf8'), relative);
    assert.ok(analysis.symbols.some((symbol) => symbol.topLevel), `no exports found in ${relative}`);
  }

  const json = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'json.hexo'), 'utf8'), 'json.hexo');
  assert.ok(byName(json.variables, 'parse'));
  assert.ok(byName(json.variables, 'stringify'));
  const web = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'hexoweb.hexo'), 'utf8'), 'hexoweb.hexo');
  assert.ok(byName(web.functions, 'createApp'));
  const db = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'sqlite.hexo'), 'utf8'), 'sqlite.hexo');
  assert.ok(byName(db.variables, 'prepare'));
  const graphics = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'game_3d.hexo'), 'utf8'), 'game_3d.hexo');
  assert.ok(byName(graphics.functions, 'drawCube'));
});

test('indexes the Hexo 0.5.3 raylib audio, render, controller and 3D model API surface', () => {
  const stdlib = path.join(__dirname, '..', 'stdlib');
  const simpleGame = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'simple_game.hexo'), 'utf8'), 'simple_game.hexo');
  const game3d = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'game_3d.hexo'), 'utf8'), 'game_3d.hexo');
  const simple3d = analyzeSymbols(fs.readFileSync(path.join(stdlib, 'simple_game3d.hexo'), 'utf8'), 'simple_game3d.hexo');

  for (const name of [
    'loadSound', 'playSound', 'pauseSound', 'resumeSound', 'setSoundPan',
    'loadMusicStream', 'updateMusicStream', 'seekMusicStream', 'setMusicPitch',
    'loadFont', 'drawTextEx', 'loadRenderTexture', 'beginTextureMode',
    'drawRenderTexture', 'isGamepadAvailable', 'getGamepadAxisMovement'
  ]) {
    assert.ok(byName(simpleGame.variables, name), `missing simple_game export ${name}`);
  }
  for (const name of ['drawPlane', 'drawCubeWires', 'drawSphereWires', 'drawCylinder', 'drawModel', 'drawModelEx', 'drawModelWires', 'drawModelWiresEx']) {
    assert.ok(byName(game3d.functions, name), `missing game_3d function ${name}`);
  }
  for (const name of ['loadModel', 'drawModel', 'unloadModel', 'drawModelEx', 'drawModelWiresEx']) {
    assert.ok(byName(simple3d.variables, name), `missing simple_game3d export ${name}`);
  }
});

test('indexes current 0.5.3 analytics, animation, database and web helpers', () => {
  const stdlib = path.join(__dirname, '..', 'stdlib');
  const read = (name) => analyzeSymbols(fs.readFileSync(path.join(stdlib, name), 'utf8'), name);
  const tabular = read('tabular.hexo');
  const animath = read('animath.hexo');
  const sqlite = read('sqlite.hexo');
  const mysql = read('mysql.hexo');
  const web = read('hexoweb.hexo');

  for (const name of ['groupByAggregate', 'pivot', 'melt', 'rollingMean', 'join']) {
    assert.ok(byName(tabular.functions, name), `missing tabular function ${name}`);
  }
  assert.ok(byName(animath.classes, 'Scene'));
  for (const name of ['scatterPlot', 'parametricPlot', 'barChart', 'histogram', 'lineChart']) {
    assert.ok(byName(animath.functions, name), `missing animath function ${name}`);
  }
  for (const name of ['queryPrepared', 'executePrepared', 'executeMany', 'queryObjects', 'scalarPrepared']) {
    assert.ok(byName(sqlite.functions, name), `missing sqlite helper ${name}`);
  }
  for (const name of ['queryPrepared', 'executePrepared', 'executeMany', 'queryObjects', 'withConnectionTLS']) {
    assert.ok(byName(mysql.functions, name), `missing mysql helper ${name}`);
  }
  assert.ok(byName(mysql.variables, 'openTLS'));
  assert.ok(byName(web.classes, 'App'));
  for (const name of ['createApp', 'htmlPage', 'jsonBody', 'formBody', 'requestInfo']) {
    assert.ok(byName(web.functions, name), `missing hexoweb helper ${name}`);
  }
});
