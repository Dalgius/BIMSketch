// Utility comuni ai dialog BIMSketch (comunicazione con Ruby via window.sketchup).
var BIM = window.BIM || {};

BIM.call = function (name, data) {
  if (window.sketchup && typeof window.sketchup[name] === 'function') {
    window.sketchup[name](JSON.stringify(data || {}));
  } else {
    console.log('sketchup.' + name, data);
  }
};

BIM.esc = function (s) {
  return String(s === null || s === undefined ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
};

BIM.num = function (v, decimals) {
  if (v === null || v === undefined || v === '') return '';
  return Number(v).toFixed(decimals === undefined ? 2 : decimals).replace('.', ',');
};

BIM.$ = function (id) { return document.getElementById(id); };

BIM.error = function (message) {
  var el = BIM.$('error');
  if (el) { el.textContent = 'Errore: ' + message; el.style.display = 'block'; }
};

document.addEventListener('DOMContentLoaded', function () { BIM.call('ready'); });
