const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var page = sketch.Page.getSymbolsPage(doc);
  var svg = [
    '<svg xmlns="http://www.w3.org/2000/svg" width="201.5" height="201.5" viewBox="0 0 201.5 201.5">',
    '<g fill="none" stroke="#007aff" stroke-width="1">',
    '<rect x="0.5" y="0.5" width="200.5" height="200.5" rx="51"/>',
    '<rect x="13.4" y="13.4" width="174.7" height="174.7"/>',
    '<circle cx="100.75" cy="100.75" r="86.95"/>',
    '<circle cx="100.75" cy="100.75" r="53.15"/>',
    '<circle cx="100.75" cy="100.75" r="37.4"/>',
    '<path d="M63 0V201.5M100.75 0V201.5M138.5 0V201.5M0 63H201.5M0 100.75H201.5M0 138.5H201.5"/>',
    '<path d="M13.4 13.4L188.1 188.1M188.1 13.4L13.4 188.1"/>',
    '</g></svg>',
  ].join('');
  var frame = new sketch.Group.Frame({
    parent: page,
    name: 'Tile Grid',
    frame: { x: 6419, y: -468, width: 201.5, height: 201.5 },
    background: { enabled: false },
  });
  var lines = sketch.createLayerFromData(svg, 'svg');
  lines.parent = frame;
  lines.name = 'Grid';
  lines.frame = { x: 0, y: 0, width: 201.5, height: 201.5 };
  var master = sketch.SymbolMaster.fromFrame(frame);
  console.log(JSON.stringify({ ok: true, id: master.id, symbolId: master.symbolId, children: lines.layers ? lines.layers.length : 0 }));
}
