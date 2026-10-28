// Pannello unico di BIMSketch: intestazione, schede e barra delle azioni.
// Le schede (panel_properties.js, panel_types.js, panel_levels.js) si
// registrano come BIM.<scheda> e ricevono i dati da Ruby con BIM.<scheda>.render.
(function () {
  var ICONS = {
    logo: '<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/>',
    refresh: '<path d="M21 12a9 9 0 1 1-2.6-6.4"/><polyline points="21 3 21 9 15 9"/>',
    doc: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><polyline points="14 3 14 8 19 8"/><line x1="9" y1="13" x2="15" y2="13"/><line x1="9" y1="17" x2="15" y2="17"/>',
    layers: '<rect x="3" y="4" width="18" height="4" rx="1"/><rect x="3" y="10" width="18" height="4" rx="1"/><rect x="3" y="16" width="18" height="4" rx="1"/>',
    levels: '<rect x="3" y="3" width="18" height="18" rx="2"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="3" y1="15" x2="21" y2="15"/>',
    check: '<polyline points="20 6 9 17 4 12"/>',
    assign: '<path d="M12 5v14"/><path d="M5 12h14"/><circle cx="12" cy="12" r="9"/>',
    plus: '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
    table: '<rect x="3" y="4" width="18" height="16" rx="2"/><line x1="3" y1="10" x2="21" y2="10"/><line x1="9" y1="10" x2="9" y2="20"/>',
    shield: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><polyline points="9 12 11 14 15 10"/>',
    export: '<path d="M12 3v12"/><polyline points="7 8 12 3 17 8"/><path d="M5 15v4a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4"/>',
    copy: '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/>',
    cube: '<path d="M12 2l9 5v10l-9 5-9-5V7z"/><path d="M12 22V12"/><path d="M21 7l-9 5-9-5"/>',
    plan: '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 12h7v9"/><path d="M14 3v6h7"/>',
    edit: '<line x1="4" y1="7" x2="20" y2="7"/><line x1="4" y1="12" x2="20" y2="12"/><line x1="4" y1="17" x2="14" y2="17"/>'
  };

  BIM.icon = function (name) {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
      'stroke-linejoin="round">' + (ICONS[name] || '') + '</svg>';
  };

  BIM.fillIcons = function (root) {
    var nodes = (root || document).querySelectorAll('[data-icon]');
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].getAttribute('data-icon-done') === '1') continue;
      nodes[i].insertAdjacentHTML('afterbegin', BIM.icon(nodes[i].getAttribute('data-icon')));
      nodes[i].setAttribute('data-icon-done', '1');
    }
  };

  // Elementi grafici comuni alle schede.
  BIM.ui = {
    options: function (list, selected, blank) {
      var html = blank !== undefined ? '<option value="">' + BIM.esc(blank) + '</option>' : '';
      list.forEach(function (o) {
        html += '<option value="' + BIM.esc(o.value) + '"' + (String(o.value) === String(selected) ? ' selected' : '') +
          '>' + BIM.esc(o.label) + '</option>';
      });
      return html;
    },
    field: function (label, control, cls) {
      return '<div class="field' + (cls ? ' ' + cls : '') + '"><label>' + BIM.esc(label) + '</label>' + control + '</div>';
    },
    card: function (title, right, body, id) {
      return '<div class="card"' + (id ? ' id="' + id + '"' : '') + '><div class="card-head"><span class="card-title">' +
        BIM.esc(title) + '</span>' + (right || '') + '</div>' + body + '</div>';
    },
    // Barra degli strati in proporzione allo spessore.
    layerBar: function (layers, colors, ends) {
      var total = layers.reduce(function (s, l) { return s + (Number(l.thickness) || 0); }, 0) || 1;
      var html = ends ? '<div class="layer-ends"><span>' + BIM.esc(ends[0]) + '</span><span>' + BIM.esc(ends[1]) + '</span></div>' : '';
      html += '<div class="layer-bar">';
      layers.forEach(function (l) {
        var pct = (Number(l.thickness) || 0) / total * 100;
        var c = colors[l.function] || colors.other || '#aaaaaa';
        var dark = l.function === 'structure';
        var label = pct > 14 ? BIM.esc(l.name) + ' ' + BIM.num(l.thickness * 100, 1).replace(/,0$/, '') : '';
        html += '<div class="' + (dark ? 'dark' : '') + '" style="width:' + pct + '%;background:' + c + '" title="' +
          BIM.esc(l.name + ' · ' + l.material + ' · ' + BIM.num(l.thickness * 100, 1) + ' cm') + '">' + label + '</div>';
      });
      return html + '</div>';
    }
  };

  BIM.LAYER_COLORS = { structure: '#be6e50', insulation: '#f4d66e', finish: '#e7e2d6', other: '#aaaaaa' };

  var current = 'properties';

  function select(tab) {
    current = tab;
    document.querySelectorAll('.tab').forEach(function (b) {
      b.className = 'tab' + (b.getAttribute('data-tab') === tab ? ' sel' : '');
    });
    ['properties', 'types', 'levels'].forEach(function (t) {
      BIM.$('tab-' + t).className = 'tab-pane' + (t === tab ? ' sel' : '');
      BIM.$('actions-' + t).className = 'actions' + (t === tab ? ' sel' : '');
    });
  }

  BIM.panel = {
    tab: function (tab) { select(tab); },
    current: function () { return current; },
    header: function (d) {
      BIM.$('version').textContent = 'v' + d.version + ' · IFC4';
      var s = BIM.$('selection');
      s.textContent = d.selection;
      s.className = 'selection' + (d.active ? ' active' : '');
    },
    // Passa a un'altra scheda (chiede i dati a Ruby).
    go: function (tab, extra) {
      var data = { tab: tab };
      Object.keys(extra || {}).forEach(function (k) { data[k] = extra[k]; });
      select(tab);
      BIM.call('tab', data);
    },
    status: function (text) {
      var el = BIM.$('status');
      el.textContent = text || '';
      el.className = 'toast' + (text ? ' on' : '');
      if (text) setTimeout(function () { if (el.textContent === text) el.className = 'toast'; }, 2000);
    }
  };

  // Pulsante con conferma temporanea ("Salvato ✓").
  BIM.flash = function (button, text) {
    var label = button && button.querySelector('span:last-child');
    if (!label) return;
    var old = label.textContent;
    label.textContent = text;
    setTimeout(function () { label.textContent = old; }, 1200);
  };

  document.addEventListener('DOMContentLoaded', function () {
    BIM.fillIcons();
    select('properties');
    document.querySelector('.tabs').addEventListener('click', function (ev) {
      var b = ev.target.closest('.tab');
      if (!b) return;
      var tab = b.getAttribute('data-tab');
      if (tab === current) return;
      if (BIM[current] && BIM[current].canLeave && !BIM[current].canLeave()) return;
      BIM.panel.go(tab);
    });
    BIM.$('refreshAll').addEventListener('click', function () { BIM.call('refresh'); });
    BIM.$('openSchedule').addEventListener('click', function () { BIM.call('schedule'); });
    BIM.$('openChecker').addEventListener('click', function () { BIM.call('checker'); });
    BIM.$('exportIfc').addEventListener('click', function () { BIM.call('export_ifc'); });
  });
})();
