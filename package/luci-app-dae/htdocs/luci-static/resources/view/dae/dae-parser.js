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

        var preambleStr = preamble.join('\n');
        if (preambleStr.trim().length > 0)
            blocks['__preamble'] = preambleStr;

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
