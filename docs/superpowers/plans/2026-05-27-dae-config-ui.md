# dae Config UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the raw text editor in `luci-app-dae`'s Config page with a tab-based UI: a structured form (表单模式) alongside the existing text editor (文本模式), sharing the same `/etc/dae/config.dae` file.

**Architecture:** Client-side JS only — `dae-parser.js` handles DSL parsing/serialization (dual-environment: LuCI AMD + Node.js), `config.js` provides the tab-switching view with five form sections plus a raw textarea. Tab switching triggers parse/serialize. Unknown config blocks are preserved in `rawOther`.

**Tech Stack:** LuCI view framework (`view.extend`), vanilla DOM via `E()` helper, `fs.read_direct`/`fs.write`, Node.js built-in `assert` module for parser tests (no external dependencies).

---

## File Map

| File | Change | Responsibility |
|------|--------|----------------|
| `package/luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js` | **Create** | Parse dae DSL → `DaeConfig`; serialize `DaeConfig` → string |
| `package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js` | **Rewrite** | Tab UI, form sections, file I/O, hot_reload |
| `package/luci-app-dae/tests/parser.test.js` | **Create** | Node.js tests for dae-parser.js |
| `package/luci-app-dae/po/zh_Hans/dae.po` | **Modify** | Chinese translations for new strings |
| `package/luci-app-dae/po/templates/dae.pot` | **Modify** | Translation template for new strings |

### DaeConfig shape

```
DaeConfig {
  global:       { [key: string]: string }
  subscription: { [name: string]: url }
  node:         { [name: string]: uri }
  routing: {
    rules: [ { condType: string, condValue: string, action: string } ]
    fallback: string
  }
  dns: {
    upstream:   { [name: string]: url }
    domestic:   string   // upstream name; empty = use rawRouting
    foreign:    string   // upstream name; empty = use rawRouting
    rawRouting: string   // raw routing block content if not simple template
  }
  rawOther: string  // unknown top-level blocks, preserved verbatim
}
```

---

## Task 1: Create dae-parser.js skeleton + `_extractBlocks`

**Files:**
- Create: `package/luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js`
- Create: `package/luci-app-dae/tests/parser.test.js`

- [ ] **Step 1: Create tests directory and write failing tests for `_extractBlocks`**

Create `package/luci-app-dae/tests/parser.test.js`:

```javascript
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
```

- [ ] **Step 2: Run tests — expect FAIL (module not found)**

```bash
cd /tmp/openwrt-dae-work/package/luci-app-dae
node tests/parser.test.js
```

Expected output: `Error: Cannot find module '../htdocs/luci-static/resources/view/dae/dae-parser.js'`

- [ ] **Step 3: Create `dae-parser.js` with `_extractBlocks` implemented**

Create `package/luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js`:

```javascript
// SPDX-License-Identifier: Apache-2.0
'use strict';

var DaeParser = {

    /**
     * Extract top-level named blocks from dae config text.
     * Returns { blockName: contentString, ... }
     * Content strings do NOT include the outer braces.
     * Lines outside any block are stored in '__preamble'.
     * Duplicate block names are concatenated with '\n'.
     */
    _extractBlocks: function(text) {
        var blocks = {};
        var preamble = [];
        var currentBlock = null;
        var depth = 0;
        var bufferLines = [];

        var lines = text.split('\n');
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            var trimmed = line.trim();

            if (currentBlock === null) {
                // Match "blockname {" or "blockname{ rest..."
                var m = trimmed.match(/^([\w][\w-]*)\s*\{(.*)$/);
                if (m) {
                    currentBlock = m[1];
                    var afterBrace = m[2];
                    depth = 1;
                    for (var j = 0; j < afterBrace.length; j++) {
                        if (afterBrace[j] === '{') depth++;
                        else if (afterBrace[j] === '}') depth--;
                    }
                    if (depth <= 0) {
                        // Single-line block: "block { content }"
                        var inner = afterBrace.replace(/}[^}]*$/, '').trim();
                        blocks[currentBlock] = blocks[currentBlock] != null
                            ? blocks[currentBlock] + '\n' + inner : inner;
                        currentBlock = null;
                        depth = 0;
                    } else {
                        bufferLines = afterBrace.trim() ? [afterBrace] : [];
                    }
                } else {
                    preamble.push(line);
                }
            } else {
                // Count depth changes on this line
                for (var j = 0; j < trimmed.length; j++) {
                    if (trimmed[j] === '{') depth++;
                    else if (trimmed[j] === '}') depth--;
                }
                if (depth <= 0) {
                    // Closing brace found — strip it and everything after
                    var idx = line.lastIndexOf('}');
                    var beforeClose = line.substring(0, idx).trim();
                    if (beforeClose) bufferLines.push(beforeClose);
                    var content = bufferLines.join('\n');
                    blocks[currentBlock] = blocks[currentBlock] != null
                        ? blocks[currentBlock] + '\n' + content : content;
                    currentBlock = null;
                    depth = 0;
                    bufferLines = [];
                } else {
                    bufferLines.push(line);
                }
            }
        }

        if (preamble.length > 0)
            blocks['__preamble'] = preamble.join('\n');

        return blocks;
    },

    // Stubs — implemented in later tasks
    _parseKV:           function() { return {}; },
    _parseRoutingRules: function() { return { rules: [], fallback: 'direct' }; },
    _parseDNS:          function() { return { upstream: {}, domestic: '', foreign: '', rawRouting: '' }; },
    parse:              function() { return { global: {}, subscription: {}, node: {}, routing: { rules: [], fallback: 'direct' }, dns: { upstream: {}, domestic: '', foreign: '', rawRouting: '' }, rawOther: '' }; },
    serialize:          function() { return ''; }
};

if (typeof module !== 'undefined') module.exports = DaeParser;
return DaeParser;
```

- [ ] **Step 4: Run tests — all should pass**

```bash
cd /tmp/openwrt-dae-work/package/luci-app-dae
node tests/parser.test.js
```

Expected: `Passed: 6  Failed: 0`

- [ ] **Step 5: Commit**

```bash
cd /tmp/openwrt-dae-work
git add package/luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js \
        package/luci-app-dae/tests/parser.test.js
git commit -m "feat(luci-app-dae): add dae-parser.js skeleton with _extractBlocks

- DaeParser._extractBlocks handles nested braces and duplicate block names
- Dual-environment: works as LuCI AMD module and Node.js require()
- Test scaffold with 6 passing tests

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 2: Add `_parseKV` and `_parseRoutingRules`

**Files:**
- Modify: `package/luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js`
- Modify: `package/luci-app-dae/tests/parser.test.js`

- [ ] **Step 1: Append tests for `_parseKV` and `_parseRoutingRules` to `parser.test.js`**

Add these test blocks before the final summary lines in `tests/parser.test.js`:

```javascript
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
```

- [ ] **Step 2: Run tests — new tests should fail (stubs return empty)**

```bash
cd /tmp/openwrt-dae-work/package/luci-app-dae
node tests/parser.test.js
```

Expected: `_parseKV` and `_parseRoutingRules` tests all FAIL.

- [ ] **Step 3: Implement `_parseKV` and `_parseRoutingRules` in `dae-parser.js`**

Replace the stub lines for `_parseKV` and `_parseRoutingRules`:

```javascript
    /**
     * Parse "name: value" lines.
     * Handles 'single-quoted', "double-quoted", and unquoted values.
     * Returns { name: value } with quotes stripped.
     * Skips # comments and blank lines.
     */
    _parseKV: function(content) {
        var result = {};
        var lines = content.split('\n');
        for (var i = 0; i < lines.length; i++) {
            var trimmed = lines[i].trim();
            if (!trimmed || trimmed[0] === '#') continue;
            var m = trimmed.match(/^([\w][\w-]*)\s*:\s*(.*)$/);
            if (!m) continue;
            var key = m[1];
            var val = m[2].trim();
            // Strip leading/trailing quote (same char)
            val = val.replace(/^(['"])(.*)\1$/, '$2');
            result[key] = val;
        }
        return result;
    },

    /**
     * Parse routing block content → { rules: [...], fallback: string }
     * Each rule: condType(condValue) -> action
     * Fallback: fallback: action
     */
    _parseRoutingRules: function(content) {
        var rules = [];
        var fallback = 'direct';
        var lines = content.split('\n');
        for (var i = 0; i < lines.length; i++) {
            var trimmed = lines[i].trim();
            if (!trimmed || trimmed[0] === '#') continue;
            var fb = trimmed.match(/^fallback\s*:\s*(\S+)/);
            if (fb) { fallback = fb[1]; continue; }
            var rule = trimmed.match(/^([\w!][\w-]*)\(([^)]*)\)\s*->\s*(\S+)/);
            if (rule) {
                rules.push({ condType: rule[1], condValue: rule[2].trim(), action: rule[3] });
            }
        }
        return { rules: rules, fallback: fallback };
    },
```

- [ ] **Step 4: Run tests — all should pass**

```bash
node tests/parser.test.js
```

Expected: `Passed: 19  Failed: 0`

- [ ] **Step 5: Commit**

```bash
cd /tmp/openwrt-dae-work
git add package/luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js \
        package/luci-app-dae/tests/parser.test.js
git commit -m "feat(luci-app-dae): implement _parseKV and _parseRoutingRules

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 3: Add `_parseDNS`, `parse()`, `serialize()`

**Files:**
- Modify: `package/luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js`
- Modify: `package/luci-app-dae/tests/parser.test.js`

- [ ] **Step 1: Add tests for `_parseDNS`, `parse()`, `serialize()` to `parser.test.js`**

Append before the final summary lines:

```javascript
// ---- _parseDNS ----
console.log('\n_parseDNS:');

var DNS_SIMPLE = [
    '    upstream {',
    "        alidns: 'udp://223.5.5.5:53'",
    "        googledns: 'tcp+udp://8.8.8.8:53'",
    '    }',
    '    routing {',
    '        request {',
    '            qname(geosite:cn) -> alidns',
    '            fallback: googledns',
    '        }',
    '        response {',
    '            upstream(googledns) -> accept',
    '            !qname(geosite:cn) -> googledns',
    '            fallback: accept',
    '        }',
    '    }'
].join('\n');

test('parses upstream servers', function() {
    var r = DaeParser._parseDNS(DNS_SIMPLE);
    assert.strictEqual(r.upstream['alidns'], 'udp://223.5.5.5:53');
    assert.strictEqual(r.upstream['googledns'], 'tcp+udp://8.8.8.8:53');
});

test('detects simplified domestic/foreign template', function() {
    var r = DaeParser._parseDNS(DNS_SIMPLE);
    assert.strictEqual(r.domestic, 'alidns');
    assert.strictEqual(r.foreign, 'googledns');
    assert.strictEqual(r.rawRouting, '');
});

test('stores non-template routing as rawRouting', function() {
    var custom = "    upstream {\n        alidns: 'udp://223.5.5.5:53'\n    }\n    routing {\n        request {\n            custom_rule(foo) -> bar\n        }\n    }";
    var r = DaeParser._parseDNS(custom);
    assert.ok(r.rawRouting.length > 0);
    assert.strictEqual(r.domestic, '');
    assert.strictEqual(r.foreign, '');
});

test('handles dns block with no routing sub-block', function() {
    var r = DaeParser._parseDNS("    upstream {\n        alidns: 'udp://223.5.5.5:53'\n    }");
    assert.strictEqual(r.upstream['alidns'], 'udp://223.5.5.5:53');
    assert.strictEqual(r.rawRouting, '');
});

// ---- parse() ----
console.log('\nparse():');

var FULL_CONFIG = [
    'global {',
    '    log-level: info',
    '    lan-interface: br-lan',
    '    wan-interface: eth1',
    '}',
    '',
    'subscription {',
    "    my_sub: 'https://example.com/sub'",
    '}',
    '',
    'dns {',
    '    upstream {',
    "        alidns: 'udp://223.5.5.5:53'",
    "        googledns: 'tcp+udp://8.8.8.8:53'",
    '    }',
    '    routing {',
    '        request {',
    '            qname(geosite:cn) -> alidns',
    '            fallback: googledns',
    '        }',
    '        response {',
    '            upstream(googledns) -> accept',
    '            !qname(geosite:cn) -> googledns',
    '            fallback: accept',
    '        }',
    '    }',
    '}',
    '',
    'routing {',
    '    domain(geosite:cn) -> direct',
    '    dip(geoip:cn) -> direct',
    '    dip(geoip:private) -> direct',
    '    fallback: my_sub',
    '}'
].join('\n');

test('parses global block', function() {
    var c = DaeParser.parse(FULL_CONFIG);
    assert.strictEqual(c.global['log-level'], 'info');
    assert.strictEqual(c.global['lan-interface'], 'br-lan');
    assert.strictEqual(c.global['wan-interface'], 'eth1');
});

test('parses subscription block', function() {
    var c = DaeParser.parse(FULL_CONFIG);
    assert.strictEqual(c.subscription['my_sub'], 'https://example.com/sub');
});

test('parses dns upstream and detects template', function() {
    var c = DaeParser.parse(FULL_CONFIG);
    assert.strictEqual(c.dns.upstream['alidns'], 'udp://223.5.5.5:53');
    assert.strictEqual(c.dns.domestic, 'alidns');
    assert.strictEqual(c.dns.foreign, 'googledns');
    assert.strictEqual(c.dns.rawRouting, '');
});

test('parses routing rules', function() {
    var c = DaeParser.parse(FULL_CONFIG);
    assert.strictEqual(c.routing.rules.length, 3);
    assert.strictEqual(c.routing.rules[0].condType, 'domain');
    assert.strictEqual(c.routing.fallback, 'my_sub');
});

test('stores unknown blocks in rawOther', function() {
    var withUnknown = FULL_CONFIG + '\n\nunknown_block {\n    x: y\n}';
    var c = DaeParser.parse(withUnknown);
    assert.ok(c.rawOther.includes('unknown_block'));
});

// ---- serialize() ----
console.log('\nserialize():');

test('serialize output is re-parseable (round-trip)', function() {
    var c = DaeParser.parse(FULL_CONFIG);
    var s = DaeParser.serialize(c);
    var c2 = DaeParser.parse(s);
    assert.deepStrictEqual(c2.global, c.global);
    assert.deepStrictEqual(c2.subscription, c.subscription);
    assert.deepStrictEqual(c2.dns.upstream, c.dns.upstream);
    assert.strictEqual(c2.dns.domestic, c.dns.domestic);
    assert.strictEqual(c2.dns.foreign, c.dns.foreign);
    assert.deepStrictEqual(c2.routing.rules, c.routing.rules);
    assert.strictEqual(c2.routing.fallback, c.routing.fallback);
});

test('global block comes before subscription block', function() {
    var c = DaeParser.parse(FULL_CONFIG);
    var s = DaeParser.serialize(c);
    assert.ok(s.indexOf('global {') < s.indexOf('subscription {'));
});

test('serialize preserves rawOther', function() {
    var withUnknown = FULL_CONFIG + '\n\nunknown_block {\n    x: y\n}';
    var c = DaeParser.parse(withUnknown);
    var s = DaeParser.serialize(c);
    assert.ok(s.includes('unknown_block'));
});

test('serialize generates simplified dns routing template', function() {
    var c = DaeParser.parse(FULL_CONFIG);
    var s = DaeParser.serialize(c);
    assert.ok(s.includes('qname(geosite:cn) -> alidns'));
    assert.ok(s.includes('upstream(googledns) -> accept'));
});

test('serialize skips empty blocks', function() {
    var c = DaeParser.parse('routing {\n    fallback: direct\n}');
    var s = DaeParser.serialize(c);
    assert.ok(!s.includes('subscription {'));
    assert.ok(!s.includes('node {'));
});
```

- [ ] **Step 2: Run tests — new tests should fail**

```bash
cd /tmp/openwrt-dae-work/package/luci-app-dae
node tests/parser.test.js
```

Expected: `_parseDNS`, `parse()`, `serialize()` tests all FAIL.

- [ ] **Step 3: Implement `_parseDNS`, `parse()`, `serialize()` in `dae-parser.js`**

Replace the three stub lines with the full implementations:

```javascript
    /**
     * Parse dns block content.
     * Returns { upstream: {name: url}, domestic, foreign, rawRouting }
     * Detects the simplified domestic/foreign template; stores custom
     * routing verbatim in rawRouting.
     */
    _parseDNS: function(content) {
        var self = this;
        var result = { upstream: {}, domestic: '', foreign: '', rawRouting: '' };
        var subBlocks = self._extractBlocks(content);

        if (subBlocks['upstream'])
            result.upstream = self._parseKV(subBlocks['upstream']);

        if (subBlocks['routing']) {
            var routingContent = subBlocks['routing'];
            var rb = self._extractBlocks(routingContent);
            var reqLines = (rb['request'] || '').split('\n')
                .map(function(l) { return l.trim(); }).filter(Boolean);
            var respLines = (rb['response'] || '').split('\n')
                .map(function(l) { return l.trim(); }).filter(Boolean);

            // Check simplified template:
            // request: qname(geosite:cn) -> <dom>, fallback: <for>
            // response: upstream(<for>) -> accept, !qname(geosite:cn) -> <for>, fallback: accept
            var isSimple = false, domestic = '', foreign = '';
            if (reqLines.length === 2) {
                var r1 = reqLines[0].match(/^qname\(geosite:cn\)\s*->\s*(\S+)/);
                var r2 = reqLines[1].match(/^fallback\s*:\s*(\S+)/);
                if (r1 && r2) {
                    domestic = r1[1]; foreign = r2[1];
                    if (respLines.length === 3) {
                        var s1 = respLines[0].match(/^upstream\((\S+)\)\s*->\s*accept/);
                        var s2 = respLines[1].match(/^!qname\(geosite:cn\)\s*->\s*(\S+)/);
                        var s3 = respLines[2].match(/^fallback\s*:\s*accept/);
                        if (s1 && s1[1] === foreign && s2 && s2[1] === foreign && s3)
                            isSimple = true;
                    }
                }
            }
            if (isSimple) { result.domestic = domestic; result.foreign = foreign; }
            else { result.rawRouting = routingContent; }
        }
        return result;
    },

    /**
     * Parse full dae config text → DaeConfig object.
     */
    parse: function(text) {
        var self = this;
        var blocks = self._extractBlocks(text);
        var config = {
            global: {}, subscription: {}, node: {},
            routing: { rules: [], fallback: 'direct' },
            dns: { upstream: {}, domestic: '', foreign: '', rawRouting: '' },
            rawOther: ''
        };

        if (blocks['global'])       config.global       = self._parseKV(blocks['global']);
        if (blocks['subscription']) config.subscription = self._parseKV(blocks['subscription']);
        if (blocks['node'])         config.node         = self._parseKV(blocks['node']);
        if (blocks['routing'])      config.routing      = self._parseRoutingRules(blocks['routing']);
        if (blocks['dns'])          config.dns          = self._parseDNS(blocks['dns']);

        // Preserve unknown blocks verbatim
        var known = ['global', 'subscription', 'node', 'routing', 'dns', '__preamble'];
        var otherParts = blocks['__preamble'] ? [blocks['__preamble']] : [];
        for (var name in blocks) {
            if (known.indexOf(name) === -1)
                otherParts.push(name + ' {\n' + blocks[name] + '\n}');
        }
        config.rawOther = otherParts.join('\n\n');
        return config;
    },

    /**
     * Serialize DaeConfig → dae DSL string.
     * Order: global → subscription → node → dns → routing → rawOther
     */
    serialize: function(config) {
        var parts = [];
        var g = config.global || {}, gk = Object.keys(g);
        if (gk.length) {
            var ls = ['global {'];
            gk.forEach(function(k) { ls.push('    ' + k + ': ' + g[k]); });
            ls.push('}'); parts.push(ls.join('\n'));
        }

        var sk = Object.keys(config.subscription || {});
        if (sk.length) {
            var ls = ['subscription {'];
            sk.forEach(function(k) { ls.push("    " + k + ": '" + config.subscription[k] + "'"); });
            ls.push('}'); parts.push(ls.join('\n'));
        }

        var nk = Object.keys(config.node || {});
        if (nk.length) {
            var ls = ['node {'];
            nk.forEach(function(k) { ls.push("    " + k + ": '" + config.node[k] + "'"); });
            ls.push('}'); parts.push(ls.join('\n'));
        }

        var dns = config.dns || {};
        var uk = Object.keys(dns.upstream || {});
        if (uk.length || dns.domestic || dns.foreign || dns.rawRouting) {
            var ls = ['dns {'];
            if (uk.length) {
                ls.push('    upstream {');
                uk.forEach(function(k) { ls.push("        " + k + ": '" + dns.upstream[k] + "'"); });
                ls.push('    }');
            }
            if (dns.rawRouting) {
                ls.push('    routing {');
                dns.rawRouting.split('\n').forEach(function(l) { ls.push('    ' + l); });
                ls.push('    }');
            } else if (dns.domestic || dns.foreign) {
                var dom = dns.domestic || (uk[0] || '');
                var fgn = dns.foreign  || (uk[1] || '');
                ls.push('    routing {');
                ls.push('        request {');
                ls.push('            qname(geosite:cn) -> ' + dom);
                ls.push('            fallback: ' + fgn);
                ls.push('        }');
                ls.push('        response {');
                ls.push('            upstream(' + fgn + ') -> accept');
                ls.push('            !qname(geosite:cn) -> ' + fgn);
                ls.push('            fallback: accept');
                ls.push('        }');
                ls.push('    }');
            }
            ls.push('}'); parts.push(ls.join('\n'));
        }

        var routing = config.routing || {};
        var rules = routing.rules || [];
        var fb = routing.fallback || 'direct';
        {
            var ls = ['routing {'];
            rules.forEach(function(r) {
                ls.push('    ' + r.condType + '(' + r.condValue + ') -> ' + r.action);
            });
            ls.push('    fallback: ' + fb);
            ls.push('}'); parts.push(ls.join('\n'));
        }

        if (config.rawOther) parts.push(config.rawOther);
        return parts.join('\n\n');
    }
```

- [ ] **Step 4: Run full test suite — all tests pass**

```bash
cd /tmp/openwrt-dae-work/package/luci-app-dae
node tests/parser.test.js
```

Expected: `Passed: 38  Failed: 0`  
(6 + 13 + 19 = 38; exact count may vary slightly by implementation)

- [ ] **Step 5: Commit**

```bash
cd /tmp/openwrt-dae-work
git add package/luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js \
        package/luci-app-dae/tests/parser.test.js
git commit -m "feat(luci-app-dae): complete dae-parser.js with parse() and serialize()

- _parseDNS detects simplified domestic/foreign template
- parse() + serialize() round-trip tested
- rawOther preserves unknown blocks verbatim

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 4: Rewrite `config.js` — skeleton (load, tab switching, text pane, save)

**Files:**
- Modify: `package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Replace `config.js` entirely with the new view skeleton**

```javascript
// SPDX-License-Identifier: Apache-2.0
'use strict';
'require fs';
'require ui';
'require view';

return view.extend({
    /* Active tab: 'form' | 'text' */
    _activeTab: 'form',
    /* Parsed DaeConfig; valid when form tab last rendered */
    _config: null,
    /* Reference to DaeParser module; set in render() */
    _parser: null,

    render: function() {
        var self = this;
        return Promise.all([
            fs.read_direct('/etc/dae/config.dae', 'text').catch(function() {
                return fs.read_direct('/etc/dae/example.dae', 'text').catch(function() {
                    return '';
                });
            }),
            L.require('view/dae/dae-parser')
        ]).then(function(results) {
            var content = results[0] || '';
            self._parser = results[1];
            try {
                self._config = self._parser.parse(content);
            } catch(e) {
                self._config = self._parser.parse('');
                self._activeTab = 'text';
                ui.addNotification(null, E('p', _('Config parse error — opened in text mode: ') + e.message));
            }
            return self._buildUI(content);
        }).catch(function(e) {
            ui.addNotification(null, E('p', e.message));
            return E('div', {}, _('Failed to load configuration.'));
        });
    },

    _buildUI: function(rawText) {
        var self = this;
        var container = E('div', { 'class': 'dae-config-container' });

        // ── Tab bar ──────────────────────────────────────────────────────────
        container.appendChild(E('ul', { 'class': 'cbi-tabmenu' }, [
            E('li', {
                'id': 'tab-btn-form',
                'class': 'cbi-tab' + (self._activeTab === 'form' ? ' cbi-tab-active' : ''),
                'click': function() { self._switchTab('form'); }
            }, _('Form')),
            E('li', {
                'id': 'tab-btn-text',
                'class': 'cbi-tab' + (self._activeTab === 'text' ? ' cbi-tab-active' : ''),
                'click': function() { self._switchTab('text'); }
            }, _('Text'))
        ]));

        // ── Form pane ─────────────────────────────────────────────────────────
        var formPane = self._buildFormPane();
        formPane.id = 'pane-form';
        formPane.style.display = self._activeTab === 'form' ? '' : 'none';
        container.appendChild(formPane);

        // ── Text pane ─────────────────────────────────────────────────────────
        container.appendChild(E('div', {
            'id': 'pane-text',
            'style': self._activeTab === 'text' ? '' : 'display:none'
        }, [
            E('textarea', {
                'id': 'dae-raw-text',
                'class': 'cbi-input-textarea',
                'rows': '30',
                'style': 'width:100%;font-family:monospace;white-space:pre'
            }, [rawText])
        ]));

        return container;
    },

    _switchTab: function(tab) {
        var self = this;
        if (tab === self._activeTab) return;

        if (tab === 'text') {
            // Form → Text: serialize current form data
            try {
                var text = self._parser.serialize(self._getFormData());
                document.getElementById('dae-raw-text').value = text;
            } catch(e) {
                ui.addNotification(null, E('p', _('Failed to serialize form: ') + e.message));
                return;
            }
        } else {
            // Text → Form: parse text and rebuild form
            var text = document.getElementById('dae-raw-text').value;
            try {
                self._config = self._parser.parse(text);
                self._refreshForm();
            } catch(e) {
                ui.addNotification(null, E('p', _('Config text has errors. Please fix before switching to form mode.')));
                return;
            }
        }

        self._activeTab = tab;
        document.getElementById('pane-form').style.display = tab === 'form' ? '' : 'none';
        document.getElementById('pane-text').style.display = tab === 'text'  ? '' : 'none';
        document.getElementById('tab-btn-form').classList.toggle('cbi-tab-active', tab === 'form');
        document.getElementById('tab-btn-text').classList.toggle('cbi-tab-active', tab === 'text');
    },

    // ── Stubs implemented in Tasks 5–7 ──────────────────────────────────────
    _buildFormPane:          function() { return E('div', { 'class': 'cbi-section' }, _('(form sections coming soon)')); },
    _buildSubscriptionSection: function() { return E('div'); },
    _buildNodeSection:         function() { return E('div'); },
    _buildRoutingSection:      function() { return E('div'); },
    _buildDNSSection:          function() { return E('div'); },
    _buildGlobalSection:       function() { return E('div'); },
    _makeSubRow:               function()  { return E('tr'); },
    _makeNodeRow:              function()  { return E('tr'); },
    _makeRoutingRow:           function()  { return E('tr'); },
    _makeActionSelect:         function()  { return E('select'); },
    _makeDNSUpstreamRow:       function()  { return E('tr'); },
    _makeDNSSelect:            function()  { return E('select'); },
    _getFormData:              function()  { return self._config || {}; },
    _refreshForm:              function()  {},

    // ── Save ─────────────────────────────────────────────────────────────────
    handleSaveApply: function(ev, mode) {
        var self = this;
        var text;
        if (self._activeTab === 'form') {
            try { text = self._parser.serialize(self._getFormData()); }
            catch(e) {
                ui.addNotification(null, E('p', _('Failed to serialize form: ') + e.message));
                return Promise.resolve();
            }
        } else {
            text = document.getElementById('dae-raw-text').value;
        }
        return fs.write('/etc/dae/config.dae', text, 384)
            .then(function() {
                return L.resolveDefault(fs.exec_direct('/etc/init.d/dae', ['hot_reload']), null);
            })
            .then(function() {
                ui.addNotification(null, E('p', _('Configuration saved and dae reloaded.')));
            })
            .catch(function(e) {
                ui.addNotification(null, E('p', e.message));
            });
    }
});
```

- [ ] **Step 2: Verify the file was written correctly**

```bash
head -5 /tmp/openwrt-dae-work/package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
```

Expected first line: `// SPDX-License-Identifier: Apache-2.0`

- [ ] **Step 3: Commit**

```bash
cd /tmp/openwrt-dae-work
git add package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(luci-app-dae): rewrite config.js with tab-switching skeleton

- Tab bar: Form / Text mode
- Text pane with monospace textarea
- handleSaveApply serializes active tab's content
- Form sections stubbed; implemented in follow-up commits

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 5: Add subscription and node form sections

**Files:**
- Modify: `package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Replace the `_buildFormPane`, subscription, and node stubs**

In `config.js`, replace the stub methods `_buildFormPane`, `_buildSubscriptionSection`, `_buildNodeSection`, `_makeSubRow`, `_makeNodeRow` with:

```javascript
    _buildFormPane: function() {
        var self = this;
        var pane = E('div', { 'class': 'cbi-section' });
        pane.appendChild(self._buildSubscriptionSection());
        pane.appendChild(self._buildNodeSection());
        pane.appendChild(self._buildRoutingSection());
        pane.appendChild(self._buildDNSSection());
        pane.appendChild(self._buildGlobalSection());
        return pane;
    },

    _buildSubscriptionSection: function() {
        var self = this;
        var subs = (self._config || {}).subscription || {};
        var section = E('div', { 'class': 'cbi-section', 'id': 'section-subscription' });
        section.appendChild(E('h3', {}, _('Subscriptions')));
        var table = E('table', { 'class': 'table cbi-section-table', 'id': 'sub-table' }, [
            E('tr', { 'class': 'cbi-section-table-titles' }, [
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:20%' }, _('Name')),
                E('th', { 'class': 'cbi-section-table-cell' }, _('Subscription URL')),
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:80px' }, _('Action'))
            ])
        ]);
        Object.keys(subs).forEach(function(name) {
            table.appendChild(self._makeSubRow(name, subs[name]));
        });
        section.appendChild(table);
        section.appendChild(E('button', {
            'class': 'btn cbi-button cbi-button-add',
            'click': function() {
                document.getElementById('sub-table').appendChild(self._makeSubRow('', ''));
            }
        }, '+ ' + _('Add Subscription')));
        return section;
    },

    _makeSubRow: function(name, url) {
        var self = this;
        var row = E('tr', { 'class': 'cbi-section-table-row sub-row' }, [
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('input', {
                    'type': 'text', 'class': 'cbi-input-text sub-name',
                    'value': name, 'placeholder': _('e.g. my_sub'),
                    'pattern': '[\\w]+', 'title': _('Letters, digits, underscore only')
                })
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('input', {
                    'type': 'text', 'class': 'cbi-input-text sub-url',
                    'value': url, 'placeholder': 'https://...',
                    'style': 'width:100%'
                })
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('button', {
                    'class': 'btn cbi-button cbi-button-remove',
                    'click': function() { row.parentNode.removeChild(row); }
                }, _('Delete'))
            ])
        ]);
        return row;
    },

    _buildNodeSection: function() {
        var self = this;
        var nodes = (self._config || {}).node || {};
        var section = E('div', { 'class': 'cbi-section', 'id': 'section-node' });
        var titleDiv = E('div', {
            'style': 'cursor:pointer;user-select:none',
            'click': function() {
                var body = document.getElementById('node-section-body');
                body.style.display = body.style.display === 'none' ? '' : 'none';
            }
        }, [E('h3', {}, '▶ ' + _('Nodes (Manual)'))]);
        section.appendChild(titleDiv);
        var body = E('div', { 'id': 'node-section-body', 'style': 'display:none' });
        var table = E('table', { 'class': 'table cbi-section-table', 'id': 'node-table' }, [
            E('tr', { 'class': 'cbi-section-table-titles' }, [
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:20%' }, _('Name')),
                E('th', { 'class': 'cbi-section-table-cell' }, _('Node URI')),
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:80px' }, _('Action'))
            ])
        ]);
        Object.keys(nodes).forEach(function(name) {
            table.appendChild(self._makeNodeRow(name, nodes[name]));
        });
        body.appendChild(table);
        body.appendChild(E('button', {
            'class': 'btn cbi-button cbi-button-add',
            'click': function() {
                document.getElementById('node-table').appendChild(self._makeNodeRow('', ''));
            }
        }, '+ ' + _('Add Node')));
        section.appendChild(body);
        return section;
    },

    _makeNodeRow: function(name, uri) {
        var row = E('tr', { 'class': 'cbi-section-table-row node-row' }, [
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('input', { 'type': 'text', 'class': 'cbi-input-text node-name', 'value': name, 'placeholder': 'node1' })
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('input', { 'type': 'text', 'class': 'cbi-input-text node-uri', 'value': uri, 'placeholder': 'ss://...' })
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('button', { 'class': 'btn cbi-button cbi-button-remove',
                    'click': function() { row.parentNode.removeChild(row); } }, _('Delete'))
            ])
        ]);
        return row;
    },
```

- [ ] **Step 2: Commit**

```bash
cd /tmp/openwrt-dae-work
git add package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(luci-app-dae): add subscription and node form sections

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 6: Add routing rules form section

**Files:**
- Modify: `package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Replace `_buildRoutingSection`, `_makeRoutingRow`, `_makeActionSelect` stubs**

```javascript
    _buildRoutingSection: function() {
        var self = this;
        var routing = ((self._config || {}).routing) || { rules: [], fallback: 'direct' };
        var section = E('div', { 'class': 'cbi-section', 'id': 'section-routing' });
        section.appendChild(E('h3', {}, _('Routing Rules')));
        var table = E('table', { 'class': 'table cbi-section-table', 'id': 'routing-table' }, [
            E('tr', { 'class': 'cbi-section-table-titles' }, [
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:15%' }, _('Condition Type')),
                E('th', { 'class': 'cbi-section-table-cell' },                       _('Condition Value')),
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:18%' }, _('Action')),
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:120px' }, _('Operation'))
            ])
        ]);
        (routing.rules || []).forEach(function(rule) {
            table.appendChild(self._makeRoutingRow(rule.condType, rule.condValue, rule.action));
        });
        // Fallback row (always last, not removable or sortable)
        var fallbackRow = E('tr', { 'class': 'cbi-section-table-row', 'id': 'routing-fallback-row' }, [
            E('td', { 'class': 'cbi-section-table-cell' }, E('strong', {}, _('Fallback'))),
            E('td', { 'class': 'cbi-section-table-cell' }, '—'),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                self._makeActionSelect('routing-fallback-action', routing.fallback || 'direct')
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, '—')
        ]);
        table.appendChild(fallbackRow);
        section.appendChild(table);
        section.appendChild(E('button', {
            'class': 'btn cbi-button cbi-button-add',
            'click': function() {
                var fb = document.getElementById('routing-fallback-row');
                document.getElementById('routing-table').insertBefore(
                    self._makeRoutingRow('domain', '', 'direct'), fb);
            }
        }, '+ ' + _('Add Rule')));
        return section;
    },

    _makeRoutingRow: function(condType, condValue, action) {
        var self = this;
        var condTypes = ['domain', 'dip', 'sip', 'pname', 'l4proto', 'port'];
        var typeSelect = E('select', { 'class': 'cbi-input-select rule-cond-type' });
        condTypes.forEach(function(t) {
            typeSelect.appendChild(E('option', { 'value': t, 'selected': t === condType ? '' : null }, t));
        });
        var row = E('tr', { 'class': 'cbi-section-table-row routing-row' }, [
            E('td', { 'class': 'cbi-section-table-cell' }, [typeSelect]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('input', {
                    'type': 'text', 'class': 'cbi-input-text rule-cond-value',
                    'value': condValue, 'placeholder': 'geosite:cn'
                })
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                self._makeActionSelect('', action)
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('button', {
                    'class': 'btn cbi-button', 'title': _('Move Up'),
                    'click': function() {
                        var prev = row.previousElementSibling;
                        if (prev && prev.classList.contains('routing-row'))
                            row.parentNode.insertBefore(row, prev);
                    }
                }, '↑'),
                ' ',
                E('button', {
                    'class': 'btn cbi-button', 'title': _('Move Down'),
                    'click': function() {
                        var next = row.nextElementSibling;
                        if (next && next.classList.contains('routing-row'))
                            row.parentNode.insertBefore(next, row);
                    }
                }, '↓'),
                ' ',
                E('button', {
                    'class': 'btn cbi-button cbi-button-remove',
                    'click': function() { row.parentNode.removeChild(row); }
                }, _('Delete'))
            ])
        ]);
        return row;
    },

    _makeActionSelect: function(id, selectedAction) {
        var self = this;
        var config = self._config || {};
        var options = ['direct', 'block'];
        Object.keys(config.subscription || {}).forEach(function(n) {
            if (options.indexOf(n) === -1) options.push(n);
        });
        Object.keys(config.node || {}).forEach(function(n) {
            if (options.indexOf(n) === -1) options.push(n);
        });
        if (selectedAction && options.indexOf(selectedAction) === -1)
            options.push(selectedAction);
        var attrs = { 'class': 'cbi-input-select rule-action' };
        if (id) attrs['id'] = id;
        var sel = E('select', attrs);
        options.forEach(function(o) {
            sel.appendChild(E('option', { 'value': o, 'selected': o === selectedAction ? '' : null }, o));
        });
        return sel;
    },
```

- [ ] **Step 2: Commit**

```bash
cd /tmp/openwrt-dae-work
git add package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(luci-app-dae): add routing rules form section

- Condition type dropdown (domain/dip/sip/pname/l4proto/port)
- Action dropdown populated from subscription + node names
- Up/down sort buttons; fallback row pinned at bottom

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 7: Add DNS + global sections, `_getFormData`, `_refreshForm`

**Files:**
- Modify: `package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Replace DNS section stubs (`_buildDNSSection`, `_makeDNSUpstreamRow`, `_makeDNSSelect`)**

```javascript
    _buildDNSSection: function() {
        var self = this;
        var dns = ((self._config || {}).dns) || { upstream: {}, domestic: '', foreign: '', rawRouting: '' };
        var upstream = dns.upstream || {};
        var upstreamNames = Object.keys(upstream);
        var section = E('div', { 'class': 'cbi-section', 'id': 'section-dns' });
        section.appendChild(E('h3', {}, _('DNS')));
        section.appendChild(E('h4', {}, _('Upstream Servers')));
        var table = E('table', { 'class': 'table cbi-section-table', 'id': 'dns-upstream-table' }, [
            E('tr', { 'class': 'cbi-section-table-titles' }, [
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:20%' }, _('Name')),
                E('th', { 'class': 'cbi-section-table-cell' }, _('URL')),
                E('th', { 'class': 'cbi-section-table-cell', 'style': 'width:80px' }, _('Action'))
            ])
        ]);
        upstreamNames.forEach(function(name) {
            table.appendChild(self._makeDNSUpstreamRow(name, upstream[name]));
        });
        section.appendChild(table);
        section.appendChild(E('button', {
            'class': 'btn cbi-button cbi-button-add',
            'click': function() {
                document.getElementById('dns-upstream-table').appendChild(
                    self._makeDNSUpstreamRow('', ''));
            }
        }, '+ ' + _('Add Upstream')));

        // DNS routing — simplified selectors or notice for custom routing
        if (!dns.rawRouting) {
            section.appendChild(E('h4', {}, _('DNS Routing')));
            section.appendChild(E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('Domestic DNS')),
                E('div', { 'class': 'cbi-value-field' }, [
                    self._makeDNSSelect('dns-domestic', dns.domestic, upstreamNames)
                ])
            ]));
            section.appendChild(E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title' }, _('Foreign DNS')),
                E('div', { 'class': 'cbi-value-field' }, [
                    self._makeDNSSelect('dns-foreign', dns.foreign, upstreamNames)
                ])
            ]));
        } else {
            section.appendChild(E('p', { 'class': 'alert-message notice' },
                _('Custom DNS routing detected. Edit in text mode.')));
        }
        return section;
    },

    _makeDNSUpstreamRow: function(name, url) {
        var row = E('tr', { 'class': 'cbi-section-table-row dns-upstream-row' }, [
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('input', { 'type': 'text', 'class': 'cbi-input-text dns-upstream-name',
                    'value': name, 'placeholder': 'alidns' })
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('input', { 'type': 'text', 'class': 'cbi-input-text dns-upstream-url',
                    'value': url, 'placeholder': 'udp://223.5.5.5:53', 'style': 'width:100%' })
            ]),
            E('td', { 'class': 'cbi-section-table-cell' }, [
                E('button', { 'class': 'btn cbi-button cbi-button-remove',
                    'click': function() { row.parentNode.removeChild(row); } }, _('Delete'))
            ])
        ]);
        return row;
    },

    _makeDNSSelect: function(id, selected, options) {
        var sel = E('select', { 'id': id, 'class': 'cbi-input-select' });
        sel.appendChild(E('option', { 'value': '' }, _('-- select --')));
        options.forEach(function(o) {
            sel.appendChild(E('option', { 'value': o, 'selected': o === selected ? '' : null }, o));
        });
        return sel;
    },
```

- [ ] **Step 2: Replace global section stub (`_buildGlobalSection`)**

```javascript
    _buildGlobalSection: function() {
        var self = this;
        var global_ = (self._config || {}).global || {};
        var section = E('div', { 'class': 'cbi-section', 'id': 'section-global' });
        section.appendChild(E('div', {
            'style': 'cursor:pointer;user-select:none',
            'click': function() {
                var body = document.getElementById('global-section-body');
                body.style.display = body.style.display === 'none' ? '' : 'none';
            }
        }, [E('h3', {}, '▶ ' + _('Global Settings'))]));
        var body = E('div', { 'id': 'global-section-body', 'style': 'display:none' });
        var fields = [
            { key: 'log-level',                    label: _('Log Level'),                    type: 'select',   opts: ['error','warn','info','debug','trace'], def: 'info' },
            { key: 'lan-interface',                label: _('LAN Interface'),                type: 'text',     def: 'br-lan' },
            { key: 'wan-interface',                label: _('WAN Interface'),                type: 'text',     def: 'eth1'   },
            { key: 'allow-insecure',               label: _('Allow Insecure'),               type: 'checkbox', def: 'false'  },
            { key: 'auto-config-kernel-parameter', label: _('Auto Config Kernel Parameter'), type: 'checkbox', def: 'true'   }
        ];
        fields.forEach(function(f) {
            var val = global_[f.key] !== undefined ? global_[f.key] : f.def;
            var input;
            if (f.type === 'select') {
                input = E('select', { 'id': 'global-' + f.key, 'class': 'cbi-input-select' });
                f.opts.forEach(function(o) {
                    input.appendChild(E('option', { 'value': o, 'selected': o === val ? '' : null }, o));
                });
            } else if (f.type === 'checkbox') {
                input = E('input', { 'type': 'checkbox', 'id': 'global-' + f.key,
                    'checked': val === 'true' ? '' : null });
            } else {
                input = E('input', { 'type': 'text', 'id': 'global-' + f.key,
                    'class': 'cbi-input-text', 'value': val });
            }
            body.appendChild(E('div', { 'class': 'cbi-value' }, [
                E('label', { 'class': 'cbi-value-title', 'for': 'global-' + f.key }, f.label),
                E('div', { 'class': 'cbi-value-field' }, [input])
            ]));
        });
        section.appendChild(body);
        return section;
    },
```

- [ ] **Step 3: Replace `_getFormData` stub**

```javascript
    _getFormData: function() {
        var self = this;
        var config = {
            global: {}, subscription: {}, node: {},
            routing: { rules: [], fallback: 'direct' },
            dns: {
                upstream: {}, domestic: '', foreign: '',
                rawRouting: self._config ? (self._config.dns || {}).rawRouting || '' : ''
            },
            rawOther: self._config ? self._config.rawOther || '' : ''
        };

        // Global
        ['log-level','lan-interface','wan-interface','allow-insecure','auto-config-kernel-parameter']
            .forEach(function(key) {
                var el = document.getElementById('global-' + key);
                if (!el) return;
                if (el.type === 'checkbox') config.global[key] = el.checked ? 'true' : 'false';
                else if (el.value)          config.global[key] = el.value;
            });

        // Subscriptions
        document.querySelectorAll('#sub-table .sub-row').forEach(function(row) {
            var n = row.querySelector('.sub-name').value.trim();
            var u = row.querySelector('.sub-url').value.trim();
            if (n && u) config.subscription[n] = u;
        });

        // Nodes
        document.querySelectorAll('#node-table .node-row').forEach(function(row) {
            var n = row.querySelector('.node-name').value.trim();
            var u = row.querySelector('.node-uri').value.trim();
            if (n && u) config.node[n] = u;
        });

        // Routing rules
        document.querySelectorAll('#routing-table .routing-row').forEach(function(row) {
            var ct = row.querySelector('.rule-cond-type').value;
            var cv = row.querySelector('.rule-cond-value').value.trim();
            var ac = row.querySelector('.rule-action').value;
            if (cv) config.routing.rules.push({ condType: ct, condValue: cv, action: ac });
        });
        var fbEl = document.getElementById('routing-fallback-action');
        if (fbEl) config.routing.fallback = fbEl.value;

        // DNS upstream
        document.querySelectorAll('#dns-upstream-table .dns-upstream-row').forEach(function(row) {
            var n = row.querySelector('.dns-upstream-name').value.trim();
            var u = row.querySelector('.dns-upstream-url').value.trim();
            if (n && u) config.dns.upstream[n] = u;
        });
        if (!config.dns.rawRouting) {
            var domEl = document.getElementById('dns-domestic');
            var forEl = document.getElementById('dns-foreign');
            if (domEl) config.dns.domestic = domEl.value;
            if (forEl) config.dns.foreign  = forEl.value;
        }

        return config;
    },
```

- [ ] **Step 4: Replace `_refreshForm` stub**

```javascript
    _refreshForm: function() {
        var self = this;
        var config = self._config || {};

        // Subscriptions
        var subTable = document.getElementById('sub-table');
        subTable.querySelectorAll('.sub-row').forEach(function(r) { r.parentNode.removeChild(r); });
        Object.keys(config.subscription || {}).forEach(function(n) {
            subTable.appendChild(self._makeSubRow(n, config.subscription[n]));
        });

        // Nodes
        var nodeTable = document.getElementById('node-table');
        nodeTable.querySelectorAll('.node-row').forEach(function(r) { r.parentNode.removeChild(r); });
        Object.keys(config.node || {}).forEach(function(n) {
            nodeTable.appendChild(self._makeNodeRow(n, config.node[n]));
        });

        // Routing rules
        var routingTable = document.getElementById('routing-table');
        routingTable.querySelectorAll('.routing-row').forEach(function(r) { r.parentNode.removeChild(r); });
        var fbRow = document.getElementById('routing-fallback-row');
        ((config.routing || {}).rules || []).forEach(function(rule) {
            routingTable.insertBefore(
                self._makeRoutingRow(rule.condType, rule.condValue, rule.action), fbRow);
        });
        var fbEl = document.getElementById('routing-fallback-action');
        if (fbEl && config.routing) fbEl.value = config.routing.fallback || 'direct';

        // DNS upstream
        var dnsTable = document.getElementById('dns-upstream-table');
        dnsTable.querySelectorAll('.dns-upstream-row').forEach(function(r) { r.parentNode.removeChild(r); });
        Object.keys((config.dns || {}).upstream || {}).forEach(function(n) {
            dnsTable.appendChild(self._makeDNSUpstreamRow(n, config.dns.upstream[n]));
        });
        var domEl = document.getElementById('dns-domestic');
        var forEl = document.getElementById('dns-foreign');
        if (domEl && config.dns) domEl.value = config.dns.domestic || '';
        if (forEl && config.dns) forEl.value = config.dns.foreign  || '';

        // Global
        ['log-level','lan-interface','wan-interface','allow-insecure','auto-config-kernel-parameter']
            .forEach(function(key) {
                var el = document.getElementById('global-' + key);
                if (!el) return;
                var val = ((config.global || {})[key]) || '';
                if      (el.type === 'checkbox') el.checked = val === 'true';
                else if (el.tagName === 'SELECT') el.value  = val;
                else                             el.value   = val;
            });
    },
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/openwrt-dae-work
git add package/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(luci-app-dae): complete form sections — DNS, global, getFormData, refreshForm

- DNS section: upstream table + domestic/foreign selectors
- Global section: collapsed, log-level/interfaces/switches
- _getFormData() reads all form fields → DaeConfig
- _refreshForm() rebuilds form from parsed config (used on Text→Form switch)

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 8: Update i18n files

**Files:**
- Modify: `package/luci-app-dae/po/zh_Hans/dae.po`
- Modify: `package/luci-app-dae/po/templates/dae.pot`

- [ ] **Step 1: Append new entries to `po/templates/dae.pot`**

Append the following block to the end of `po/templates/dae.pot`:

```po
#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Form"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Text"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Subscriptions"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Subscription URL"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Subscription"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Nodes (Manual)"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Node URI"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Node"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Routing Rules"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Condition Type"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Condition Value"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Operation"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Fallback"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Move Up"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Move Down"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Rule"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "DNS"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Upstream Servers"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Upstream"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "DNS Routing"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Domestic DNS"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Foreign DNS"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Custom DNS routing detected. Edit in text mode."
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Global Settings"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Log Level"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "LAN Interface"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "WAN Interface"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Allow Insecure"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Auto Config Kernel Parameter"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "-- select --"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Configuration saved and dae reloaded."
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Failed to load configuration."
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Config text has errors. Please fix before switching to form mode."
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Failed to serialize form: "
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "e.g. my_sub"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Letters, digits, underscore only"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Name"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Action"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "URL"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Delete"
msgstr ""
```

- [ ] **Step 2: Append Chinese translations to `po/zh_Hans/dae.po`**

Append the following block to the end of `po/zh_Hans/dae.po`:

```po
#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Form"
msgstr "表单模式"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Text"
msgstr "文本模式"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Subscriptions"
msgstr "订阅"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Subscription URL"
msgstr "订阅 URL"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Subscription"
msgstr "添加订阅"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Nodes (Manual)"
msgstr "节点（手动）"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Node URI"
msgstr "节点 URI"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Node"
msgstr "添加节点"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Routing Rules"
msgstr "路由规则"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Condition Type"
msgstr "条件类型"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Condition Value"
msgstr "条件值"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Operation"
msgstr "操作"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Fallback"
msgstr "兜底动作"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Move Up"
msgstr "上移"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Move Down"
msgstr "下移"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Rule"
msgstr "添加规则"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "DNS"
msgstr "DNS"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Upstream Servers"
msgstr "上游服务器"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Upstream"
msgstr "添加上游"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "DNS Routing"
msgstr "DNS 路由"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Domestic DNS"
msgstr "国内 DNS"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Foreign DNS"
msgstr "国外 DNS"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Custom DNS routing detected. Edit in text mode."
msgstr "检测到自定义 DNS 路由规则，请在文本模式下编辑。"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Global Settings"
msgstr "全局设置"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Log Level"
msgstr "日志级别"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "LAN Interface"
msgstr "LAN 接口"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "WAN Interface"
msgstr "WAN 接口"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Allow Insecure"
msgstr "允许不安全连接"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Auto Config Kernel Parameter"
msgstr "自动配置内核参数"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "-- select --"
msgstr "-- 请选择 --"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Configuration saved and dae reloaded."
msgstr "配置已保存，dae 已热重载。"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Failed to load configuration."
msgstr "加载配置失败。"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Config text has errors. Please fix before switching to form mode."
msgstr "配置文本有错误，请修正后再切换到表单模式。"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Failed to serialize form: "
msgstr "表单序列化失败："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "e.g. my_sub"
msgstr "例如 my_sub"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Letters, digits, underscore only"
msgstr "只允许字母、数字、下划线"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Name"
msgstr "名称"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Action"
msgstr "操作"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "URL"
msgstr "URL"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Delete"
msgstr "删除"
```

- [ ] **Step 3: Commit**

```bash
cd /tmp/openwrt-dae-work
git add package/luci-app-dae/po/templates/dae.pot \
        package/luci-app-dae/po/zh_Hans/dae.po
git commit -m "feat(luci-app-dae): add i18n strings for config UI form sections

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Final push

- [ ] **Pull and push**

```bash
cd /tmp/openwrt-dae-work
git pull --rebase origin main
git push origin main
```

---

## Known Limitations (out of scope for this plan)

- Action dropdowns in routing rules are populated from `_config` at load time; new subscriptions added in the same session won't automatically appear until page reload.
- DNS domestic/foreign dropdowns are populated from upstream servers at load time; same limitation.
- No per-field validation beyond HTML `pattern` attribute on name inputs.
- `_refreshForm()` rebuilds all rows on Text→Form switch (acceptable for typical config sizes).
