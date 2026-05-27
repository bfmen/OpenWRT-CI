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

    _buildDNSSection:          function() { return E('div'); },
    _buildGlobalSection:       function() { return E('div'); },

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
    _makeDNSUpstreamRow:       function()  { return E('tr'); },
    _makeDNSSelect:            function()  { return E('select'); },
    _getFormData:              function()  { return this._config || {}; },
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
