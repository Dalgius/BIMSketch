// Scheda Stratigrafie del pannello: librerie delle tipologie di muri e solai.
(function () {
  var ui = BIM.ui;
  var state = { kind: 'wall', types: [], usage: {}, functions: {}, rsi: 0.13, rse: 0.04, selected: 0 };
  var current = 0;
  var snapshot = '[]';
  var WORDS = { wall: ['muro', 'muri'], slab: ['solaio', 'solai'] };
  var NOTES = {
    wall: 'Gli strati sono elencati dalla faccia esterna (primo strato) a quella interna; "strati invertiti" li ' +
      'percorre al contrario rispetto al verso di disegno. Salvando, i muri che usano una tipologia modificata ' +
      'vengono ricostruiti. U secondo UNI EN ISO 6946 (Rsi 0,13 e Rse 0,04 m²K/W, flusso orizzontale), quando ' +
      'tutti gli strati hanno la conduttività λ.',
    slab: 'Gli strati sono elencati dall\'estradosso (pavimento o manto) all\'intradosso. Assegnando una tipologia ' +
      'la faccia superiore del solaio resta alla sua quota e lo spessore cresce verso il basso. U secondo UNI EN ' +
      'ISO 6946 con flusso verso il basso (Rsi 0,17) per i solai e verso l\'alto (Rsi 0,10) per le coperture; i ' +
      'solai controterra richiedono la UNI EN ISO 13370.'
  };

  function $(id) { return document.getElementById(id); }
  function esc(s) { return BIM.esc(s); }

  function num(v) {
    if (v === null || v === undefined || v === '') return null;
    var n = parseFloat(String(v).replace(',', '.'));
    return isNaN(n) ? null : n;
  }
  function thickness(t) { return t.layers.reduce(function (s, l) { return s + (num(l.thickness) || 0); }, 0); }
  function uValue(t) {
    if (!t.layers.length) return null;
    var r = state.rsi + state.rse;
    for (var i = 0; i < t.layers.length; i++) {
      var lam = num(t.layers[i].lambda), d = num(t.layers[i].thickness);
      if (!lam || lam <= 0 || d === null) return null;
      r += d / lam;
    }
    return 1 / r;
  }
  function nextId() {
    var ids = state.types.map(function (t) { return t.id; }), i = 1;
    var prefix = state.kind === 'slab' ? 'ST' : 'WT';
    while (ids.indexOf(prefix + i) >= 0) i++;
    return prefix + i;
  }

  function drawList() {
    var html = '';
    state.types.forEach(function (t, i) {
      var used = state.usage[t.id] || 0;
      html += '<div class="item' + (i === current ? ' sel' : '') + '" data-i="' + i + '"><span>' + esc(t.name) + '</span><small>' +
        BIM.num(thickness(t) * 100, 1) + ' cm' + (used ? ' · ' + used + ' ' + WORDS[state.kind][1] : '') + '</small></div>';
    });
    $('t_list').innerHTML = html || '<span class="muted">Nessuna tipologia.</span>';
  }

  function fnOptions(sel) {
    return Object.keys(state.functions).map(function (k) {
      return '<option value="' + k + '"' + (k === sel ? ' selected' : '') + '>' + esc(state.functions[k]) + '</option>';
    }).join('');
  }

  function drawEditor() {
    var t = state.types[current];
    if (!t) { $('t_editor').innerHTML = '<div class="empty">Crea una tipologia con "+ Nuova".</div>'; return; }
    var html = '<div class="card-head"><span class="card-title">Strati</span><span id="t_result" class="small-text"></span></div>' +
      ui.field('Nome', '<input id="t_name" value="' + esc(t.name) + '">') + '<div id="t_bar"></div><div style="height:8px"></div>';
    t.layers.forEach(function (l, i) {
      var color = BIM.LAYER_COLORS[l.function] || BIM.LAYER_COLORS.other;
      html += '<div class="layer" data-i="' + i + '">' +
        '<div class="grid-l1"><span class="swatch" style="background:' + color + '"></span>' +
        '<input data-k="name" placeholder="Strato" value="' + esc(l.name) + '">' +
        '<input data-k="material" placeholder="Materiale" value="' + esc(l.material) + '"></div>' +
        '<div class="grid-l2">' +
        '<label><span class="mini">Spessore (cm)</span><input data-k="thickness" class="num" value="' + BIM.num((num(l.thickness) || 0) * 100, 2) + '"></label>' +
        '<label><span class="mini">λ (W/mK)</span><input data-k="lambda" class="num" value="' +
          (l.lambda === null || l.lambda === undefined ? '' : BIM.num(l.lambda, 3)) + '"></label>' +
        '<label><span class="mini">Funzione</span><select data-k="function">' + fnOptions(l.function) + '</select></label>' +
        '<span style="white-space:nowrap"><button class="small ghost" data-act="up" title="Sposta su">↑</button>' +
        '<button class="small ghost" data-act="down" title="Sposta giù">↓</button>' +
        '<button class="small ghost danger" data-act="del" title="Elimina">×</button></span></div></div>';
    });
    html += '<div class="toolbar" style="margin-bottom:0;justify-content:space-between"><button class="small" id="t_addLayer">+ Aggiungi strato</button>' +
      (state.kind === 'wall' ? '<label class="check small-text"><input type="checkbox" id="t_flipped">assegna con strati invertiti</label>' : '') +
      '</div>';
    $('t_editor').innerHTML = html;
    drawResult();
  }

  function drawResult() {
    var t = state.types[current];
    if (!t) return;
    var u = uValue(t);
    $('t_result').innerHTML = '<b>' + BIM.num(thickness(t) * 100, 1) + ' cm</b> · U = ' +
      (u === null ? '— (manca λ)' : '<b>' + BIM.num(u, 3) + '</b> W/m²K');
    var ends = state.kind === 'slab' ? ['Estradosso', 'Intradosso'] : ['Esterno', 'Interno'];
    $('t_bar').innerHTML = t.layers.length ? ui.layerBar(t.layers.map(function (l) {
      return { name: l.name, material: l.material, function: l.function, thickness: num(l.thickness) || 0 };
    }), BIM.LAYER_COLORS, ends) : '';
  }

  function readEditor() {
    var t = state.types[current];
    if (!t) return;
    var name = $('t_name');
    if (name) t.name = name.value;
    var rows = document.querySelectorAll('#t_editor .layer');
    for (var i = 0; i < rows.length; i++) {
      var l = t.layers[Number(rows[i].getAttribute('data-i'))];
      rows[i].querySelectorAll('[data-k]').forEach(function (f) {
        var k = f.getAttribute('data-k');
        if (k === 'thickness') { var cm = num(f.value); l.thickness = cm === null ? 0 : cm / 100; }
        else if (k === 'lambda') l.lambda = num(f.value);
        else l[k] = f.value;
      });
    }
  }

  function dirty() {
    readEditor();
    return JSON.stringify(state.types) !== snapshot;
  }

  function drawChrome() {
    var w = WORDS[state.kind] || WORDS.wall;
    document.querySelectorAll('#t_kinds button').forEach(function (b) {
      b.className = b.getAttribute('data-kind') === state.kind ? 'sel' : '';
    });
    $('t_title').textContent = state.kind === 'slab' ? 'Tipologie di solaio' : 'Tipologie di muro';
    $('t_note').textContent = NOTES[state.kind] || NOTES.wall;
    var a = $('t_assign').querySelector('span:last-child');
    a.textContent = 'Assegna a ' + state.selected + ' ' + (state.selected === 1 ? w[0] : w[1]);
    $('t_assign').disabled = !state.selected;
  }

  BIM.types = {
    render: function (d) {
      var id = state.kind === d.kind && state.types[current] && state.types[current].id;
      state = d;
      snapshot = JSON.stringify(d.types);
      var idx = state.types.map(function (t) { return t.id; }).indexOf(id);
      current = idx >= 0 ? idx : 0;
      drawChrome();
      drawList();
      drawEditor();
    },
    selection: function (count) {
      state.selected = count;
      drawChrome();
    },
    saved: function () {
      snapshot = JSON.stringify(state.types);
      BIM.flash($('t_save'), 'Salvata ✓');
    },
    canLeave: function () {
      return !dirty() || confirm('Le modifiche non salvate alle stratigrafie andranno perse. Continuare?');
    }
  };

  $('t_kinds').addEventListener('click', function (ev) {
    var k = ev.target.getAttribute('data-kind');
    if (!k || k === state.kind) return;
    if (!BIM.types.canLeave()) return;
    BIM.call('types_kind', { kind: k });
  });
  $('t_list').addEventListener('click', function (ev) {
    var it = ev.target.closest('.item');
    if (!it) return;
    readEditor();
    current = Number(it.getAttribute('data-i'));
    drawList();
    drawEditor();
  });
  $('t_editor').addEventListener('input', function () { readEditor(); drawResult(); drawList(); });
  $('t_editor').addEventListener('change', function (ev) {
    if (ev.target.getAttribute('data-k') === 'function') { readEditor(); drawEditor(); }
  });
  $('t_editor').addEventListener('click', function (ev) {
    var t = state.types[current];
    if (ev.target.id === 't_addLayer') {
      readEditor();
      t.layers.push({ name: '', material: '', thickness: 0.05, lambda: null, function: 'other' });
      drawEditor();
      return;
    }
    var act = ev.target.getAttribute('data-act');
    if (!act) return;
    readEditor();
    var i = Number(ev.target.closest('.layer').getAttribute('data-i'));
    if (act === 'del') t.layers.splice(i, 1);
    if (act === 'up' && i > 0) t.layers.splice(i - 1, 0, t.layers.splice(i, 1)[0]);
    if (act === 'down' && i < t.layers.length - 1) t.layers.splice(i + 1, 0, t.layers.splice(i, 1)[0]);
    drawEditor();
    drawList();
  });
  $('t_new').addEventListener('click', function () {
    readEditor();
    state.types.push({ id: nextId(), name: 'Nuova tipologia',
      layers: state.kind === 'slab'
        ? [{ name: 'Soletta', material: 'Calcestruzzo armato', thickness: 0.20, lambda: 2.3, function: 'structure' }]
        : [{ name: 'Muratura', material: 'Laterizio', thickness: 0.25, lambda: 0.4, function: 'structure' }] });
    current = state.types.length - 1;
    drawList();
    drawEditor();
  });
  $('t_dup').addEventListener('click', function () {
    readEditor();
    var t = state.types[current];
    if (!t) return;
    var copy = JSON.parse(JSON.stringify(t));
    copy.id = nextId();
    copy.name = t.name + ' (copia)';
    state.types.push(copy);
    current = state.types.length - 1;
    drawList();
    drawEditor();
  });
  $('t_del').addEventListener('click', function () {
    var t = state.types[current];
    if (!t) return;
    var used = state.usage[t.id] || 0;
    if (!confirm('Eliminare la tipologia "' + t.name + '"?' + (used ? '\n' + used + ' ' + WORDS[state.kind][1] +
      ' torneranno a un unico strato.' : ''))) return;
    state.types.splice(current, 1);
    current = 0;
    drawList();
    drawEditor();
  });
  $('t_save').addEventListener('click', function () {
    readEditor();
    BIM.call('types_save', { types: state.types });
  });
  $('t_assign').addEventListener('click', function () {
    readEditor();
    var t = state.types[current];
    if (!t) return;
    var fl = $('t_flipped');
    var flipped = state.kind === 'wall' && fl && fl.checked;
    if (JSON.stringify(state.types) !== snapshot) BIM.call('types_save', { types: state.types });
    BIM.call('types_assign', { id: t.id, flipped: flipped });
  });
})();
