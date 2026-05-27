# dae Config UI v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `luci-app-dae` to correctly model dae's group concept, restore an "All Nodes" tab unifying subscription nodes with manual node CRUD, and replace cbi-tabmenu with button-styled tabs.

**Architecture:** Three-tab LuCI view (`Form` / `All Nodes` / `Text`). Form tab gains a new "代理组" (group) section that maps to dae's `group {}` block (the missing layer between subscriptions and routing). All-Nodes tab reads/writes `/tmp/dae-nodes-cache.json` populated by a backend shell script (`list-nodes.sh`). Parser is extended (additive) with `_parseGroup` and `_serializeGroup`; `DaeConfig` gains a `groups: GroupDef[]` field.

**Tech Stack:** LuCI JS framework (ES5, `view.extend`, `baseclass.extend`), vanilla DOM via `E()`, shell + `base64` + `awk` for subscription URI parsing, Node.js built-in `assert` for parser tests.

**Repositories involved:**
- Work happens in **`/tmp/luci-app-dae-split`** (the standalone `ysuolmai/luci-app-dae` repo)
- The OpenWRT-CI repo (`/tmp/openwrt-dae-work`) is NOT modified by this plan

**Node binary for tests:** `/Users/yufan/.cache/tailscale-node/bin/node`

**Router for verification:** `172.28.1.224` (password-less SSH via `~/.ssh/claude_agent_ed25519`)

---

## File Map

| File | Status | Responsibility |
|------|--------|----------------|
| `luci-app-dae/Makefile` | Modify | Bump `PKG_VERSION` to date-based so opkg accepts upgrade over upstream feed `26.146.x` |
| `luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js` | Modify (additive) | Add `_parseGroup`, group serialize, default-group helper. Keep existing methods. |
| `luci-app-dae/htdocs/luci-static/resources/view/dae/config.js` | Major rewrite | 3-tab UI, group section, all-nodes tab, removed manual-node form section |
| `luci-app-dae/root/usr/lib/luci-app-dae/list-nodes.sh` | Create | Backend script: wget URL → base64 → parse URIs → JSON cache |
| `luci-app-dae/root/usr/share/rpcd/acl.d/luci-app-dae.json` | Modify | Add `exec` permission for `list-nodes.sh` |
| `luci-app-dae/Makefile` | Modify | Install `list-nodes.sh` (already covered by `root/` tree) |
| `luci-app-dae/po/templates/dae.pot` | Modify | New i18n keys |
| `luci-app-dae/po/zh_Hans/dae.po` | Modify | Chinese translations |
| `luci-app-dae/tests/parser.test.js` | Modify (additive) | Group parse/serialize round-trip tests |
| `luci-app-dae/tests/list-nodes.test.sh` | Create | Shell tests for the backend script |

---

## DaeConfig v2 Shape (recap from spec)

Every later task assumes this exact shape. Defined here once; referenced by all parser/UI tasks.

```javascript
// DaeConfig
{
  global:       { [key]: value },       // unchanged from v1
  subscription: { [name]: url },        // unchanged
  node:         { [name]: uri },        // unchanged (data still in config.dae's node {})
  groups: [                             // ← NEW in v2
    {
      name: 'proxy',
      filter: {
        subscriptions:   ['my_sub'],    // selected sub names
        nodes:           [],            // selected manual node names
        excludeKeywords: ['ExpireAt'],  // exclude if node name contains any of these
        namePin:         null           // null|string. when set: filter narrowed to single node
      },
      policy: 'min_moving_avg'          // 'min_moving_avg' | 'random'
    }
  ],
  routing: { rules: [{condType, condValue, action}], fallback: 'proxy' },
  dns: { upstream: {}, domestic: '', foreign: '', rawRouting: '' },
  rawOther: ''                          // includes any group block we can't parse
}
```

When `groups` is empty after `parse()`, callers should `ensureDefaultGroup(config)` which adds a `proxy` group with all known subscription names checked and `excludeKeywords: ['ExpireAt']`.

---

## Task 1: Bump PKG_VERSION to date-based

**Why:** opkg refuses to "downgrade" 1.2 over upstream feed's `26.146.x`. Date-based versions like `2026.05.27` always exceed it numerically (2026 > 26 by Debian version compare).

**Files:**
- Modify: `luci-app-dae/Makefile`

- [ ] **Step 1: Read current Makefile**

```bash
cd /tmp/luci-app-dae-split
cat luci-app-dae/Makefile
```

Note current `PKG_VERSION:=1.2` and `PKG_RELEASE:=1`.

- [ ] **Step 2: Change PKG_VERSION to date-based, reset PKG_RELEASE**

Edit `luci-app-dae/Makefile`:

```diff
-PKG_VERSION:=1.2
-PKG_RELEASE:=1
+# Use date-based version so opkg always accepts upgrade over upstream feed
+# (which uses date-based versioning starting with e.g. 26.146.x).
+# Bump this string when releasing.
+PKG_VERSION:=2026.05.27
+PKG_RELEASE:=1
```

- [ ] **Step 3: Verify Makefile still parses (basic sanity)**

```bash
grep -E '^(PKG_NAME|PKG_VERSION|PKG_RELEASE|LUCI_DEPENDS|LUCI_PKGARCH):' /tmp/luci-app-dae-split/luci-app-dae/Makefile
```

Expected output:
```
PKG_NAME:=luci-app-dae
PKG_VERSION:=2026.05.27
PKG_RELEASE:=1
LUCI_DEPENDS:=+dae
LUCI_PKGARCH:=all
```

- [ ] **Step 4: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/Makefile
git commit -m "chore(luci-app-dae): bump PKG_VERSION to 2026.05.27

Date-based versioning so opkg accepts upgrades over the upstream
ImmortalWrt feed (which uses 26.146.x and refuses downgrade to 1.2).

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 2: Parser — DaeConfig.groups field + ensureDefaultGroup helper

**Goal:** Update `parse()` to always return a `groups` array (empty by default). Add `ensureDefaultGroup(config, fallbackName)` helper. No actual group block parsing yet (Task 3).

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js`
- Modify: `luci-app-dae/tests/parser.test.js`

- [ ] **Step 1: Add failing tests**

Append to `tests/parser.test.js` before the final summary lines:

```javascript
// ---- groups in DaeConfig ----
console.log('\ngroups field:');

test('parse() returns empty groups array when no group block', function() {
    var c = DaeParser.parse("subscription {\n  my_sub: 'https://x'\n}\nrouting {\n  fallback: direct\n}");
    assert.ok(Array.isArray(c.groups), 'groups should be an array');
    assert.strictEqual(c.groups.length, 0);
});

test('parse() returns empty groups array for empty input', function() {
    var c = DaeParser.parse('');
    assert.deepStrictEqual(c.groups, []);
});

// ---- ensureDefaultGroup ----
console.log('\nensureDefaultGroup:');

test('adds a default group when groups is empty', function() {
    var c = DaeParser.parse("subscription {\n  my_sub: 'https://x'\n}\nrouting {\n  fallback: proxy\n}");
    DaeParser.ensureDefaultGroup(c);
    assert.strictEqual(c.groups.length, 1);
    assert.strictEqual(c.groups[0].name, 'proxy');
    assert.deepStrictEqual(c.groups[0].filter.subscriptions, ['my_sub']);
    assert.deepStrictEqual(c.groups[0].filter.excludeKeywords, ['ExpireAt']);
    assert.strictEqual(c.groups[0].policy, 'min_moving_avg');
});

test('does nothing when groups already populated', function() {
    var c = {
        global: {}, subscription: {}, node: {}, groups: [{name: 'mygroup', filter: {subscriptions:[], nodes:[], excludeKeywords:[], namePin:null}, policy: 'random'}],
        routing: {rules:[], fallback:'direct'},
        dns: {upstream:{}, domestic:'', foreign:'', rawRouting:''},
        rawOther: ''
    };
    DaeParser.ensureDefaultGroup(c);
    assert.strictEqual(c.groups.length, 1);
    assert.strictEqual(c.groups[0].name, 'mygroup');
});
```

- [ ] **Step 2: Run tests, expect failure**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
/Users/yufan/.cache/tailscale-node/bin/node tests/parser.test.js 2>&1 | tail -10
```

Expected: 4 new failures (`c.groups` undefined, `ensureDefaultGroup` not a function).

- [ ] **Step 3: Update parse() and add ensureDefaultGroup in dae-parser.js**

Find the `parse:` method, add `groups: []` to the initial `config` object:

```javascript
parse: function(text) {
    var self = this;
    var blocks = self._extractBlocks(text);
    var config = {
        global: {}, subscription: {}, node: {},
        groups: [],                                                  // ← ADD THIS LINE
        routing: { rules: [], fallback: 'direct' },
        dns: { upstream: {}, domestic: '', foreign: '', rawRouting: '' },
        rawOther: ''
    };
    // ... (rest unchanged)
}
```

Then add a new method (place it after `_parseDNS` and before `parse`):

```javascript
    /**
     * If config.groups is empty, add a default group named `name`
     * (default 'proxy'), with all current subscription names selected and
     * 'ExpireAt' as the exclude keyword. Policy defaults to min_moving_avg.
     * Mutates config in place.
     */
    ensureDefaultGroup: function(config, name) {
        if (!config || !Array.isArray(config.groups)) return;
        if (config.groups.length > 0) return;
        name = name || 'proxy';
        config.groups.push({
            name: name,
            filter: {
                subscriptions: Object.keys(config.subscription || {}),
                nodes: [],
                excludeKeywords: ['ExpireAt'],
                namePin: null
            },
            policy: 'min_moving_avg'
        });
    },
```

- [ ] **Step 4: Run tests, expect pass**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
/Users/yufan/.cache/tailscale-node/bin/node tests/parser.test.js 2>&1 | tail -5
```

Expected: all tests pass (previous count + 4 new = previous+4).

- [ ] **Step 5: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js \
        luci-app-dae/tests/parser.test.js
git commit -m "feat(parser): add DaeConfig.groups field and ensureDefaultGroup helper

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 3: Parser — `_parseGroup` and the filter sub-syntax

**Goal:** Parse the dae `group { ... }` block into structured `GroupDef[]`. Recognize a constrained filter sub-syntax:

- `subtag(sub1, sub2)` → `filter.subscriptions = ['sub1', 'sub2']`
- `name(node1, node2)` → `filter.nodes = ['node1', 'node2']`
- `name(keyword: 'ExpireAt')` → push `'ExpireAt'` into `filter.excludeKeywords` (note: combined with leading `!` — see below)
- `!name(keyword: 'ExpireAt')` → `filter.excludeKeywords.push('ExpireAt')`
- Filter lines joined by `&&` produce conjunction
- Multiple `filter:` lines = OR semantics (we'll preserve them in raw form but the UI maps the first only — see "rawGroups" below)
- `policy: <name>` → `policy` ('min_moving_avg' / 'random' / others fall back to 'min_moving_avg' for UI; raw value preserved in `policyRaw`)

Anything that doesn't match (e.g. multiple filter lines, `name(regex: ...)`, `tcp_check_url` overrides) → entire group goes to `rawGroups: [{name, content}]` and won't appear in `groups`; UI shows a "custom group (text mode)" placeholder card.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js`
- Modify: `luci-app-dae/tests/parser.test.js`

- [ ] **Step 1: Append failing tests to `tests/parser.test.js`**

```javascript
// ---- _parseGroup ----
console.log('\n_parseGroup:');

test('parses a simple group with subtag + name keyword exclude', function() {
    var content = "    proxy {\n" +
                  "        filter: subtag(my_sub) && !name(keyword: 'ExpireAt')\n" +
                  "        policy: min_moving_avg\n" +
                  "    }";
    var groups = DaeParser._parseGroup(content);
    assert.strictEqual(groups.parsed.length, 1);
    var g = groups.parsed[0];
    assert.strictEqual(g.name, 'proxy');
    assert.deepStrictEqual(g.filter.subscriptions, ['my_sub']);
    assert.deepStrictEqual(g.filter.excludeKeywords, ['ExpireAt']);
    assert.strictEqual(g.filter.namePin, null);
    assert.strictEqual(g.policy, 'min_moving_avg');
});

test('parses multiple subscriptions in subtag()', function() {
    var content = "    g1 {\n" +
                  "        filter: subtag(sub_a, sub_b)\n" +
                  "        policy: random\n" +
                  "    }";
    var groups = DaeParser._parseGroup(content);
    assert.deepStrictEqual(groups.parsed[0].filter.subscriptions, ['sub_a', 'sub_b']);
    assert.strictEqual(groups.parsed[0].policy, 'random');
});

test('parses name(nodes) into filter.nodes', function() {
    var content = "    g {\n" +
                  "        filter: name(node1, node2)\n" +
                  "        policy: min_moving_avg\n" +
                  "    }";
    var groups = DaeParser._parseGroup(content);
    assert.deepStrictEqual(groups.parsed[0].filter.nodes, ['node1', 'node2']);
});

test('detects namePin when filter is single name() + policy min', function() {
    var content = "    pinned {\n" +
                  "        filter: name(HK_01)\n" +
                  "        policy: min_moving_avg\n" +
                  "    }";
    var groups = DaeParser._parseGroup(content);
    // We treat single-node-filter as namePin
    assert.strictEqual(groups.parsed[0].filter.namePin, 'HK_01');
});

test('parses multiple groups in one block', function() {
    var content = "    a {\n" +
                  "        filter: subtag(s1)\n" +
                  "        policy: min_moving_avg\n" +
                  "    }\n" +
                  "    b {\n" +
                  "        filter: subtag(s2)\n" +
                  "        policy: random\n" +
                  "    }";
    var groups = DaeParser._parseGroup(content);
    assert.strictEqual(groups.parsed.length, 2);
    assert.strictEqual(groups.parsed[0].name, 'a');
    assert.strictEqual(groups.parsed[1].name, 'b');
});

test('unparseable group goes to rawGroups', function() {
    var content = "    weird {\n" +
                  "        filter: name(regex: '^HK.*$')\n" +
                  "        policy: min_moving_avg\n" +
                  "        tcp_check_url: 'http://example.com'\n" +
                  "    }";
    var groups = DaeParser._parseGroup(content);
    assert.strictEqual(groups.parsed.length, 0);
    assert.strictEqual(groups.rawGroups.length, 1);
    assert.strictEqual(groups.rawGroups[0].name, 'weird');
});

test('parse() wires _parseGroup into config.groups', function() {
    var text = "group {\n" +
               "    proxy {\n" +
               "        filter: subtag(my_sub) && !name(keyword: 'ExpireAt')\n" +
               "        policy: min_moving_avg\n" +
               "    }\n" +
               "}\n" +
               "subscription {\n" +
               "    my_sub: 'https://x'\n" +
               "}";
    var c = DaeParser.parse(text);
    assert.strictEqual(c.groups.length, 1);
    assert.strictEqual(c.groups[0].name, 'proxy');
});
```

- [ ] **Step 2: Run tests, expect 7 failures**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
/Users/yufan/.cache/tailscale-node/bin/node tests/parser.test.js 2>&1 | tail -15
```

- [ ] **Step 3: Implement `_parseGroup` in `dae-parser.js`**

Add this method just after `_parseDNS`:

```javascript
    /**
     * Parse the body of a top-level `group { ... }` block.
     * Returns { parsed: GroupDef[], rawGroups: [{name, content}] }
     * 'parsed' contains groups whose filter we understand; 'rawGroups'
     * contains groups whose filter has syntax outside our supported subset
     * (multiple filter lines, regex, per-group overrides, etc.) — those
     * are preserved in DaeConfig.rawOther so they don't get lost.
     *
     * Supported filter syntax:
     *   subtag(sub1, sub2, ...)
     *   name(node1, node2, ...)
     *   !name(keyword: 'kw')            → push 'kw' to excludeKeywords
     *   Above joined by ' && '
     *
     * If a group has filter: name(SINGLE_NODE) only, we set namePin=SINGLE_NODE
     * to represent the "manually pin to one node" UI choice.
     */
    _parseGroup: function(content) {
        var self = this;
        var result = { parsed: [], rawGroups: [] };
        var subBlocks = self._extractBlocks(content);

        for (var groupName in subBlocks) {
            if (groupName === '__preamble') continue;
            var body = subBlocks[groupName];
            var lines = body.split('\n').map(function(l) { return l.trim(); }).filter(Boolean);

            var filterLines = [];
            var policyLine = null;
            var hasUnknownLine = false;

            for (var i = 0; i < lines.length; i++) {
                var l = lines[i];
                if (l[0] === '#') continue;
                if (l.indexOf('filter:') === 0) {
                    filterLines.push(l.substring('filter:'.length).trim());
                } else if (l.indexOf('policy:') === 0) {
                    if (policyLine !== null) { hasUnknownLine = true; break; }
                    policyLine = l.substring('policy:'.length).trim();
                } else {
                    // any other line (tcp_check_url, etc.) → bail to rawGroups
                    hasUnknownLine = true;
                    break;
                }
            }

            if (hasUnknownLine || filterLines.length > 1) {
                result.rawGroups.push({ name: groupName, content: body });
                continue;
            }

            var filter = { subscriptions: [], nodes: [], excludeKeywords: [], namePin: null };
            var policy = policyLine || 'min_moving_avg';

            if (filterLines.length === 1) {
                var clauses = filterLines[0].split(/\s*&&\s*/);
                var clauseOk = true;
                for (var c = 0; c < clauses.length; c++) {
                    var clause = clauses[c].trim();
                    var m;
                    if ((m = clause.match(/^subtag\(([^)]*)\)$/))) {
                        filter.subscriptions = m[1].split(',').map(function(s){return s.trim();}).filter(Boolean);
                    } else if ((m = clause.match(/^name\(([^)]*)\)$/))) {
                        var args = m[1].trim();
                        // name(keyword: 'X') is exclude when prefixed with !; positive name() = node list
                        var kw = args.match(/^keyword:\s*['"]([^'"]+)['"]$/);
                        if (kw) {
                            // positive keyword filter — we don't model this; bail
                            clauseOk = false; break;
                        }
                        filter.nodes = args.split(',').map(function(s){return s.trim();}).filter(Boolean);
                    } else if ((m = clause.match(/^!name\(([^)]*)\)$/))) {
                        var args2 = m[1].trim();
                        var kw2 = args2.match(/^keyword:\s*['"]([^'"]+)['"]$/);
                        if (kw2) {
                            filter.excludeKeywords.push(kw2[1]);
                        } else {
                            // !name(node1) — we don't model this; bail
                            clauseOk = false; break;
                        }
                    } else {
                        clauseOk = false; break;
                    }
                }
                if (!clauseOk) {
                    result.rawGroups.push({ name: groupName, content: body });
                    continue;
                }
            }

            // single-node detection → namePin
            if (filter.nodes.length === 1 && filter.subscriptions.length === 0 && filter.excludeKeywords.length === 0) {
                filter.namePin = filter.nodes[0];
                filter.nodes = [];
            }

            result.parsed.push({ name: groupName, filter: filter, policy: policy });
        }

        return result;
    },
```

- [ ] **Step 4: Wire `_parseGroup` into `parse()` and route rawGroups to rawOther**

In `parse()`, after the existing block-dispatch chain, before the rawOther assembly, add:

```javascript
        // Groups (v2)
        if (blocks['group']) {
            var groupResult = self._parseGroup(blocks['group']);
            config.groups = groupResult.parsed;
            // unparseable groups → reconstruct group { ... } block in rawOther
            if (groupResult.rawGroups.length > 0) {
                var rawText = 'group {\n';
                groupResult.rawGroups.forEach(function(rg) {
                    rawText += '    ' + rg.name + ' {\n';
                    rg.content.split('\n').forEach(function(l) {
                        rawText += '        ' + l + '\n';
                    });
                    rawText += '    }\n';
                });
                rawText += '}';
                // Append to rawOther later (after the existing 'known' loop)
                blocks['__rawGroupReinject'] = rawText;
            }
        }
```

Update the `known` array and the rawOther loop to also skip `group` and to inject `__rawGroupReinject` if present:

```javascript
        // Preserve unknown blocks verbatim
        var known = ['global', 'subscription', 'node', 'routing', 'dns', 'group', '__preamble', '__rawGroupReinject'];
        var otherParts = blocks['__preamble'] ? [blocks['__preamble']] : [];
        for (var name in blocks) {
            if (known.indexOf(name) === -1)
                otherParts.push(name + ' {\n' + blocks[name] + '\n}');
        }
        if (blocks['__rawGroupReinject']) otherParts.push(blocks['__rawGroupReinject']);
        config.rawOther = otherParts.join('\n\n');
```

- [ ] **Step 5: Run tests, expect pass**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
/Users/yufan/.cache/tailscale-node/bin/node tests/parser.test.js 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js \
        luci-app-dae/tests/parser.test.js
git commit -m "feat(parser): parse dae group {} block with constrained filter syntax

Supported: subtag(...), name(...), !name(keyword:'...') joined by &&.
Unparseable groups (regex filter, per-group tcp_check_url, multiple filter
lines etc.) are preserved verbatim in rawOther so we don't lose user data.

Single-node filter (filter: name(HK_01)) is detected as namePin for the
'manually pin one node' UI policy.

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 4: Parser — `serialize()` outputs group block

**Goal:** When serializing, emit `group { ... }` in the correct order (`global → subscription → node → dns → group → routing → rawOther`) and produce the inverse of `_parseGroup`.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js`
- Modify: `luci-app-dae/tests/parser.test.js`

- [ ] **Step 1: Append serialize tests**

```javascript
// ---- serialize() with groups ----
console.log('\nserialize() with groups:');

test('serializes a basic group with subtag and exclude', function() {
    var config = {
        global: {}, subscription: {'my_sub': 'https://x'}, node: {},
        groups: [{
            name: 'proxy',
            filter: { subscriptions: ['my_sub'], nodes: [], excludeKeywords: ['ExpireAt'], namePin: null },
            policy: 'min_moving_avg'
        }],
        routing: { rules: [], fallback: 'proxy' },
        dns: { upstream: {}, domestic: '', foreign: '', rawRouting: '' },
        rawOther: ''
    };
    var s = DaeParser.serialize(config);
    assert.ok(s.indexOf('group {') >= 0);
    assert.ok(s.indexOf("filter: subtag(my_sub) && !name(keyword: 'ExpireAt')") >= 0);
    assert.ok(s.indexOf('policy: min_moving_avg') >= 0);
});

test('serializes group block before routing block', function() {
    var config = {
        global: {}, subscription: {}, node: {},
        groups: [{ name: 'p', filter: {subscriptions:[], nodes:[], excludeKeywords:[], namePin:null}, policy: 'random' }],
        routing: { rules: [], fallback: 'p' },
        dns: { upstream: {}, domestic: '', foreign: '', rawRouting: '' },
        rawOther: ''
    };
    var s = DaeParser.serialize(config);
    assert.ok(s.indexOf('group {') < s.indexOf('routing {'), 'group must come before routing');
});

test('serializes namePin as filter: name(NODE)', function() {
    var config = {
        global: {}, subscription: {}, node: {},
        groups: [{ name: 'pin', filter: {subscriptions:[], nodes:[], excludeKeywords:[], namePin: 'HK_01'}, policy: 'min_moving_avg' }],
        routing: { rules: [], fallback: 'pin' },
        dns: { upstream: {}, domestic: '', foreign: '', rawRouting: '' },
        rawOther: ''
    };
    var s = DaeParser.serialize(config);
    assert.ok(s.indexOf('filter: name(HK_01)') >= 0);
});

test('omits group block when groups array is empty', function() {
    var config = {
        global: {}, subscription: {}, node: {}, groups: [],
        routing: { rules: [], fallback: 'direct' },
        dns: { upstream: {}, domestic: '', foreign: '', rawRouting: '' },
        rawOther: ''
    };
    var s = DaeParser.serialize(config);
    assert.strictEqual(s.indexOf('group {'), -1);
});

test('group round-trip preserves shape', function() {
    var text =
        "subscription {\n    my_sub: 'https://x'\n}\n\n" +
        "group {\n    proxy {\n        filter: subtag(my_sub) && !name(keyword: 'ExpireAt')\n        policy: min_moving_avg\n    }\n}\n\n" +
        "routing {\n    fallback: proxy\n}";
    var c1 = DaeParser.parse(text);
    var s = DaeParser.serialize(c1);
    var c2 = DaeParser.parse(s);
    assert.deepStrictEqual(c2.groups, c1.groups);
    assert.deepStrictEqual(c2.subscription, c1.subscription);
    assert.strictEqual(c2.routing.fallback, c1.routing.fallback);
});
```

- [ ] **Step 2: Run tests, expect 5 failures**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
/Users/yufan/.cache/tailscale-node/bin/node tests/parser.test.js 2>&1 | tail -10
```

- [ ] **Step 3: Update `serialize()`**

Locate the `serialize:` method. After the dns block (and before the routing block), insert group emission. Also add a helper `_serializeFilter`.

Add this helper method just before `serialize:` in the parser:

```javascript
    /**
     * Render a GroupDef.filter object back to the dae filter line string.
     * Mirrors _parseGroup's supported subset.
     *
     * Output format (joined by ' && '):
     *   namePin set:        name(NODENAME)                (subscriptions/nodes/exclude ignored)
     *   subscriptions:      subtag(s1, s2, ...)
     *   nodes:              name(n1, n2, ...)
     *   excludeKeywords:    !name(keyword: 'kw')          (one per keyword)
     * If everything is empty → return '' so we emit no `filter:` line at all.
     */
    _serializeFilter: function(filter) {
        if (filter.namePin) {
            return 'name(' + filter.namePin + ')';
        }
        var parts = [];
        if (filter.subscriptions && filter.subscriptions.length > 0) {
            parts.push('subtag(' + filter.subscriptions.join(', ') + ')');
        }
        if (filter.nodes && filter.nodes.length > 0) {
            parts.push('name(' + filter.nodes.join(', ') + ')');
        }
        if (filter.excludeKeywords && filter.excludeKeywords.length > 0) {
            filter.excludeKeywords.forEach(function(kw) {
                parts.push("!name(keyword: '" + kw + "')");
            });
        }
        return parts.join(' && ');
    },
```

Now in `serialize:`, after the dns block emission (look for the `parts.push(ls.join('\n'));` that closes the dns block), insert group emission *before* the routing block:

```javascript
        // groups
        var groups = config.groups || [];
        if (groups.length > 0) {
            var ls = ['group {'];
            groups.forEach(function(g) {
                ls.push('    ' + g.name + ' {');
                var filterStr = self._serializeFilter(g.filter || {});
                if (filterStr) ls.push('        filter: ' + filterStr);
                ls.push('        policy: ' + (g.policy || 'min_moving_avg'));
                ls.push('    }');
            });
            ls.push('}');
            parts.push(ls.join('\n'));
        }
```

The existing `serialize:` defines `var self = this;` at the top — confirm or add it so `self._serializeFilter` resolves.

- [ ] **Step 4: Run tests, expect all pass**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
/Users/yufan/.cache/tailscale-node/bin/node tests/parser.test.js 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/dae-parser.js \
        luci-app-dae/tests/parser.test.js
git commit -m "feat(parser): serialize DaeConfig.groups to dae group {} block

Group block emitted between dns and routing (dae requires groups defined
before routing references them).

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 5: Backend script — `list-nodes.sh`

**Goal:** Shell script that takes a subscription URL, downloads, base64-decodes if needed, parses each `<scheme>://<rest>` line, extracts node name (URL fragment), protocol, server, port — outputs JSON. Also supports `from-file <path>` mode for testing.

**Files:**
- Create: `luci-app-dae/root/usr/lib/luci-app-dae/list-nodes.sh`
- Create: `luci-app-dae/tests/list-nodes.test.sh`
- Create: `luci-app-dae/tests/fixtures/sample-sub-b64.txt` (test fixture)
- Create: `luci-app-dae/tests/fixtures/sample-sub-plain.txt` (test fixture)

- [ ] **Step 1: Create test fixtures**

Create `luci-app-dae/tests/fixtures/sample-sub-plain.txt`:

```
ss://YWVzLTI1Ni1nY206dGVzdHBhc3M=@1.2.3.4:8388#HK_01
vmess://eyJ2IjoiMiIsInBzIjoiVVNfMDEiLCJhZGQiOiI5LjEwLjExLjEyIiwicG9ydCI6IjQ0MyIsImlkIjoiYWFhYS1iYmJiLWNjY2MtZGRkZCIsImFpZCI6IjAiLCJuZXQiOiJ3cyIsInR5cGUiOiJub25lIiwidGxzIjoidGxzIn0=
trojan://password@5.6.7.8:443#JP_Trojan
```

Wait — the vmess line has a base64-encoded JSON. Let me verify the JSON decodes to `{"v":"2","ps":"US_01","add":"9.10.11.12","port":"443",...}`. (`ps` is the node name in vmess.) Confirmed sample.

Create `luci-app-dae/tests/fixtures/sample-sub-b64.txt` — the same content base64-encoded. To create it during the test, the test script will do the encoding on the fly:

```bash
# The test will produce this on the fly via:
#   base64 < fixtures/sample-sub-plain.txt > /tmp/sample-sub-b64.txt
```

(So we only need to commit `sample-sub-plain.txt`.)

- [ ] **Step 2: Write failing test script**

Create `luci-app-dae/tests/list-nodes.test.sh`:

```bash
#!/bin/sh
# Run: sh tests/list-nodes.test.sh
# Requires: bash/sh, base64, jq (for assertions), the script under test
set -e

SCRIPT="$(dirname "$0")/../root/usr/lib/luci-app-dae/list-nodes.sh"
FIXTURES="$(dirname "$0")/fixtures"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

run_test() {
    name="$1"; shift
    if "$@" >/dev/null; then
        echo "  PASS: $name"
        pass=$((pass+1))
    else
        echo "  FAIL: $name"
        fail=$((fail+1))
    fi
}

assert_eq() {
    if [ "$1" = "$2" ]; then return 0; else
        echo "    expected: $2"
        echo "    actual:   $1"
        return 1
    fi
}

echo "--- list-nodes.sh ---"

# Test 1: parse plain subscription file (no base64 outer layer)
run_test "from-file plain produces JSON array" sh -c "
    cp '$FIXTURES/sample-sub-plain.txt' '$TMPDIR/plain.txt'
    output=\$('$SCRIPT' from-file '$TMPDIR/plain.txt')
    [ -n \"\$output\" ] || exit 1
    echo \"\$output\" | jq -e 'type == \"array\"' >/dev/null
"

# Test 2: extracts ss node correctly
run_test "ss URI parsed: name=HK_01, protocol=ss, server=1.2.3.4, port=8388" sh -c "
    output=\$('$SCRIPT' from-file '$FIXTURES/sample-sub-plain.txt')
    ss=\$(echo \"\$output\" | jq '.[] | select(.protocol==\"ss\")')
    name=\$(echo \"\$ss\" | jq -r '.name')
    server=\$(echo \"\$ss\" | jq -r '.server')
    port=\$(echo \"\$ss\" | jq -r '.port')
    [ \"\$name\" = 'HK_01' ] && [ \"\$server\" = '1.2.3.4' ] && [ \"\$port\" = '8388' ]
"

# Test 3: extracts vmess (base64 JSON body) node name from 'ps' field
run_test "vmess URI parsed: name extracted from base64 JSON 'ps' field" sh -c "
    output=\$('$SCRIPT' from-file '$FIXTURES/sample-sub-plain.txt')
    vmess=\$(echo \"\$output\" | jq '.[] | select(.protocol==\"vmess\")')
    name=\$(echo \"\$vmess\" | jq -r '.name')
    [ \"\$name\" = 'US_01' ]
"

# Test 4: extracts trojan node name from URL fragment
run_test "trojan URI parsed: name from #fragment" sh -c "
    output=\$('$SCRIPT' from-file '$FIXTURES/sample-sub-plain.txt')
    trojan=\$(echo \"\$output\" | jq '.[] | select(.protocol==\"trojan\")')
    name=\$(echo \"\$trojan\" | jq -r '.name')
    [ \"\$name\" = 'JP_Trojan' ]
"

# Test 5: auto-detects base64-encoded outer wrapper
run_test "from-file with base64-outer produces same result as plain" sh -c "
    base64 < '$FIXTURES/sample-sub-plain.txt' > '$TMPDIR/b64.txt'
    out_b64=\$('$SCRIPT' from-file '$TMPDIR/b64.txt' | jq -S .)
    out_plain=\$('$SCRIPT' from-file '$FIXTURES/sample-sub-plain.txt' | jq -S .)
    [ \"\$out_b64\" = \"\$out_plain\" ]
"

echo
echo "Passed: $pass  Failed: $fail"
[ "$fail" = "0" ]
```

Make executable:

```bash
chmod +x /tmp/luci-app-dae-split/luci-app-dae/tests/list-nodes.test.sh
```

- [ ] **Step 3: Run tests — expect failure (script doesn't exist yet)**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
sh tests/list-nodes.test.sh 2>&1 | tail -10
```

Expected: script not found errors.

- [ ] **Step 4: Implement `list-nodes.sh`**

Create `luci-app-dae/root/usr/lib/luci-app-dae/list-nodes.sh`:

```bash
#!/bin/sh
# luci-app-dae node list extractor
#
# Usage:
#   list-nodes.sh fetch <sub_name> <url>     - wget URL, parse, return JSON array
#   list-nodes.sh from-file <path>           - parse a local file (for tests)
#   list-nodes.sh refresh-all                - fetch all subs from /etc/dae/config.dae, update cache
#
# Output: JSON array of {name, protocol, server, port} on stdout.
# For refresh-all, also writes /tmp/dae-nodes-cache.json with the merged result.
#
# Supported URI schemes: ss, vmess, vless, trojan, hysteria2, tuic
# Limitations: Clash YAML / SIP008 not supported.

CACHE=/tmp/dae-nodes-cache.json

# --- URI parsers ---
# Each emits one JSON object per call: {"name":"X","protocol":"Y","server":"Z","port":N}

parse_uri() {
    line="$1"
    # extract scheme
    scheme=$(echo "$line" | sed -n 's|^\([a-z0-9]*\)://.*|\1|p')
    case "$scheme" in
        ss)       parse_ss "$line" ;;
        vmess)    parse_vmess "$line" ;;
        vless|trojan|hysteria2|tuic)  parse_generic "$scheme" "$line" ;;
        *) return 0 ;;
    esac
}

# ss://base64(method:pass)@host:port#name   OR   ss://base64(method:pass@host:port)#name
parse_ss() {
    body=$(echo "$1" | sed 's|^ss://||')
    # split off #fragment
    name=$(echo "$body" | sed -n 's|.*#\(.*\)$|\1|p')
    [ -z "$name" ] && name="unnamed"
    name=$(printf '%s' "$name" | sed 's|+| |g' | awk '{ for (i=1;i<=length($0);i++) { c=substr($0,i,1); if (c=="%") { hex=substr($0,i+1,2); printf "%c", strtonum("0x"hex); i+=2 } else printf "%s", c } }')
    body_no_frag=$(echo "$body" | sed 's|#.*||')
    # try "userinfo@host:port" form first
    after_at=$(echo "$body_no_frag" | sed -n 's|.*@\(.*\)$|\1|p')
    if [ -n "$after_at" ]; then
        host=$(echo "$after_at" | sed 's|:.*||')
        port=$(echo "$after_at" | sed 's|.*:||')
    else
        # legacy form: full base64 of method:pass@host:port
        decoded=$(printf '%s' "$body_no_frag" | base64 -d 2>/dev/null || echo "")
        host=$(echo "$decoded" | sed -n 's|.*@\([^:]*\):.*|\1|p')
        port=$(echo "$decoded" | sed -n 's|.*@[^:]*:\([0-9]*\)|\1|p')
    fi
    printf '{"name":"%s","protocol":"ss","server":"%s","port":%s}\n' "$name" "$host" "${port:-0}"
}

# vmess://base64(json) — JSON has {add, port, ps:nodeName}
parse_vmess() {
    b64=$(echo "$1" | sed 's|^vmess://||')
    # pad to multiple of 4
    pad=$(( (4 - ${#b64} % 4) % 4 ))
    while [ $pad -gt 0 ]; do b64="${b64}="; pad=$((pad - 1)); done
    json=$(printf '%s' "$b64" | base64 -d 2>/dev/null || echo "")
    if [ -z "$json" ]; then return 0; fi
    name=$(echo "$json" | sed -n 's|.*"ps":[[:space:]]*"\([^"]*\)".*|\1|p')
    add=$(echo  "$json" | sed -n 's|.*"add":[[:space:]]*"\([^"]*\)".*|\1|p')
    port=$(echo "$json" | sed -n 's|.*"port":[[:space:]]*"\?\([0-9]*\)"\?.*|\1|p')
    printf '{"name":"%s","protocol":"vmess","server":"%s","port":%s}\n' "${name:-unnamed}" "$add" "${port:-0}"
}

# scheme://creds@host:port?...#name
parse_generic() {
    scheme="$1"; line="$2"
    body=$(echo "$line" | sed "s|^${scheme}://||")
    name=$(echo "$body" | sed -n 's|.*#\(.*\)$|\1|p')
    [ -z "$name" ] && name="unnamed"
    name=$(printf '%s' "$name" | sed 's|+| |g' | awk '{ for (i=1;i<=length($0);i++) { c=substr($0,i,1); if (c=="%") { hex=substr($0,i+1,2); printf "%c", strtonum("0x"hex); i+=2 } else printf "%s", c } }')
    # strip query, then #fragment
    body=$(echo "$body" | sed 's|#.*||; s|?.*||')
    # split off creds@host:port
    after_at=$(echo "$body" | sed -n 's|.*@\(.*\)$|\1|p')
    if [ -n "$after_at" ]; then
        host=$(echo "$after_at" | sed 's|:.*||')
        port=$(echo "$after_at" | sed 's|.*:||')
    else
        host=$(echo "$body" | sed 's|:.*||')
        port=$(echo "$body" | sed 's|.*:||')
    fi
    printf '{"name":"%s","protocol":"%s","server":"%s","port":%s}\n' "$name" "$scheme" "$host" "${port:-0}"
}

# --- main parser: read multi-URI text (possibly base64-wrapped) ---
parse_content() {
    raw="$1"
    # auto-detect base64 outer wrapper: try decoding, if result contains '://' it's likely encoded
    decoded=$(printf '%s' "$raw" | base64 -d 2>/dev/null || echo "")
    if echo "$decoded" | grep -q '://'; then
        text="$decoded"
    else
        text="$raw"
    fi

    first=1
    echo "["
    echo "$text" | grep -E '^(ss|vmess|vless|trojan|hysteria2|tuic)://' | while IFS= read -r line; do
        json=$(parse_uri "$line")
        if [ -n "$json" ]; then
            if [ "$first" = "1" ]; then
                printf '  %s' "$json"
                first=0
            else
                printf ',\n  %s' "$json"
            fi
        fi
    done
    echo
    echo "]"
}

# --- command dispatch ---
cmd="$1"; shift
case "$cmd" in
    from-file)
        content=$(cat "$1")
        parse_content "$content"
        ;;
    fetch)
        sub_name="$1"; url="$2"
        content=$(wget -q -O - "$url" 2>/dev/null || echo "")
        if [ -z "$content" ]; then
            echo '[]'
            exit 1
        fi
        parse_content "$content"
        ;;
    refresh-all)
        # Read /etc/dae/config.dae, find subscription { ... }, extract name:url pairs
        # Aggregate into cache file
        config=/etc/dae/config.dae
        [ -f "$config" ] || { echo '{}' > "$CACHE"; exit 0; }
        # Crude extraction of subscription block lines
        subs=$(awk '/^subscription[[:space:]]*\{/,/^\}/' "$config" \
               | grep -E "^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:" \
               | sed -E "s|^[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*['\"]?([^'\"]*)['\"]?[[:space:]]*$|\1\t\2|")

        echo "{"
        echo '  "updated_at": '"$(date +%s)"','
        echo '  "subscriptions": {'
        first=1
        echo "$subs" | while IFS="$(printf '\t')" read -r name url; do
            [ -z "$name" ] && continue
            nodes=$("$0" fetch "$name" "$url")
            if [ "$first" = "1" ]; then
                printf '    "%s": %s' "$name" "$nodes"
                first=0
            else
                printf ',\n    "%s": %s' "$name" "$nodes"
            fi
        done
        echo
        echo '  }'
        echo "}" > "$CACHE"
        cat "$CACHE"
        ;;
    *)
        echo "Usage: $0 {fetch <name> <url> | from-file <path> | refresh-all}" >&2
        exit 1
        ;;
esac
```

Make executable:

```bash
chmod +x /tmp/luci-app-dae-split/luci-app-dae/root/usr/lib/luci-app-dae/list-nodes.sh
```

- [ ] **Step 5: Run tests — expect pass**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
sh tests/list-nodes.test.sh 2>&1 | tail -10
```

Expected: `Passed: 5  Failed: 0`.

If any test fails, read the diff carefully — most likely culprits: `base64` flag differences across OS (use `base64 -d` on Linux, but macOS uses `-D`), `sed -E` differences, etc. Adjust the script to use POSIX-compatible flags only.

- [ ] **Step 6: Commit**

```bash
cd /tmp/luci-app-dae-split
chmod +x luci-app-dae/tests/list-nodes.test.sh \
         luci-app-dae/root/usr/lib/luci-app-dae/list-nodes.sh
git add luci-app-dae/root/usr/lib/luci-app-dae/list-nodes.sh \
        luci-app-dae/tests/list-nodes.test.sh \
        luci-app-dae/tests/fixtures/sample-sub-plain.txt
git commit -m "feat(backend): add list-nodes.sh for subscription URI parsing

Parses ss / vmess / vless / trojan / hysteria2 / tuic URIs from either
plain or base64-wrapped subscription text. Outputs JSON array of
{name, protocol, server, port}.

Modes:
- fetch <sub> <url>    : wget URL, parse, emit JSON
- from-file <path>     : same but from local file (for tests)
- refresh-all          : iterate subscriptions in /etc/dae/config.dae,
                         aggregate into /tmp/dae-nodes-cache.json

Clash YAML / SIP008 not supported.

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 6: ACL update for list-nodes.sh

**Goal:** Grant LuCI's `fs.exec_direct` permission to run `/usr/lib/luci-app-dae/list-nodes.sh`.

**Files:**
- Modify: `luci-app-dae/root/usr/share/rpcd/acl.d/luci-app-dae.json`

- [ ] **Step 1: Read current ACL**

```bash
cat /tmp/luci-app-dae-split/luci-app-dae/root/usr/share/rpcd/acl.d/luci-app-dae.json
```

- [ ] **Step 2: Add exec permission for list-nodes.sh**

Edit so the `read.file` section grants exec permission for the new script, and `read.file` gets read access to the cache file:

```json
{
    "luci-app-dae": {
        "description": "Grant access to dae configuration",
        "read": {
            "file": {
                "/etc/dae/config.dae": [ "read" ],
                "/etc/dae/example.dae": [ "read" ],
                "/var/log/dae/dae.log": [ "read" ],
                "/tmp/dae-nodes-cache.json": [ "read" ],
                "/etc/init.d/dae hot_reload": [ "exec" ],
                "/usr/lib/luci-app-dae/list-nodes.sh fetch *": [ "exec" ],
                "/usr/lib/luci-app-dae/list-nodes.sh refresh-all": [ "exec" ]
            },
            "ubus": {
                "service": [ "list" ]
            },
            "uci": [ "dae" ]
        },
        "write": {
            "file": {
                "/etc/dae/config.dae": [ "write" ]
            },
            "uci": [ "dae" ]
        }
    }
}
```

(Wildcard `*` after `fetch` lets it pass arbitrary subscription name + URL args.)

- [ ] **Step 3: Verify it's valid JSON**

```bash
/Users/yufan/.cache/tailscale-node/bin/node -e "JSON.parse(require('fs').readFileSync('/tmp/luci-app-dae-split/luci-app-dae/root/usr/share/rpcd/acl.d/luci-app-dae.json', 'utf-8')); console.log('valid JSON')"
```

- [ ] **Step 4: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/root/usr/share/rpcd/acl.d/luci-app-dae.json
git commit -m "feat(acl): grant exec for list-nodes.sh + read cache file

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 7: config.js — Tab buttons styled as cbi-button

**Goal:** Replace the existing `<ul class="cbi-tabmenu"><li class="cbi-tab">` structure with `<button class="btn cbi-button cbi-button-action">` style (so they actually look like buttons), add a third "All Nodes" tab as an empty pane.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Locate the tab-bar block in `_buildUI`**

The current code uses:

```javascript
container.appendChild(E('ul', { 'class': 'cbi-tabmenu' }, [
    E('li', { 'id': 'tab-btn-form', 'class': 'cbi-tab ...', 'click': ... }, _('Form')),
    E('li', { 'id': 'tab-btn-text', 'class': 'cbi-tab ...', 'click': ... }, _('Text'))
]));
```

- [ ] **Step 2: Replace with cbi-button div + add third tab**

Replace the tab-bar block with:

```javascript
// Tab bar — use button styling so it actually looks like clickable buttons
var tabBtn = function(id, label, active) {
    return E('button', {
        'id': 'tab-btn-' + id,
        'class': active ? 'btn cbi-button cbi-button-action' : 'btn cbi-button',
        'style': 'margin-right: 0.5em',
        'click': function() { self._switchTab(id); }
    }, label);
};
container.appendChild(E('div', { 'class': 'cbi-tabcontainer', 'style': 'margin-bottom:1em' }, [
    tabBtn('form',  _('Form'),       self._activeTab === 'form'),
    tabBtn('nodes', _('All Nodes'),  self._activeTab === 'nodes'),
    tabBtn('text',  _('Text'),       self._activeTab === 'text')
]));
```

- [ ] **Step 3: Replace the existing pane assembly**

After the tab bar in `_buildUI`, where the form pane and text pane are currently built, replace with all three panes:

```javascript
// Form pane
var formPane = self._buildFormPane();
formPane.id = 'pane-form';
formPane.style.display = self._activeTab === 'form' ? '' : 'none';
container.appendChild(formPane);

// All Nodes pane (Task 11 fills this in)
var nodesPane = self._buildNodesPane();
nodesPane.id = 'pane-nodes';
nodesPane.style.display = self._activeTab === 'nodes' ? '' : 'none';
container.appendChild(nodesPane);

// Text pane
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
```

- [ ] **Step 4: Update `_switchTab` to handle 3 tabs**

Replace the existing `_switchTab` with:

```javascript
_switchTab: function(tab) {
    var self = this;
    if (tab === self._activeTab) return;

    // Form → Text: serialize current form data
    if (self._activeTab === 'form' && tab === 'text') {
        try {
            var text = self._parser.serialize(self._getFormData());
            document.getElementById('dae-raw-text').value = text;
        } catch(e) {
            ui.addNotification(null, E('p', _('Failed to serialize form: ') + e.message));
            return;
        }
    }
    // Text → Form: parse text into config + refresh form
    if (self._activeTab === 'text' && tab === 'form') {
        var text = document.getElementById('dae-raw-text').value;
        try {
            self._config = self._parser.parse(text);
            self._parser.ensureDefaultGroup(self._config);
            self._refreshForm();
        } catch(e) {
            ui.addNotification(null, E('p', _('Config text has errors. Please fix before switching to form mode.')));
            return;
        }
    }
    // For nodes tab: re-render from cache (Task 11 implements _refreshNodes)
    if (tab === 'nodes') {
        self._refreshNodes();
    }

    self._activeTab = tab;
    ['form','nodes','text'].forEach(function(t) {
        document.getElementById('pane-' + t).style.display = (t === tab) ? '' : 'none';
        var btn = document.getElementById('tab-btn-' + t);
        btn.className = (t === tab) ? 'btn cbi-button cbi-button-action' : 'btn cbi-button';
    });
},
```

- [ ] **Step 5: Add `_buildNodesPane` and `_refreshNodes` stubs (Task 11 fills them)**

Append to the methods list:

```javascript
_buildNodesPane: function() {
    return E('div', { 'class': 'cbi-section' }, _('(node list — implemented in Task 11)'));
},
_refreshNodes: function() {
    // implemented in Task 11
},
```

- [ ] **Step 6: Call `ensureDefaultGroup` after initial parse**

In `render()`, after the `self._config = self._parser.parse(content);` line, add:

```javascript
self._parser.ensureDefaultGroup(self._config);
```

(For both the success and the catch-fallback path.)

- [ ] **Step 7: Syntax check**

```bash
/Users/yufan/.cache/tailscale-node/bin/node --check /tmp/luci-app-dae-split/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js && echo "OK"
```

- [ ] **Step 8: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(ui): 3 tabs styled as cbi-button (Form / All Nodes / Text)

Replaces the cbi-tabmenu/li structure which renders as plain text without
form.Map. Uses cbi-button + cbi-button-action for the active state so the
tabs look like buttons.

ensureDefaultGroup is called after parse so the UI always has at least
one 'proxy' group to display.

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 8: config.js — Form: subscription section simplified

**Goal:** Subscription row no longer has 【获取节点】 or in-line expand — that responsibility moved to the All Nodes tab. Keep name / URL / delete.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Find current `_makeSubRow` and `_buildSubscriptionSection`**

These currently include logic for the expand button (which doesn't exist yet but might have been hinted in the v2 spec sketch). Verify the current code shows just `[name] [url] [delete]`.

- [ ] **Step 2: Confirm no change needed if already simple**

Read the current method bodies. If they already match the v2 spec (just Name / URL / Delete + Add button), no changes needed — skip to step 4.

If they have any `获取节点` / `Fetch nodes` button code, remove it.

- [ ] **Step 3: Verify the section title is clear**

The subscription `<h3>` should be `_('Subscriptions')`. Confirm.

- [ ] **Step 4: Verify the form pane order**

In `_buildFormPane`, the v2 order should be:

```javascript
pane.appendChild(self._buildSubscriptionSection());
pane.appendChild(self._buildGroupSection());      // ← NEW (Task 9 replaces the stub)
pane.appendChild(self._buildRoutingSection());
pane.appendChild(self._buildDNSSection());
pane.appendChild(self._buildGlobalSection());
```

**Remove** the existing call to `self._buildNodeSection()` — manual node CRUD now lives in the All Nodes tab.

Add a stub for `_buildGroupSection` (Task 9 implements it):

```javascript
_buildGroupSection: function() {
    return E('div', { 'class': 'cbi-section', 'id': 'section-group' }, [
        E('h3', {}, _('Proxy Groups')),
        E('p', {}, _('(implemented in Task 9)'))
    ]);
},
```

- [ ] **Step 5: Delete the manual node methods**

The following methods are obsolete after this task and should be deleted from `config.js`:

- `_buildNodeSection`
- `_makeNodeRow`

(They will be replaced by All Nodes tab implementation in Task 11. Don't worry about losing the code — git history has it if needed.)

- [ ] **Step 6: Syntax check**

```bash
/Users/yufan/.cache/tailscale-node/bin/node --check /tmp/luci-app-dae-split/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js && echo "OK"
```

- [ ] **Step 7: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "refactor(ui): remove manual node section from form mode

Manual nodes now live in the All Nodes tab (see Task 11). _buildFormPane
order is now: subscription → group → routing → dns → global.

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 9: config.js — Group section (the main UI work)

**Goal:** Implement `_buildGroupSection`, `_makeGroupCard`, supporting helpers. Each group renders as a card with: name input, multi-checkbox for subscriptions, multi-checkbox for manual nodes, exclude-keyword input, policy dropdown, conditional namePin selector.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Replace the `_buildGroupSection` stub**

Replace with full implementation:

```javascript
_buildGroupSection: function() {
    var self = this;
    var section = E('div', { 'class': 'cbi-section', 'id': 'section-group' });
    section.appendChild(E('h3', {}, _('Proxy Groups')));

    var container = E('div', { 'id': 'group-cards' });
    var groups = (self._config && self._config.groups) || [];
    groups.forEach(function(g, idx) {
        container.appendChild(self._makeGroupCard(g, idx === 0));
    });
    section.appendChild(container);

    section.appendChild(E('button', {
        'class': 'btn cbi-button cbi-button-add',
        'click': function() {
            var groups = self._config.groups || [];
            var newName = 'group' + (groups.length + 1);
            var newGroup = {
                name: newName,
                filter: {
                    subscriptions: Object.keys(self._config.subscription || {}),
                    nodes: [],
                    excludeKeywords: ['ExpireAt'],
                    namePin: null
                },
                policy: 'min_moving_avg'
            };
            self._config.groups.push(newGroup);
            document.getElementById('group-cards').appendChild(self._makeGroupCard(newGroup, false));
        }
    }, '+ ' + _('Add Group')));

    return section;
},

_makeGroupCard: function(group, isFirst) {
    var self = this;
    var card = E('div', { 'class': 'cbi-section-node group-card', 'style': 'border:1px solid #ccc;padding:1em;margin-bottom:0.5em', 'data-group-name': group.name });

    // Header row: name + delete button
    var nameInput = E('input', {
        'type': 'text',
        'class': 'cbi-input-text group-name',
        'value': group.name,
        'style': 'width:14em',
        'pattern': '[\\w]+',
        'change': function(ev) {
            // Renaming: update card's data-group-name + refresh routing action dropdowns
            var oldName = card.getAttribute('data-group-name');
            var newName = ev.target.value;
            card.setAttribute('data-group-name', newName);
            self._onGroupRenamed(oldName, newName);
        }
    });

    var delBtn = E('button', {
        'class': 'btn cbi-button cbi-button-remove',
        'style': 'float:right',
        'disabled': isFirst ? '' : null,
        'click': function() {
            if (isFirst) return;
            self._onGroupDeleted(card.getAttribute('data-group-name'));
            card.parentNode.removeChild(card);
        }
    }, _('Delete Group'));

    card.appendChild(E('div', { 'style': 'margin-bottom:0.5em' }, [
        delBtn,
        E('label', { 'style': 'font-weight:bold;margin-right:0.5em' }, _('Group name:')),
        nameInput
    ]));

    // Subscriptions checkbox grid
    var subKeys = Object.keys((self._config && self._config.subscription) || {});
    var subBox = E('div', { 'class': 'group-subs', 'style': 'margin:0.5em 0' });
    subBox.appendChild(E('label', { 'style': 'display:block;font-weight:bold' }, _('Use Subscriptions:')));
    if (subKeys.length === 0) {
        subBox.appendChild(E('em', {}, _('(no subscriptions defined)')));
    } else {
        subKeys.forEach(function(sub) {
            var checked = (group.filter.subscriptions || []).indexOf(sub) !== -1;
            subBox.appendChild(E('label', { 'style': 'margin-right:1em' }, [
                E('input', {
                    'type': 'checkbox',
                    'class': 'group-sub-cb',
                    'value': sub,
                    'checked': checked ? '' : null
                }),
                ' ' + sub
            ]));
        });
    }
    card.appendChild(subBox);

    // Manual nodes checkbox grid
    var nodeKeys = Object.keys((self._config && self._config.node) || {});
    if (nodeKeys.length > 0) {
        var nodeBox = E('div', { 'class': 'group-nodes', 'style': 'margin:0.5em 0' });
        nodeBox.appendChild(E('label', { 'style': 'display:block;font-weight:bold' }, _('Use Manual Nodes:')));
        nodeKeys.forEach(function(n) {
            var checked = (group.filter.nodes || []).indexOf(n) !== -1;
            nodeBox.appendChild(E('label', { 'style': 'margin-right:1em' }, [
                E('input', {
                    'type': 'checkbox',
                    'class': 'group-node-cb',
                    'value': n,
                    'checked': checked ? '' : null
                }),
                ' ' + n
            ]));
        });
        card.appendChild(nodeBox);
    }

    // Exclude keywords input
    card.appendChild(E('div', { 'style': 'margin:0.5em 0' }, [
        E('label', { 'style': 'display:block;font-weight:bold' }, _('Exclude nodes whose name contains:')),
        E('input', {
            'type': 'text',
            'class': 'cbi-input-text group-exclude',
            'value': (group.filter.excludeKeywords || []).join(', '),
            'placeholder': 'ExpireAt, 流量, 剩余',
            'style': 'width:30em'
        }),
        E('br'),
        E('em', { 'style': 'font-size:0.85em;color:#666' }, _('(comma-separated)'))
    ]));

    // Policy dropdown
    var policySelect = E('select', { 'class': 'cbi-input-select group-policy' }, [
        E('option', { 'value': 'min_moving_avg', 'selected': group.policy === 'min_moving_avg' ? '' : null }, _('Auto (fastest)')),
        E('option', { 'value': 'random',         'selected': group.policy === 'random' ? '' : null }, _('Random')),
        E('option', { 'value': '__pin',          'selected': group.filter.namePin ? '' : null },     _('Pin to one node'))
    ]);
    policySelect.addEventListener('change', function() {
        var pinRow = card.querySelector('.group-pin-row');
        if (policySelect.value === '__pin') {
            if (!pinRow) {
                pinRow = self._buildPinRow(group);
                pinRow.classList.add('group-pin-row');
                card.appendChild(pinRow);
            }
        } else if (pinRow) {
            pinRow.parentNode.removeChild(pinRow);
        }
    });
    card.appendChild(E('div', { 'style': 'margin:0.5em 0' }, [
        E('label', { 'style': 'display:block;font-weight:bold' }, _('Policy:')),
        policySelect
    ]));

    // Initial pin row if namePin is set
    if (group.filter.namePin) {
        var pinRow = self._buildPinRow(group);
        pinRow.classList.add('group-pin-row');
        card.appendChild(pinRow);
    }

    return card;
},

/**
 * Build the "pin to node" row — a dropdown of all known nodes
 * (from /tmp/dae-nodes-cache.json subscriptions + config.node manual).
 */
_buildPinRow: function(group) {
    var self = this;
    var allNodes = self._allKnownNodeNames();
    var sel = E('select', { 'class': 'cbi-input-select group-pin' });
    if (allNodes.length === 0) {
        sel.appendChild(E('option', { 'value': '' }, _('(no nodes — fetch in All Nodes tab first)')));
    } else {
        sel.appendChild(E('option', { 'value': '' }, _('-- choose --')));
        allNodes.forEach(function(item) {
            sel.appendChild(E('option', {
                'value': item.name,
                'selected': group.filter.namePin === item.name ? '' : null
            }, item.name + ' (' + item.source + ')'));
        });
    }
    return E('div', { 'style': 'margin:0.5em 0' }, [
        E('label', { 'style': 'display:block;font-weight:bold' }, _('Pinned node:')),
        sel
    ]);
},

/**
 * Return [{name, source}] of every node known to UI:
 *  - subscription nodes from /tmp/dae-nodes-cache.json (if cache loaded)
 *  - manual nodes from this._config.node
 */
_allKnownNodeNames: function() {
    var self = this;
    var out = [];
    var cache = self._nodesCache || {};
    var subs = cache.subscriptions || {};
    for (var subName in subs) {
        (subs[subName] || []).forEach(function(n) {
            out.push({ name: n.name, source: subName });
        });
    }
    Object.keys(self._config.node || {}).forEach(function(n) {
        out.push({ name: n, source: _('manual') });
    });
    return out;
},

/**
 * When a group is renamed, propagate to routing rules referencing the old name.
 */
_onGroupRenamed: function(oldName, newName) {
    var self = this;
    var routing = self._config.routing || { rules: [], fallback: 'direct' };
    if (routing.fallback === oldName) routing.fallback = newName;
    (routing.rules || []).forEach(function(r) {
        if (r.action === oldName) r.action = newName;
    });
    // Also update the in-memory groups array
    var g = (self._config.groups || []).filter(function(g){ return g.name === oldName; })[0];
    if (g) g.name = newName;
    // Refresh the routing table dropdowns
    self._refreshRoutingActionOptions();
},

/**
 * When a group is deleted, point any routing rule referencing it to 'direct'.
 */
_onGroupDeleted: function(name) {
    var self = this;
    self._config.groups = (self._config.groups || []).filter(function(g){ return g.name !== name; });
    var routing = self._config.routing || { rules: [], fallback: 'direct' };
    if (routing.fallback === name) routing.fallback = 'direct';
    (routing.rules || []).forEach(function(r) {
        if (r.action === name) r.action = 'direct';
    });
    self._refreshRoutingActionOptions();
    ui.addNotification(null, E('p', _('Group "%s" deleted. Routing rules referencing it have been reset to direct.').replace('%s', name)));
},

/**
 * Rebuild all <select.rule-action> options in the routing table to match
 * current self._config.groups.
 */
_refreshRoutingActionOptions: function() {
    var self = this;
    var groupNames = (self._config.groups || []).map(function(g) { return g.name; });
    var allActions = ['direct', 'block'].concat(groupNames);
    document.querySelectorAll('.rule-action').forEach(function(sel) {
        var current = sel.value;
        // Clear and re-populate
        sel.innerHTML = '';
        allActions.forEach(function(a) {
            sel.appendChild(E('option', { 'value': a, 'selected': a === current ? '' : null }, a));
        });
        // If current value no longer in options, add it (rare; deleted group still referenced)
        if (allActions.indexOf(current) === -1 && current) {
            sel.appendChild(E('option', { 'value': current, 'selected': '' }, current));
        }
    });
},
```

- [ ] **Step 2: Syntax check**

```bash
/Users/yufan/.cache/tailscale-node/bin/node --check /tmp/luci-app-dae-split/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(ui): proxy group card with filter + policy + namePin

Each group renders as a card. First group cannot be deleted (the always-
present default 'proxy' group). Renaming a group propagates to routing
rules referencing it. Deleting a group resets references to 'direct'.

Policy = 'Pin to one node' reveals a node selector populated from the
nodes cache (built in Task 11).

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 10: config.js — Routing action dropdown sourced from groups

**Goal:** `_makeActionSelect` now produces options `[direct, block, ...groupNames]`. Remove the old logic that used subscription names + node names.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Replace `_makeActionSelect`**

Locate the current method and replace with:

```javascript
_makeActionSelect: function(id, selectedAction) {
    var self = this;
    var groupNames = (self._config && self._config.groups || []).map(function(g) { return g.name; });
    var options = ['direct', 'block'].concat(groupNames);
    if (selectedAction && options.indexOf(selectedAction) === -1) {
        // Preserve forward-compatibility for unknown actions
        options.push(selectedAction);
    }
    var attrs = { 'class': 'cbi-input-select rule-action' };
    if (id) attrs['id'] = id;
    var sel = E('select', attrs);
    options.forEach(function(opt) {
        sel.appendChild(E('option', {
            'value': opt,
            'selected': opt === selectedAction ? '' : null
        }, opt));
    });
    return sel;
},
```

- [ ] **Step 2: Update routing default fallback to use first group**

Locate `_buildRoutingSection`. Where it pulls `routing.fallback || 'direct'`, change the default to:

```javascript
var fallbackDefault = (self._config.groups && self._config.groups[0] && self._config.groups[0].name) || 'direct';
var fallbackRow = E('tr', { 'class': 'cbi-section-table-row', 'id': 'routing-fallback-row' }, [
    E('td', { 'class': 'cbi-section-table-cell' }, E('strong', {}, _('Fallback'))),
    E('td', { 'class': 'cbi-section-table-cell' }, '—'),
    E('td', { 'class': 'cbi-section-table-cell' }, [
        self._makeActionSelect('routing-fallback-action', routing.fallback || fallbackDefault)
    ]),
    E('td', { 'class': 'cbi-section-table-cell' }, '—')
]);
```

- [ ] **Step 3: Add default routing rules when none defined**

In `_buildRoutingSection`, replace:

```javascript
var routing = ((self._config || {}).routing) || { rules: [], fallback: 'direct' };
```

with:

```javascript
var routing = ((self._config || {}).routing) || { rules: [], fallback: 'direct' };
// If no rules defined, seed the standard ones (private + cn IPs/domains → direct)
if ((!routing.rules || routing.rules.length === 0)) {
    routing.rules = [
        { condType: 'dip',    condValue: 'geoip:private', action: 'direct' },
        { condType: 'dip',    condValue: 'geoip:cn',      action: 'direct' },
        { condType: 'domain', condValue: 'geosite:cn',    action: 'direct' }
    ];
    self._config.routing = routing;
}
```

- [ ] **Step 4: Syntax check**

```bash
/Users/yufan/.cache/tailscale-node/bin/node --check /tmp/luci-app-dae-split/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js && echo "OK"
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "fix(ui): routing action dropdown sources from groups, not subs

v1 used subscription names and node names as action targets — incorrect
per dae's data model. v2: action options are [direct, block, ...groupNames].

Also seed default 3-line routing (geoip:private/cn, geosite:cn → direct)
when no rules are defined yet.

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 11: config.js — All Nodes tab

**Goal:** Implement `_buildNodesPane`, `_refreshNodes`, `_loadNodesCache`, manual-node add/delete inline, refresh button calls `list-nodes.sh refresh-all`.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Replace `_buildNodesPane` and `_refreshNodes` stubs**

```javascript
_buildNodesPane: function() {
    var self = this;
    var pane = E('div', { 'class': 'cbi-section' });

    pane.appendChild(E('h3', {}, _('All Nodes')));

    // Toolbar: refresh + filter
    var refreshBtn = E('button', {
        'class': 'btn cbi-button cbi-button-action',
        'click': function() { self._refreshSubscriptionNodes(); }
    }, '🔄 ' + _('Refresh Subscription Nodes'));

    var filterSel = E('select', { 'class': 'cbi-input-select', 'id': 'nodes-filter', 'change': function() { self._renderNodesTable(); } }, [
        E('option', { 'value': '' }, _('All sources'))
    ]);

    pane.appendChild(E('div', { 'style': 'margin-bottom:0.5em' }, [
        refreshBtn,
        E('span', { 'style': 'margin-left:1em' }, _('Filter by source:') + ' '),
        filterSel
    ]));

    // Table container
    pane.appendChild(E('div', { 'id': 'nodes-table-container' }));

    // Manual add button
    pane.appendChild(E('button', {
        'class': 'btn cbi-button cbi-button-add',
        'style': 'margin-top:0.5em',
        'click': function() { self._addManualNode(); }
    }, '+ ' + _('Add Manual Node')));

    return pane;
},

_refreshNodes: function() {
    var self = this;
    self._loadNodesCache().then(function() {
        self._renderFilterOptions();
        self._renderNodesTable();
    });
},

_loadNodesCache: function() {
    var self = this;
    return fs.read_direct('/tmp/dae-nodes-cache.json', 'text')
        .then(function(text) {
            try { self._nodesCache = JSON.parse(text); }
            catch(e) { self._nodesCache = { subscriptions: {}, updated_at: 0 }; }
        })
        .catch(function() {
            self._nodesCache = { subscriptions: {}, updated_at: 0 };
        });
},

_renderFilterOptions: function() {
    var self = this;
    var sel = document.getElementById('nodes-filter');
    if (!sel) return;
    var current = sel.value;
    sel.innerHTML = '';
    sel.appendChild(E('option', { 'value': '' }, _('All sources')));
    var cache = self._nodesCache || { subscriptions: {} };
    Object.keys(cache.subscriptions || {}).forEach(function(s) {
        sel.appendChild(E('option', { 'value': s, 'selected': s === current ? '' : null }, s));
    });
    sel.appendChild(E('option', { 'value': '__manual', 'selected': current === '__manual' ? '' : null }, _('Manual')));
},

_renderNodesTable: function() {
    var self = this;
    var container = document.getElementById('nodes-table-container');
    if (!container) return;
    container.innerHTML = '';

    var cache = self._nodesCache || { subscriptions: {} };
    var filterEl = document.getElementById('nodes-filter');
    var filterVal = filterEl ? filterEl.value : '';

    var rows = [];

    // Subscription nodes
    Object.keys(cache.subscriptions || {}).forEach(function(subName) {
        if (filterVal && filterVal !== subName) return;
        (cache.subscriptions[subName] || []).forEach(function(n) {
            rows.push({
                name: n.name, protocol: n.protocol, server: n.server, port: n.port,
                source: subName, manual: false
            });
        });
    });
    // Manual nodes (parsed shallowly from config.node URIs — show URI as server:port)
    if (!filterVal || filterVal === '__manual') {
        Object.keys((self._config && self._config.node) || {}).forEach(function(n) {
            var uri = self._config.node[n];
            var scheme = (uri.match(/^([a-z0-9]+):\/\//) || [])[1] || '?';
            rows.push({
                name: n, protocol: scheme, server: '(see URI)', port: '',
                source: _('manual'), manual: true, uri: uri
            });
        });
    }

    var table = E('table', { 'class': 'table cbi-section-table' }, [
        E('tr', { 'class': 'cbi-section-table-titles' }, [
            E('th', { 'class': 'cbi-section-table-cell' }, _('Name')),
            E('th', { 'class': 'cbi-section-table-cell' }, _('Protocol')),
            E('th', { 'class': 'cbi-section-table-cell' }, _('Server:Port')),
            E('th', { 'class': 'cbi-section-table-cell' }, _('Source')),
            E('th', { 'class': 'cbi-section-table-cell' }, _('Action'))
        ])
    ]);

    if (rows.length === 0) {
        table.appendChild(E('tr', {}, [
            E('td', { 'colspan': 5, 'style': 'text-align:center;color:#999;padding:1em' },
                _('No nodes yet. Click "Refresh Subscription Nodes" or "Add Manual Node".'))
        ]));
    } else {
        rows.forEach(function(r) {
            var row = E('tr', { 'class': 'cbi-section-table-row' }, [
                E('td', { 'class': 'cbi-section-table-cell' }, r.name),
                E('td', { 'class': 'cbi-section-table-cell' }, r.protocol),
                E('td', { 'class': 'cbi-section-table-cell' }, r.server + (r.port ? ':' + r.port : '')),
                E('td', { 'class': 'cbi-section-table-cell' }, r.source),
                E('td', { 'class': 'cbi-section-table-cell' }, r.manual ? E('button', {
                    'class': 'btn cbi-button cbi-button-remove',
                    'click': function() {
                        delete self._config.node[r.name];
                        self._renderNodesTable();
                    }
                }, _('Delete')) : '—')
            ]);
            table.appendChild(row);
        });
    }

    container.appendChild(table);
},

_addManualNode: function() {
    var self = this;
    // Inline editor row: a tiny prompt + input. Use a simple ui.showModal alternative.
    var nameInput = E('input', { 'type': 'text', 'placeholder': 'myhomeproxy', 'class': 'cbi-input-text', 'style': 'width:12em' });
    var uriInput  = E('input', { 'type': 'text', 'placeholder': 'ss://... or vmess://...', 'class': 'cbi-input-text', 'style': 'width:30em' });
    ui.showModal(_('Add Manual Node'), [
        E('p', {}, _('Enter a name and the node URI:')),
        E('div', { 'style': 'margin:0.5em 0' }, [E('label', {}, _('Name:') + ' '), nameInput]),
        E('div', { 'style': 'margin:0.5em 0' }, [E('label', {}, _('URI:') + ' '),  uriInput]),
        E('div', { 'class': 'right' }, [
            E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
            ' ',
            E('button', {
                'class': 'btn cbi-button cbi-button-action',
                'click': function() {
                    var name = nameInput.value.trim();
                    var uri  = uriInput.value.trim();
                    if (!name.match(/^\w+$/)) { ui.addNotification(null, E('p', _('Name must be letters/digits/underscore only'))); return; }
                    if (!uri.match(/^[a-z0-9]+:\/\//))   { ui.addNotification(null, E('p', _('URI must start with scheme://'))); return; }
                    self._config.node = self._config.node || {};
                    self._config.node[name] = uri;
                    ui.hideModal();
                    self._renderNodesTable();
                }
            }, _('Add'))
        ])
    ]);
},

_refreshSubscriptionNodes: function() {
    var self = this;
    ui.addNotification(null, E('p', _('Fetching subscriptions… this may take a few seconds.')));
    return fs.exec_direct('/usr/lib/luci-app-dae/list-nodes.sh', ['refresh-all'])
        .then(function() { return self._loadNodesCache(); })
        .then(function() {
            self._renderFilterOptions();
            self._renderNodesTable();
            ui.addNotification(null, E('p', _('Nodes refreshed.')));
        })
        .catch(function(e) {
            ui.addNotification(null, E('p', _('Refresh failed: ') + (e.message || e)));
        });
},
```

- [ ] **Step 2: Add `'require fs'` if not present**

Verify the top of config.js has `'require fs';` already. (It should — fs is already used.)

- [ ] **Step 3: Load cache in `render()` so Group cards' Pin dropdowns work on first load**

In `render()`, after `self._parser.ensureDefaultGroup(self._config)`, add:

```javascript
return self._loadNodesCache().then(function() {
    return self._buildUI(content);
});
```

(Replace the existing `return self._buildUI(content);` with the promise-chained version.)

- [ ] **Step 4: Syntax check**

```bash
/Users/yufan/.cache/tailscale-node/bin/node --check /tmp/luci-app-dae-split/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js && echo "OK"
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(ui): All Nodes tab — view subscriptions cache + manual CRUD

- Table merges subscription nodes (from /tmp/dae-nodes-cache.json) and
  manual nodes (from config.node).
- Refresh button calls list-nodes.sh refresh-all.
- Filter dropdown narrows to a single subscription or to manual nodes.
- Add Manual Node opens a modal asking for name + URI.
- Delete only available on manual rows; subscription rows are read-only.

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 12: config.js — `_getFormData` / `_refreshForm` updated for v2

**Goal:** Read groups from the UI back into `DaeConfig.groups`; refresh group cards when reloading after Text→Form.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Update `_getFormData`**

Locate the current implementation. Add group extraction. Final version:

```javascript
_getFormData: function() {
    var self = this;
    var config = {
        global: {}, subscription: {}, node: {},
        groups: [],
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

    // Manual nodes — read from in-memory self._config.node
    // (kept up-to-date by the All Nodes tab's add/delete operations)
    config.node = Object.assign({}, self._config.node || {});

    // Groups
    document.querySelectorAll('#group-cards .group-card').forEach(function(card) {
        var name = card.querySelector('.group-name').value.trim();
        if (!name) return;
        var subs = [];
        card.querySelectorAll('.group-sub-cb').forEach(function(cb) {
            if (cb.checked) subs.push(cb.value);
        });
        var nodes = [];
        card.querySelectorAll('.group-node-cb').forEach(function(cb) {
            if (cb.checked) nodes.push(cb.value);
        });
        var excludeStr = (card.querySelector('.group-exclude') || {}).value || '';
        var excludeKws = excludeStr.split(',').map(function(s){return s.trim();}).filter(Boolean);
        var policySelEl = card.querySelector('.group-policy');
        var policy = 'min_moving_avg';
        var namePin = null;
        if (policySelEl) {
            if (policySelEl.value === '__pin') {
                var pinEl = card.querySelector('.group-pin');
                if (pinEl) namePin = pinEl.value || null;
            } else {
                policy = policySelEl.value;
            }
        }
        config.groups.push({
            name: name,
            filter: { subscriptions: subs, nodes: nodes, excludeKeywords: excludeKws, namePin: namePin },
            policy: namePin ? 'min_moving_avg' : policy
        });
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

- [ ] **Step 2: Update `_refreshForm`**

Add group rebuild. Final:

```javascript
_refreshForm: function() {
    var self = this;
    var config = self._config || {};

    // Subscriptions
    var subTable = document.getElementById('sub-table');
    if (subTable) {
        subTable.querySelectorAll('.sub-row').forEach(function(r) { r.parentNode.removeChild(r); });
        Object.keys(config.subscription || {}).forEach(function(n) {
            subTable.appendChild(self._makeSubRow(n, config.subscription[n]));
        });
    }

    // Groups — full rebuild
    var groupContainer = document.getElementById('group-cards');
    if (groupContainer) {
        groupContainer.innerHTML = '';
        (config.groups || []).forEach(function(g, idx) {
            groupContainer.appendChild(self._makeGroupCard(g, idx === 0));
        });
    }

    // Routing rules
    var routingTable = document.getElementById('routing-table');
    if (routingTable) {
        routingTable.querySelectorAll('.routing-row').forEach(function(r) { r.parentNode.removeChild(r); });
        var fbRow = document.getElementById('routing-fallback-row');
        ((config.routing || {}).rules || []).forEach(function(rule) {
            routingTable.insertBefore(
                self._makeRoutingRow(rule.condType, rule.condValue, rule.action), fbRow);
        });
        self._refreshRoutingActionOptions();
        var fbEl = document.getElementById('routing-fallback-action');
        if (fbEl && config.routing) fbEl.value = config.routing.fallback || 'direct';
    }

    // DNS upstream
    var dnsTable = document.getElementById('dns-upstream-table');
    if (dnsTable) {
        dnsTable.querySelectorAll('.dns-upstream-row').forEach(function(r) { r.parentNode.removeChild(r); });
        Object.keys((config.dns || {}).upstream || {}).forEach(function(n) {
            dnsTable.appendChild(self._makeDNSUpstreamRow(n, config.dns.upstream[n]));
        });
    }
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

- [ ] **Step 3: Syntax check**

```bash
/Users/yufan/.cache/tailscale-node/bin/node --check /tmp/luci-app-dae-split/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js && echo "OK"
```

- [ ] **Step 4: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(ui): _getFormData and _refreshForm handle groups[]

Bidirectional sync now includes the new group cards. Manual nodes are
read from self._config.node (kept in sync by the All Nodes tab) rather
than from a removed form section.

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 13: config.js — Save flow: silent background refresh + handleSaveApply

**Goal:** After `fs.write + hot_reload`, fire-and-forget the `refresh-all` background call so the next page load has fresh node cache.

**Files:**
- Modify: `luci-app-dae/htdocs/luci-static/resources/view/dae/config.js`

- [ ] **Step 1: Update `handleSaveApply`**

Replace the existing method:

```javascript
handleSaveApply: function(ev, mode) {
    var self = this;
    var text;
    if (self._activeTab === 'form') {
        try { text = self._parser.serialize(self._getFormData()); }
        catch(e) {
            ui.addNotification(null, E('p', _('Failed to serialize form: ') + e.message));
            return Promise.resolve();
        }
    } else if (self._activeTab === 'text') {
        text = document.getElementById('dae-raw-text').value;
    } else {
        // Saving while on All Nodes tab: serialize from in-memory _config
        try { text = self._parser.serialize(self._config); }
        catch(e) {
            ui.addNotification(null, E('p', _('Failed to serialize: ') + e.message));
            return Promise.resolve();
        }
    }

    return fs.write('/etc/dae/config.dae', text, 384)
        .then(function() {
            return L.resolveDefault(fs.exec_direct('/etc/init.d/dae', ['hot_reload']), null);
        })
        .then(function() {
            ui.addNotification(null, E('p', _('Configuration saved and dae reloaded.')));
            // Fire-and-forget: refresh node cache in background
            L.resolveDefault(fs.exec_direct('/usr/lib/luci-app-dae/list-nodes.sh', ['refresh-all']), null)
                .then(function() {
                    return self._loadNodesCache && self._loadNodesCache();
                })
                .catch(function() { /* silent */ });
        })
        .catch(function(e) {
            ui.addNotification(null, E('p', e.message));
        });
},
```

- [ ] **Step 2: Syntax check**

```bash
/Users/yufan/.cache/tailscale-node/bin/node --check /tmp/luci-app-dae-split/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
git commit -m "feat(ui): silent background node-cache refresh after save

handleSaveApply now also fires (and forgets) list-nodes.sh refresh-all
after dae hot_reload, so next-page-load shows fresh subscription nodes
without user action.

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 14: i18n strings for v2

**Goal:** Add all new i18n keys to `.pot` and `zh_Hans/.po`.

**Files:**
- Modify: `luci-app-dae/po/templates/dae.pot`
- Modify: `luci-app-dae/po/zh_Hans/dae.po`

- [ ] **Step 1: Append to `po/templates/dae.pot`**

```
#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "All Nodes"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Proxy Groups"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Group"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Delete Group"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Group name:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Use Subscriptions:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Use Manual Nodes:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "(no subscriptions defined)"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Exclude nodes whose name contains:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "(comma-separated)"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Policy:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Auto (fastest)"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Random"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Pin to one node"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Pinned node:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "-- choose --"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "(no nodes — fetch in All Nodes tab first)"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "manual"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Group \"%s\" deleted. Routing rules referencing it have been reset to direct."
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Refresh Subscription Nodes"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Filter by source:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "All sources"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Manual"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Protocol"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Server:Port"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Source"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "No nodes yet. Click \"Refresh Subscription Nodes\" or \"Add Manual Node\"."
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Manual Node"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Enter a name and the node URI:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Name:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "URI:"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Cancel"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Name must be letters/digits/underscore only"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "URI must start with scheme://"
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Fetching subscriptions… this may take a few seconds."
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Nodes refreshed."
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Refresh failed: "
msgstr ""

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Failed to serialize: "
msgstr ""
```

- [ ] **Step 2: Append to `po/zh_Hans/dae.po`**

Same keys, with translations:

```
#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "All Nodes"
msgstr "所有节点"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Proxy Groups"
msgstr "代理组"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Group"
msgstr "添加分流组"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Delete Group"
msgstr "删除此组"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Group name:"
msgstr "组名："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Use Subscriptions:"
msgstr "使用订阅："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Use Manual Nodes:"
msgstr "使用手动节点："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "(no subscriptions defined)"
msgstr "（还没有订阅）"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Exclude nodes whose name contains:"
msgstr "排除名字包含以下关键字的节点："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "(comma-separated)"
msgstr "（逗号分隔）"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Policy:"
msgstr "策略："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Auto (fastest)"
msgstr "自动选最快"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Random"
msgstr "随机"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Pin to one node"
msgstr "手动选一个节点"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Pinned node:"
msgstr "指定节点："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "-- choose --"
msgstr "-- 请选择 --"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "(no nodes — fetch in All Nodes tab first)"
msgstr "（暂无节点，请先去【所有节点】tab 点刷新）"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "manual"
msgstr "手动"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Group \"%s\" deleted. Routing rules referencing it have been reset to direct."
msgstr "组 \"%s\" 已删除。引用它的路由规则已重置为 direct。"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Refresh Subscription Nodes"
msgstr "刷新订阅节点"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Filter by source:"
msgstr "按来源筛选："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "All sources"
msgstr "全部"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Manual"
msgstr "手动"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Protocol"
msgstr "协议"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Server:Port"
msgstr "服务器:端口"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Source"
msgstr "来源"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "No nodes yet. Click \"Refresh Subscription Nodes\" or \"Add Manual Node\"."
msgstr "暂无节点。点【刷新订阅节点】或【+ 添加手动节点】。"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add Manual Node"
msgstr "+ 添加手动节点"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Enter a name and the node URI:"
msgstr "输入节点名称和 URI："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Name:"
msgstr "名称："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "URI:"
msgstr "URI："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Cancel"
msgstr "取消"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Add"
msgstr "添加"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Name must be letters/digits/underscore only"
msgstr "名称只允许字母、数字、下划线"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "URI must start with scheme://"
msgstr "URI 必须以 scheme:// 开头"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Fetching subscriptions… this may take a few seconds."
msgstr "正在拉取订阅…可能需要几秒钟。"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Nodes refreshed."
msgstr "节点已刷新。"

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Refresh failed: "
msgstr "刷新失败："

#: applications/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js
msgid "Failed to serialize: "
msgstr "序列化失败："
```

- [ ] **Step 3: Commit**

```bash
cd /tmp/luci-app-dae-split
git add luci-app-dae/po/templates/dae.pot luci-app-dae/po/zh_Hans/dae.po
git commit -m "i18n: v2 keys for groups, all-nodes tab, manual node modal

Co-Authored-By: bugwriter <noreply@wahlau.top>"
```

---

## Task 15: Final verification + push

**Goal:** Run all tests, build the ipk via GitHub workflow, install to router, smoke test the UI.

- [ ] **Step 1: Run parser tests one final time**

```bash
cd /tmp/luci-app-dae-split/luci-app-dae
/Users/yufan/.cache/tailscale-node/bin/node tests/parser.test.js 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 2: Run shell tests**

```bash
sh tests/list-nodes.test.sh 2>&1 | tail -5
```

Expected: `Passed: 5  Failed: 0`.

- [ ] **Step 3: Syntax check config.js**

```bash
/Users/yufan/.cache/tailscale-node/bin/node --check /tmp/luci-app-dae-split/luci-app-dae/htdocs/luci-static/resources/view/dae/config.js && echo "OK"
```

- [ ] **Step 4: Push everything to GitHub**

```bash
cd /tmp/luci-app-dae-split
git log --oneline -20
git push origin main
```

This triggers the build workflow.

- [ ] **Step 5: Wait for workflow to finish & download .ipk**

```bash
GH=/tmp/gh_2.81.0_macOS_arm64/bin/gh
$GH run list -R ysuolmai/luci-app-dae --limit 1
# wait until status=completed conclusion=success
rm -rf /tmp/dae-artifacts-v3
$GH run download -R ysuolmai/luci-app-dae -D /tmp/dae-artifacts-v3
ls -la /tmp/dae-artifacts-v3/luci-app-dae-ipk/
```

- [ ] **Step 6: Install to router**

```bash
ROUTER=172.28.1.224
KEY=~/.ssh/claude_agent_ed25519
scp -i $KEY -q /tmp/dae-artifacts-v3/luci-app-dae-ipk/*.ipk root@$ROUTER:/tmp/
ssh -i $KEY root@$ROUTER 'cd /tmp && opkg install --force-overwrite luci-app-dae_*.ipk luci-i18n-dae-zh-cn_*.ipk 2>&1' | tail -10
# Clear LuCI cache
ssh -i $KEY root@$ROUTER 'rm -f /tmp/luci-modulecache/* /tmp/luci-indexcache; /etc/init.d/rpcd reload'
```

(Note: `--force-overwrite` since list-nodes.sh is at a new path — the directory `/usr/lib/luci-app-dae/` is new.)

- [ ] **Step 7: Smoke test on router**

Manually open `http://172.28.1.224/cgi-bin/luci/admin/services/dae` and verify:

1. Three tabs at top with button styling: 表单模式 / 所有节点 / 文本模式
2. 表单模式: shows 订阅 / 代理组 / 路由规则 / DNS / 全局设置
3. 代理组: default `proxy` card visible with "使用订阅" / "排除..." / "策略" fields
4. 路由规则: default 3 rules + fallback → proxy
5. 所有节点: empty initially, "Refresh Subscription Nodes" button works after adding a subscription
6. 文本模式: shows current config text

If anything is wrong, file a follow-up. Otherwise this plan is complete.

---

## Self-review checklist (for the plan author, not a subagent)

Before kicking off implementation, the plan author should verify:

**Spec coverage:**
- Tab structure (3 tabs, cbi-button style) → Task 7 ✓
- Subscription section simplified → Task 8 ✓
- Manual node section removed → Task 8 ✓
- Proxy group card with filter/policy/namePin → Task 9 ✓
- Routing action from groups → Task 10 ✓
- All Nodes tab (view + manual CRUD) → Task 11 ✓
- /tmp/dae-nodes-cache.json + list-nodes.sh → Tasks 5, 11 ✓
- ACL grants → Task 6 ✓
- _getFormData / _refreshForm for new shape → Task 12 ✓
- Save flow with silent background refresh → Task 13 ✓
- DaeConfig.groups data model + ensureDefaultGroup → Task 2 ✓
- _parseGroup with filter sub-syntax → Task 3 ✓
- _serializeFilter + group block emission → Task 4 ✓
- i18n updates → Task 14 ✓
- PKG_VERSION bump → Task 1 ✓
- Final ipk install + smoke test → Task 15 ✓

**Method name consistency:**
- `_makeActionSelect` used in Tasks 9, 10
- `_buildGroupSection`, `_makeGroupCard`, `_buildPinRow`, `_allKnownNodeNames` consistent in Tasks 9, 11
- `_onGroupRenamed`, `_onGroupDeleted`, `_refreshRoutingActionOptions` consistent in Tasks 9, 10
- `_buildNodesPane`, `_refreshNodes`, `_loadNodesCache`, `_renderNodesTable`, `_addManualNode`, `_refreshSubscriptionNodes`, `_renderFilterOptions` consistent in Tasks 7, 11
- `_getFormData`, `_refreshForm` consistent in Task 12

**No placeholders:** Every step has a code block where code is required.

---
