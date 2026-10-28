// Scheda Livelli del pannello: piani dell'edificio.
(function () {
  var state = { levels: [], current: null };

  function $(id) { return document.getElementById(id); }
  function esc(s) { return BIM.esc(s); }

  function read() {
    var out = [];
    var items = document.querySelectorAll('#l_list .level');
    for (var i = 0; i < items.length; i++) {
      var r = items[i];
      out.push({
        id: r.getAttribute('data-id'),
        name: r.querySelector('.name').value,
        elevation: r.querySelector('.elev').value.replace(',', '.'),
        height: r.querySelector('.height').value.replace(',', '.')
      });
    }
    return out;
  }

  function button(act, label, title, cls) {
    return '<button class="small act' + (cls ? ' ' + cls : '') + '" data-act="' + act + '" title="' + esc(title) + '">' + label + '</button>';
  }

  BIM.levels = {
    saved: function () { BIM.flash($('l_save'), 'Salvati ✓'); },
    render: function (data) {
      state = data;
      var html = '';
      data.levels.slice().reverse().forEach(function (l) {
        var cur = l.id === data.current;
        html += '<div class="level' + (cur ? ' current' : '') + '" data-id="' + esc(l.id) + '">' +
          '<div class="level-head">' +
          '<button class="icon ghost act" data-act="set_current" title="Imposta come livello corrente">' + (cur ? '●' : '○') + '</button>' +
          '<input class="name" value="' + esc(l.name) + '">' +
          '<span class="tag" title="Elementi sul livello">' + l.count + ' el.</span>' +
          '<button class="small plan act" data-act="plan_view" title="Crea una scena con la vista in pianta del livello">' +
          BIM.icon('plan') + 'Vista in pianta</button></div>' +
          '<div class="grid2">' +
          BIM.ui.field('Quota (m)', '<div class="unit"><input class="elev num" value="' + BIM.num(l.elevation, 3) + '"><span>m</span></div>') +
          BIM.ui.field('Altezza (m)', '<div class="unit"><input class="height num" value="' + BIM.num(l.height, 3) + '"><span>m</span></div>') +
          '</div><div class="level-actions">' +
          button('select', 'Seleziona', 'Seleziona gli elementi del livello') +
          button('isolate', 'Isola', 'Mostra solo questo livello') +
          button('assign', 'Assegna', 'Assegna la selezione a questo livello') +
          button('delete', 'Elimina', 'Elimina il livello', 'ghost danger') +
          '</div></div>';
      });
      html += '<div class="toolbar"><button class="small plan" id="l_view3d" title="Toglie la sezione e torna alla vista ' +
        'assonometrica (scena Vista 3D)">' + BIM.icon('cube') + 'Vista 3D</button>' +
        '<button class="small" id="l_showAll">Mostra tutti i livelli</button></div>';
      $('l_list').innerHTML = html;
      $('l_showAll').addEventListener('click', function () { BIM.call('levels_show_all'); });
      $('l_view3d').addEventListener('click', function () { BIM.call('levels_view_3d'); });
    }
  };

  $('l_list').addEventListener('click', function (ev) {
    var b = ev.target.closest('button.act');
    if (!b) return;
    var id = b.closest('.level').getAttribute('data-id');
    var act = b.getAttribute('data-act');
    if (act === 'delete' && !confirm('Eliminare il livello? Gli elementi resteranno senza livello.')) return;
    BIM.call('levels_' + act, { id: id });
  });
  $('l_add').addEventListener('click', function () { BIM.call('levels_add', { levels: read() }); });
  $('l_save').addEventListener('click', function () {
    BIM.call('levels_save', { levels: read(), move: $('l_move').checked });
  });
})();
