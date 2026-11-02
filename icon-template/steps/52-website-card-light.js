const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var tileStyle = doc.sharedLayerStyles.find(function (s) { return s.name === 'Tile/Accent'; });
  var gridMaster = doc.getSymbols().find(function (m) { return m.name === 'Tile Grid'; });
  var markMaster = doc.getSymbols().find(function (m) { return m.name === 'Icon White'; });
  var card = new sketch.Group.Frame({
    parent: doc.pages[0],
    name: 'Website Card - Light',
    frame: { x: 6400, y: -357, width: 220, height: 221 },
    background: { enabled: true, color: '#ffffffff', includedInExport: false },
  });
  var tile = new sketch.ShapePath({
    name: 'Background',
    shapeType: sketch.ShapePath.ShapeType.Rectangle,
    frame: { x: 0, y: 4.5, width: 201.5, height: 201.5 },
  });
  tile.sharedStyle = tileStyle;
  tile.style.corners.style = sketch.Style.CornerStyle.Smooth;
  tile.style.corners.radii = [51, 51, 51, 51];
  tile.style.corners.smoothing = 0.6;
  var grid = gridMaster.createNewInstance();
  grid.name = 'Grid (hide me)';
  grid.frame = { x: 0, y: 4.5, width: 201.5, height: 201.5 };
  grid.hidden = true;
  var mark = markMaster.createNewInstance();
  mark.name = 'Icon White';
  mark.frame = { x: 40, y: 44, width: 122, height: 122 };
  var icon = new sketch.Group({ parent: card, name: 'Icon', layers: [tile, grid, mark] });
  icon.adjustToFit();
  icon.frame = { x: 9 - tile.frame.x, y: 5.5 - tile.frame.y, width: icon.frame.width, height: icon.frame.height };
  card.exportFormats = [{ fileFormat: 'png', size: '1x' }];
  console.log(JSON.stringify({
    ok: true,
    id: card.id,
    icon: icon.frame,
    tileOnCard: { x: icon.frame.x + tile.frame.x, y: icon.frame.y + tile.frame.y },
    layers: icon.layers.map(function (l) { return { name: l.name, hidden: l.hidden, frame: l.frame }; }),
  }));
}
