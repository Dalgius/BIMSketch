// Scheda Proprietà del pannello: dati BIM della selezione.
(function () {
  var root = BIM.$('tab-properties');
  var ui = BIM.ui;
  var state = null;

  function $(id) { return document.getElementById(id); }
  function esc(s) { return BIM.esc(s); }

  function typeByKey(key) {
    for (var i = 0; i < state.types.length; i++) if (state.types[i].key === key) return state.types[i];
    return null;
  }
  function typeOptions() {
    return state.types.map(function (t) { return { value: t.key, label: t.label + ' (' + t.ifc + ')' }; });
  }
  function levelOptions() {
    return state.levels.map(function (l) { return { value: l.id, label: l.name }; });
  }
  function predefinedOptions(key) {
    var t = typeByKey(key);
    return t ? t.predefined.map(function (p) { return { value: p, label: p }; }) : [];
  }
  function yesNo(selected, blank) {
    return ui.options([{ value: 'true', label: 'Sì' }, { value: 'false', label: 'No' }], selected, blank);
  }
  function typeList(list) {
    return (list || []).map(function (t) { return { value: t.id, label: t.name + (t.summary ? ' (' + t.summary + ')' : '') }; });
  }
  function editButton(kind) {
    return '<button class="icon" data-types="' + kind + '" title="Apri le stratigrafie">' + BIM.icon('edit') + '</button>';
  }

  // Tipologia (ObjectType): per muri e solai è la stratigrafia, per porte e
  // finestre la tipologia della libreria, per gli altri elementi un testo.
  function objectTypeField(e) {
    if (e.wall) {
      return ui.field('Tipologia (stratigrafia)', '<div class="with-btn"><select id="f_wall_type_id">' +
        ui.options(typeList(e.wall.types), e.wall.type_id, '(nessuna: muro unico)') + '</select>' + editButton('wall') + '</div>');
    }
    if (e.slab) {
      return ui.field('Tipologia (stratigrafia)', '<div class="with-btn"><select id="f_slab_type_id">' +
        ui.options(typeList(e.slab.types), e.slab.type_id, '(nessuna: solaio unico)') + '</select>' + editButton('slab') + '</div>');
    }
    if (e.opening) {
      return ui.field('Tipologia', '<select id="f_opening_type_id" title="Cambiando tipologia l\'apertura prende le sue dimensioni (stesso centro nel muro)">' +
        (e.opening.type_id ? '' : '<option value="(invariato)">(invariato)</option>') +
        ui.options(typeList(e.opening.types), e.opening.type_id) + '</select>');
    }
    return ui.field('Tipologia (ObjectType)', '<input id="f_object_type" placeholder="es. Muratura laterizio 30 cm" value="' +
      esc(e.object_type) + '">');
  }

  function identityCard(e) {
    var t = typeByKey(e.type) || {};
    var body = '<div class="grid2">' +
      ui.field('Categoria IFC', '<select id="f_type">' + ui.options(typeOptions(), e.type) + '</select>') +
      ui.field('Tipo predefinito', '<select id="f_predefined">' + ui.options(predefinedOptions(e.type), e.predefined) + '</select>') +
      '</div>' +
      ui.field('Nome elemento', '<input id="f_name" value="' + esc(e.name) + '">') +
      objectTypeField(e) +
      '<div class="grid2">' +
      ui.field('Livello', '<select id="f_level">' + ui.options(levelOptions(), e.level, '(automatico)') + '</select>') +
      ui.field('Materiale BIM', '<input id="f_material" placeholder="' + esc(e.sketchup_material) + '" value="' + esc(e.material) + '">') +
      '</div>' +
      ui.field('IFC GlobalId', '<div class="with-btn"><input readonly class="mono" id="f_guid" value="' + esc(e.guid) + '">' +
        '<button class="icon" id="copyGuid" title="Copia">' + BIM.icon('copy') + '</button></div>');
    return ui.card('Identità e classificazione IFC', '<span class="tag">' + esc(t.ifc || '') + '</span>', body);
  }

  // Altezza di muri e pilastri: numerica o automatica (segue il livello).
  function dimsCard(dims, multi) {
    if (!dims) return '';
    var body;
    if (multi) {
      body = '<div class="grid2">' +
        ui.field('Altezza segue il livello', '<select id="f_auto_height">' +
          ui.options([{ value: 'true', label: 'Sì' }, { value: 'false', label: 'No (valore fisso)' }], '', '(invariato)') + '</select>') +
        ui.field('Altezza (m)', '<input id="f_height" class="num" placeholder="(invariato)">') + '</div>';
      return ui.card('Dimensioni e vincolo quota', '', body);
    }
    body = '<label class="callout"><input type="checkbox" id="f_auto_height"' + (dims.auto ? ' checked' : '') + '>' +
      '<div><b>Altezza segue il livello</b><span>L\'altezza si aggiorna automaticamente quando cambia l\'altezza del livello' +
      (dims.top_offset > 0 ? ', fermandosi ' + BIM.num(dims.top_offset * 100, 1) + ' cm sotto (solaio superiore)' : '') +
      '.</span></div></label>' +
      '<div class="grid2">' +
      ui.field('Altezza (m)', '<div class="unit"><input id="f_height" class="num" value="' + BIM.num(dims.height, 3) + '"' +
        (dims.auto ? ' disabled' : '') + '><span>m</span></div>') + '<div></div></div>';
    return ui.card('Dimensioni e vincolo quota', dims.auto ? '<span class="ok-text">Vincolato al livello</span>' : '', body);
  }

  // Stratigrafia di muro o solaio: barra degli strati, tabella e trasmittanza.
  function layersCard(x, kind) {
    var right = kind === 'wall' ? '<label class="check small-text"><input type="checkbox" id="f_wall_flipped"' +
      (x.flipped ? ' checked' : '') + '>Strati invertiti</label>' : '';
    var what = kind === 'wall' ? 'Muro' : 'Solaio';
    if (!x.layers.length) {
      return ui.card('Stratigrafia', right, '<div class="muted">' + what + ' senza stratigrafia (spessore ' +
        BIM.num(x.thickness, 1) + ' cm): sceglila in Tipologia.</div>');
    }
    var ends = kind === 'wall' ? ['Esterno (primo strato)', 'Interno'] : ['Estradosso', 'Intradosso'];
    var body = ui.layerBar(x.layers, BIM.LAYER_COLORS, ends) +
      '<table style="margin-top:8px"><thead><tr><th>Strato</th><th>Materiale</th><th class="num">cm</th><th class="num">λ</th></tr></thead><tbody>';
    x.layers.forEach(function (l) {
      body += '<tr><td><span class="swatch" style="background:' + (BIM.LAYER_COLORS[l.function] || BIM.LAYER_COLORS.other) + '"></span>' +
        esc(l.name) + '</td><td>' + esc(l.material) + '</td><td class="num">' + BIM.num(l.thickness * 100, 1) +
        '</td><td class="num">' + (l.lambda ? BIM.num(l.lambda, 3) : '—') + '</td></tr>';
    });
    body += '</tbody></table><div class="summary-line"><span>Spessore ' + BIM.num(x.thickness, 1) + ' cm</span><span>U = ' +
      (x.u === null || x.u === undefined ? '— (manca λ)' : BIM.num(x.u, 3) + ' W/m²K') + '</span></div>';
    return ui.card('Stratigrafia', right, body);
  }

  // Geometria della scala: alzate, pedata e larghezza modificabili; alzata
  // e regola di Blondel calcolate mentre si scrive.
  var STAIR_PROPS = ['NumberOfRiser', 'NumberOfTreads', 'RiserHeight', 'TreadLength'];

  function stairCard(st) {
    var body = '<div class="grid2">' +
      ui.field('Numero di alzate', '<input id="f_stair_risers" class="num" data-orig="' + st.risers + '" value="' + st.risers + '">') +
      ui.field('Pedata (cm)', '<div class="unit"><input id="f_stair_tread" class="num" data-orig="' + BIM.num(st.tread * 100, 1) +
        '" value="' + BIM.num(st.tread * 100, 1) + '"><span>cm</span></div>') +
      ui.field('Larghezza (cm)', '<div class="unit"><input id="f_stair_width" class="num" data-orig="' + BIM.num(st.width * 100, 1) +
        '" value="' + BIM.num(st.width * 100, 1) + '"><span>cm</span></div>') +
      ui.field('Dislivello (m)', '<input readonly class="num" value="' + BIM.num(st.height, 3) + '">') +
      '</div><div class="summary-line" id="stairInfo"></div>' +
      '<p class="muted small-text" style="margin:6px 0 0">Applica ricostruisce la scala dalla stessa linea di partenza' +
      (st.hole ? ' e adegua il vano nel solaio superiore' : '') + '. Regola di Blondel consigliata: 2a + p tra 62 e 64 cm.</p>';
    return ui.card('Scala', '<span class="tag">' + st.risers + ' alzate</span>', body);
  }

  function updateStairInfo() {
    var info = $('stairInfo');
    if (!info) return;
    var st = state.element.stair;
    var n = parseInt($('f_stair_risers').value, 10);
    var p = parseFloat($('f_stair_tread').value.replace(',', '.'));
    if (!(n >= 2) || !(p > 0)) { info.textContent = 'Valori non validi'; return; }
    var a = st.height / n * 100;
    var b = 2 * a + p;
    info.innerHTML = '<span>Alzata ' + BIM.num(a, 1) + ' cm · lunghezza ' + BIM.num((n - 1) * p / 100, 2) + ' m</span>' +
      '<span' + (b < 62 || b > 64 ? ' class="error-text"' : '') + '>2a + p = ' + BIM.num(b, 1) + ' cm</span>';
  }

  // Fori del solaio (scale, cavedi).
  function holesCard(x) {
    if (!x.holes) return '';
    return ui.card('Fori nel solaio', '<span class="tag">' + x.holes + '</span>',
      '<div class="with-btn"><span class="muted small-text">' + (x.holes === 1 ? '1 foro' : x.holes + ' fori') +
      ' (scale, cavedi). Aggiungili con lo strumento Foro nel solaio o con la Scala.</span>' +
      '<button class="small danger" id="clearHoles">Togli i fori</button></div>');
  }

  // Posizione di porta o finestra nel muro (inviata solo se modificata).
  function openingCard(o) {
    if (o.left === undefined) return '';
    var depths = (o.depths || []).map(function (d) { return { value: d.id, label: d.name }; });
    var body = ui.field('Serramento nello spessore', '<select id="f_opening_depth">' + ui.options(depths, o.depth) + '</select>') +
      '<div class="grid2">' +
      ui.field('Distanza dall\'inizio (m)', '<div class="unit"><input id="f_opening_left" class="num" data-orig="' +
        BIM.num(o.left, 3) + '" value="' + BIM.num(o.left, 3) + '"><span>m</span></div>') +
      (o.sill !== undefined ? ui.field('Davanzale (m)', '<div class="unit"><input id="f_opening_sill" class="num" data-orig="' +
        BIM.num(o.sill, 3) + '" value="' + BIM.num(o.sill, 3) + '"><span>m</span></div>') : '<div></div>') +
      '</div><p class="muted small-text" style="margin:8px 0 0">Distanza del lato sinistro del vano dall\'inizio del muro, nel ' +
      'verso di disegno. A filo il telaio si appoggia al nucleo del muro (la faccia esterna è quella del primo strato). ' +
      'Puoi spostare l\'apertura anche con lo Sposta di SketchUp.</p>';
    return ui.card('Posizione nel muro', '', body);
  }

  function propControl(p, value, multi) {
    var id = 'prop_' + p.name;
    // Valori della scala: derivano dalla geometria (riquadro Scala).
    if (!multi && state.element && state.element.stair && STAIR_PROPS.indexOf(p.name) >= 0) {
      var v0 = value === null || value === undefined ? '' : String(value).replace('.', ',');
      return '<input readonly id="' + id + '" data-prop="' + p.name + '" title="Dalla geometria della scala" value="' +
        esc(v0) + '">';
    }
    if (p.type === 'boolean') {
      var v = value === true ? 'true' : value === false ? 'false' : '';
      return '<select id="' + id + '" data-prop="' + p.name + '">' + yesNo(v, multi ? '(invariato)' : '—') + '</select>';
    }
    var shown = value === null || value === undefined ? '' : String(value);
    if (['real', 'length', 'area', 'thermal'].indexOf(p.type) >= 0) shown = shown.replace('.', ',');
    return '<input id="' + id + '" data-prop="' + p.name + '" value="' + esc(shown) + '"' +
      (multi ? ' placeholder="(invariato)"' : '') + '>';
  }

  function propsCard(typeKey, props, multi) {
    var t = typeByKey(typeKey);
    if (!t || !t.props.length) return '';
    var body = '<div class="grid2">';
    t.props.forEach(function (p) { body += ui.field(p.label, propControl(p, props ? props[p.name] : null, multi)); });
    return ui.card(t.pset || 'Proprietà', '', body + '</div>');
  }

  function customRow(k, v) {
    return '<tr><td><input class="ck" placeholder="Nome" value="' + esc(k) + '"></td>' +
      '<td><input class="cv" placeholder="Valore" value="' + esc(v) + '"></td>' +
      '<td style="width:1%"><button class="small ghost del" title="Elimina">×</button></td></tr>';
  }

  function customCard(custom) {
    var body = '<table id="custom"><tbody>';
    Object.keys(custom || {}).forEach(function (k) { body += customRow(k, custom[k]); });
    body += '</tbody></table><div class="toolbar" style="margin-bottom:0"><button class="small" id="addCustom">+ Aggiungi proprietà</button></div>';
    return ui.card('Proprietà personalizzate', '', body);
  }

  function quantitiesCard(e) {
    var body = '';
    if (!e.quantities.length) body = '<span class="muted">Nessuna quantità calcolabile.</span>';
    else {
      body = '<div class="kv">';
      e.quantities.forEach(function (q) { body += '<span>' + esc(q.label) + '</span><span>' + esc(q.value + ' ' + q.unit) + '</span>'; });
      body += '</div>';
    }
    if (!e.solid) body += '<div class="notice">L\'elemento non è un solido chiuso: il volume netto non è disponibile.</div>';
    return ui.card('Quantità', '', body);
  }

  function classifyCard() {
    if (!state.unclassified) return '';
    return ui.card('Classifica', '', '<p style="margin:0 0 8px"><b>' + state.unclassified +
      ' oggetti non classificati</b> nella selezione.</p><div class="with-btn"><select id="classType">' +
      ui.options(typeOptions(), 'wall') + '</select><button class="primary" id="classify">Classifica</button></div>');
  }

  function renderSingle() {
    var e = state.element;
    var html = identityCard(e) + dimsCard(e.dims, false);
    if (e.wall) html += layersCard(e.wall, 'wall');
    if (e.slab) html += layersCard(e.slab, 'slab') + holesCard(e.slab);
    if (e.opening) html += openingCard(e.opening);
    if (e.stair) html += stairCard(e.stair);
    html += '<div id="propsBox">' + propsCard(e.type, e.props, false) + '</div>';
    html += customCard(e.custom) + quantitiesCard(e) + classifyCard();
    html += '<div class="toolbar"><button class="small ghost danger" id="declassify">Rimuovi classificazione BIM</button></div>';
    return html;
  }

  function renderMulti() {
    var summary = state.summary.map(function (s) { return esc(s.label) + ' <b>' + s.count + '</b>'; }).join(' · ');
    var objectType = state.opening_types
      ? ui.field('Tipologia', '<select id="f_opening_type_id"><option value="(invariato)">(invariato)</option>' +
          ui.options(typeList(state.opening_types), '') + '</select>')
      : ui.field('Tipologia (ObjectType)', '<input id="f_object_type" placeholder="(invariato)">');
    var body = '<p class="muted" style="margin:0 0 8px">' + summary + '</p><div class="grid2">' +
      ui.field('Categoria IFC', '<select id="f_type">' + ui.options(typeOptions(), '', '(invariato)') + '</select>') +
      ui.field('Livello', '<select id="f_level">' + ui.options(levelOptions(), '', '(invariato)') + '</select>') +
      '</div>' + objectType +
      ui.field('Materiale BIM', '<input id="f_material" placeholder="(invariato)">');
    var html = ui.card('Modifica comune · ' + state.count + ' elementi', '', body);
    html += dimsCard(state.dims ? {} : null, true);
    if (state.wall_types) {
      html += ui.card('Stratigrafia dei muri', '', '<div class="grid2">' +
        ui.field('Stratigrafia', '<select id="f_wall_type_id"><option value="(invariato)">(invariato)</option>' +
          '<option value="">(nessuna: muro unico)</option>' + ui.options(typeList(state.wall_types), '') + '</select>') +
        ui.field('Strati invertiti', '<select id="f_wall_flipped">' + yesNo('', '(invariato)') + '</select>') + '</div>');
    }
    if (state.slab_types) {
      html += ui.card('Stratigrafia dei solai', '', ui.field('Stratigrafia', '<select id="f_slab_type_id">' +
        '<option value="(invariato)">(invariato)</option><option value="">(nessuna: solaio unico)</option>' +
        ui.options(typeList(state.slab_types), '') + '</select>'));
    }
    html += '<div id="propsBox">' + (state.common_type ? propsCard(state.common_type, {}, true) : '') + '</div>';
    return html + classifyCard();
  }

  function renderNone() {
    var html = '<div class="card empty"><b>Nessun elemento BIM selezionato</b>Seleziona un elemento nel modello per vederne ' +
      'le proprietà, oppure disegna muri, solai, pilastri, travi, porte e finestre con gli strumenti BIMSketch.</div>';
    return html + classifyCard();
  }

  function collect() {
    var multi = state.mode === 'multi';
    var el = {};
    ['type', 'predefined', 'name', 'object_type', 'level', 'material'].forEach(function (k) {
      var f = $('f_' + k);
      if (f) el[k] = f.value;
    });
    var props = {};
    var nodes = root.querySelectorAll('[data-prop]');
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var v = n.value;
      if (n.tagName === 'SELECT') v = v === 'true' ? true : v === 'false' ? false : '';
      if (!(multi && v === '')) props[n.getAttribute('data-prop')] = v;
    }
    el.props = props;
    var wt = $('f_wall_type_id');
    if (wt) el.wall_type_id = wt.value;
    var fl = $('f_wall_flipped');
    if (fl) el.wall_flipped = fl.type === 'checkbox' ? fl.checked : fl.value;
    ['left', 'sill'].forEach(function (k) {
      var f = $('f_opening_' + k);
      if (f && f.value !== f.getAttribute('data-orig')) el['opening_' + k] = f.value;
    });
    ['risers', 'tread', 'width'].forEach(function (k) {
      var f = $('f_stair_' + k);
      if (f && f.value !== f.getAttribute('data-orig')) el['stair_' + k] = f.value;
    });
    var ot = $('f_opening_type_id');
    if (ot) el.opening_type_id = ot.value;
    var od = $('f_opening_depth');
    if (od) el.opening_depth = od.value;
    var st = $('f_slab_type_id');
    if (st) el.slab_type_id = st.value;
    var auto = $('f_auto_height');
    if (auto) {
      el.auto_height = auto.type === 'checkbox' ? auto.checked : auto.value;
      el.height = $('f_height').value;
    }
    if (!multi) {
      var custom = {};
      var rows = root.querySelectorAll('#custom tr');
      for (var j = 0; j < rows.length; j++) {
        var k = rows[j].querySelector('.ck').value.trim();
        if (k) custom[k] = rows[j].querySelector('.cv').value;
      }
      el.custom = custom;
    }
    return { mode: state.mode, element: el };
  }

  function bind() {
    var on = function (id, ev, fn) { var el = $(id); if (el) el.addEventListener(ev, fn); };
    on('declassify', 'click', function () {
      if (confirm('Rimuovere i dati BIM dall\'elemento?')) BIM.call('properties_declassify');
    });
    on('clearHoles', 'click', function () {
      if (confirm('Togliere tutti i fori dal solaio?')) BIM.call('properties_clear_holes');
    });
    on('classify', 'click', function () { BIM.call('properties_classify', { type: $('classType').value }); });
    on('copyGuid', 'click', function () {
      var f = $('f_guid');
      f.select();
      try { document.execCommand('copy'); BIM.panel.status('GlobalId copiato'); } catch (e) { /* niente appunti */ }
    });
    ['f_stair_risers', 'f_stair_tread'].forEach(function (id) { on(id, 'input', updateStairInfo); });
    updateStairInfo();
    on('f_auto_height', 'change', function () {
      var a = $('f_auto_height');
      if (a.type === 'checkbox') $('f_height').disabled = a.checked;
    });
    on('f_type', 'change', function () {
      var key = $('f_type').value;
      var box = $('propsBox');
      if (state.mode === 'single') {
        $('f_predefined').innerHTML = ui.options(predefinedOptions(key), '');
        if (box) box.innerHTML = propsCard(key, state.element.props, false);
      } else {
        var k = key || state.common_type;
        box.innerHTML = k ? propsCard(k, {}, true) : '';
      }
    });
    on('addCustom', 'click', function () {
      $('custom').querySelector('tbody').insertAdjacentHTML('beforeend', customRow('', ''));
    });
    var custom = $('custom');
    if (custom) custom.addEventListener('click', function (ev) {
      if (ev.target.classList.contains('del')) ev.target.closest('tr').remove();
    });
    root.querySelectorAll('[data-types]').forEach(function (b) {
      b.addEventListener('click', function () { BIM.panel.go('types', { kind: b.getAttribute('data-types') }); });
    });
  }

  BIM.properties = {
    render: function (data) {
      state = data;
      $('error').style.display = 'none';
      root.innerHTML = data.mode === 'single' ? renderSingle() : data.mode === 'multi' ? renderMulti() : renderNone();
      $('p_apply').disabled = data.mode === 'none';
      bind();
    },
    saved: function () {
      BIM.flash($('p_apply'), 'Applicato ✓');
    }
  };

  $('p_apply').addEventListener('click', function () { if (state && state.mode !== 'none') BIM.call('properties_save', collect()); });
  $('p_refresh').addEventListener('click', function () { BIM.call('refresh'); });
})();
