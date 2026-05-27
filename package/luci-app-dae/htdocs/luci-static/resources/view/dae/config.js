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
