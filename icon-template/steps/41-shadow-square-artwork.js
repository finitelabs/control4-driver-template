const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var group = sketch.find('#91AE36CC-885E-488A-956C-F2425B420D8B', doc)[0];
  var background = sketch.find('#495C4DB5-EB51-41DB-9DA2-AFB176ECBE77', doc)[0];
  var sample = sketch.find('#A590E3DD-011A-410D-9646-E717E083EA00', doc)[0];
  var master = doc.getSymbols().find(function (m) { return m.name === 'Icon White'; });
  var accent = doc.swatches.find(function (s) { return s.name === 'Brand/Accent'; });
  if (!group || !background || !sample || !master || !accent) {
    console.log(JSON.stringify({ ok: false, error: 'NOT_FOUND', group: !!group, background: !!background, sample: !!sample, master: !!master, accent: !!accent }));
  } else {
    background.style.fills[0].swatch = accent;
    var mark = master.createNewInstance();
    mark.parent = group;
    mark.name = 'Icon White';
    mark.frame = { x: 102, y: 102, width: 680, height: 680 };
    sample.remove();
    console.log(JSON.stringify({
      ok: true,
      layers: group.layers.map(function (l) { return { name: l.name, type: l.type, frame: l.frame }; }),
    }));
  }
}
