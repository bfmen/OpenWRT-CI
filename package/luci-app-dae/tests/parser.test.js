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

// ---- _parseKV ----
console.log('\n_parseKV:');

test('parses single-quoted value', function() {
    var r = DaeParser._parseKV("    my_sub: 'https://example.com'");
    assert.strictEqual(r['my_sub'], 'https://example.com');
});

test('parses double-quoted value', function() {
    var r = DaeParser._parseKV('    name: "https://example.com"');
    assert.strictEqual(r['name'], 'https://example.com');
});

test('parses unquoted value', function() {
    var r = DaeParser._parseKV('    log-level: info');
    assert.strictEqual(r['log-level'], 'info');
});

test('parses hyphenated key', function() {
    var r = DaeParser._parseKV('    lan-interface: br-lan');
    assert.strictEqual(r['lan-interface'], 'br-lan');
});

test('skips comment lines', function() {
    var r = DaeParser._parseKV('# comment\n    key: val');
    assert.strictEqual(Object.keys(r).length, 1);
    assert.strictEqual(r['key'], 'val');
});

test('skips empty lines', function() {
    var r = DaeParser._parseKV('\n\n    key: val\n\n');
    assert.strictEqual(Object.keys(r).length, 1);
});

test('returns empty object for empty content', function() {
    var r = DaeParser._parseKV('');
    assert.deepStrictEqual(r, {});
});

// ---- _parseRoutingRules ----
console.log('\n_parseRoutingRules:');

test('parses domain rule', function() {
    var r = DaeParser._parseRoutingRules('    domain(geosite:cn) -> direct');
    assert.strictEqual(r.rules.length, 1);
    assert.strictEqual(r.rules[0].condType, 'domain');
    assert.strictEqual(r.rules[0].condValue, 'geosite:cn');
    assert.strictEqual(r.rules[0].action, 'direct');
});

test('parses dip rule', function() {
    var r = DaeParser._parseRoutingRules('    dip(geoip:private) -> direct');
    assert.strictEqual(r.rules[0].condType, 'dip');
    assert.strictEqual(r.rules[0].condValue, 'geoip:private');
});

test('parses fallback line', function() {
    var r = DaeParser._parseRoutingRules('    fallback: my_proxy');
    assert.strictEqual(r.fallback, 'my_proxy');
});

test('parses multiple rules with fallback', function() {
    var content = '    domain(geosite:cn) -> direct\n    dip(geoip:cn) -> direct\n    fallback: proxy';
    var r = DaeParser._parseRoutingRules(content);
    assert.strictEqual(r.rules.length, 2);
    assert.strictEqual(r.fallback, 'proxy');
});

test('skips comment lines in routing', function() {
    var content = '    # a comment\n    domain(geosite:cn) -> direct\n    fallback: proxy';
    var r = DaeParser._parseRoutingRules(content);
    assert.strictEqual(r.rules.length, 1);
});

test('defaults fallback to direct when missing', function() {
    var r = DaeParser._parseRoutingRules('    domain(geosite:cn) -> direct');
    assert.strictEqual(r.fallback, 'direct');
});

console.log('\n--- Results ---');
console.log('Passed: ' + passed + '  Failed: ' + failed);
if (failed > 0) process.exit(1);
