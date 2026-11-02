const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var page = sketch.Page.getSymbolsPage(doc);
  var frame = new sketch.Group.Frame({
    parent: page,
    name: 'Icon White',
    frame: { x: 6172, y: -468, width: 200, height: 200 },
    background: { enabled: false },
  });
  new sketch.ShapePath({
    parent: frame,
    name: 'Brand Mark (replace)',
    shapeType: sketch.ShapePath.ShapeType.Oval,
    frame: { x: 0, y: 0, width: 200, height: 200 },
    style: { fills: [{ fillType: sketch.Style.FillType.Color, color: '#ffffff', enabled: true }], borders: [] },
  });
  var master = sketch.SymbolMaster.fromFrame(frame);
  console.log(JSON.stringify({ ok: true, id: master.id, symbolId: master.symbolId, name: master.name }));
}
