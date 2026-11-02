const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var frame = new sketch.Group.Frame({
    parent: doc.pages[0],
    name: 'Finite Labs Logo',
    frame: { x: 7040, y: -357, width: 1920, height: 455 },
    background: { enabled: true, color: '#ffffffff', includedInExport: false },
  });
  var logo = sketch.createLayerFromData(__FINITE_LABS_LOGO_SVG__, 'svg');
  logo.parent = frame;
  logo.name = 'Finite Labs Logo';
  var scale = 455 / logo.frame.height;
  var width = logo.frame.width * scale;
  logo.frame = { x: (1920 - width) / 2, y: 0, width: width, height: 455 };
  frame.exportFormats = [{ fileFormat: 'png', size: '1x' }];
  console.log(JSON.stringify({ ok: true, id: frame.id, logo: logo.frame }));
}
