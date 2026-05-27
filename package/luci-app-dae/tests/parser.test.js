'use strict';
var assert = require('assert');
var DaeParser = require('../htdocs/luci-static/resources/view/dae/dae-parser.js');

var passed = 0, failed = 0;
function test(name, fn) {
    try { fn(); console.log('  PASS: ' + name); passed++; }
    catch (e) { console.log('  FAIL: ' + name + '\n    ' + e.message); failed++; }
}

// ---- _extractBlocks ----
console.log('\n_extractBlocks:');

test('parses a single block', function() {
    var r = DaeParser._extractBlocks('global {\n    key: val\n}');
    assert.ok(r['global'].trim().includes('key: val'));
});

test('parses multiple blocks', function() {
    var r = DaeParser._extractBlocks('global {\n    k: v\n}\nsubscription {\n    s: "url"\n}');
    assert.ok(r['global']);
    assert.ok(r['subscription']);
});

test('stores pre-block lines in __preamble', function() {
    var r = DaeParser._extractBlocks('# top comment\nglobal {\n    k: v\n}');
    assert.ok((r['__preamble'] || '').includes('# top comment'));
});

test('handles nested braces without splitting block', function() {
    var r = DaeParser._extractBlocks('dns {\n    upstream {\n        a: "b"\n    }\n}');
    assert.ok(r['dns'] && r['dns'].includes('upstream'));
    assert.strictEqual(r['upstream'], undefined);
});

test('handles block with content on same line as opening brace', function() {
    var r = DaeParser._extractBlocks('global { log-level: info\n}');
    assert.ok(r['global'].includes('log-level: info'));
});

test('returns empty object for empty input', function() {
    var r = DaeParser._extractBlocks('');
    assert.deepStrictEqual(r, {});
});

console.log('\n--- Results ---');
console.log('Passed: ' + passed + '  Failed: ' + failed);
if (failed > 0) process.exit(1);
