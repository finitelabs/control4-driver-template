const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var cards = [
    { name: 'Driver Central Driver Card', width: 300, height: 300, backdrop: '#ffffffff', opaque: true, tile: 'Tile/Accent', mark: 'Icon White', x: 49, y: 23.5 },
    { name: 'Website Card - Light', width: 220, height: 221, backdrop: '#ffffffff', opaque: false, tile: 'Tile/Accent', mark: 'Icon White', x: 9, y: 5.5 },
    { name: 'Website Card - Dark', width: 220, height: 221, backdrop: '#343434ff', opaque: false, tile: 'Tile/White', mark: 'Icon', x: 9, y: 5.5 },
  ];
  var gridMaster = doc.getSymbols().find(function (m) { return m.name === 'Tile Grid'; });
  var built = cards.map(function (c, i) {
    var card = new sketch.Group.Frame({
      parent: doc.pages[0],
      name: c.name,
      frame: { x: 6000 + i * 400, y: -357, width: c.width, height: c.height },
      background: { enabled: true, color: c.backdrop, includedInExport: false },
    });
    if (c.opaque) {
      new sketch.ShapePath({
        parent: card,
        name: 'Background',
        shapeType: sketch.ShapePath.ShapeType.Rectangle,
        frame: { x: 0, y: 0, width: c.width, height: c.height },
        style: { fills: [{ fillType: sketch.Style.FillType.Color, color: c.backdrop, enabled: true }], borders: [] },
      });
    }
    var tile = new sketch.ShapePath({
      name: 'Background',
      shapeType: sketch.ShapePath.ShapeType.Rectangle,
      frame: { x: 0, y: 0, width: 201.5, height: 201.5 },
    });
    tile.sharedStyle = doc.sharedLayerStyles.find(function (s) { return s.name === c.tile; });
    tile.style.corners.style = sketch.Style.CornerStyle.Smooth;
    tile.style.corners.radii = [51, 51, 51, 51];
    tile.style.corners.smoothing = 0.6;
    var grid = gridMaster.createNewInstance();
    grid.name = 'Grid (hide me)';
    grid.frame = { x: 0, y: 0, width: 201.5, height: 201.5 };
    grid.hidden = true;
    var mark = doc.getSymbols().find(function (m) { return m.name === c.mark; }).createNewInstance();
    mark.name = c.mark;
    mark.frame = { x: 40, y: 39.5, width: 122, height: 122 };
    var icon = new sketch.Group({ parent: card, name: 'Icon', layers: [tile, grid, mark] });
    icon.adjustToFit();
    icon.frame = { x: c.x, y: c.y, width: icon.frame.width, height: icon.frame.height };
    card.exportFormats = [{ fileFormat: 'png', size: '1x' }];
    return { name: card.name, icon: icon.frame, gridHidden: grid.hidden };
  });
  console.log(JSON.stringify({ ok: true, cards: built }));
}
