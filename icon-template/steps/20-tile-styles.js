const sketch = require('sketch');
const doc = sketch.getDocuments().find(function (d) { return decodeURIComponent(d.path) === __DOCUMENT__; });
if (!doc) {
  console.log(JSON.stringify({ ok: false, error: 'NO_DOCUMENT' }));
} else {
  var accent = doc.swatches.find(function (s) { return s.name === 'Brand/Accent'; });
  var accentDark = doc.swatches.find(function (s) { return s.name === 'Brand/Accent Dark'; });
  var tiles = [
    { name: 'Tile/Accent', top: '#109eff', bottom: '#0e86d9' },
    { name: 'Tile/White', top: '#ffffff', bottom: '#f5f5f5' },
  ];
  tiles.forEach(function (t) {
    var style = new sketch.Style({
      fills: [{
        fillType: sketch.Style.FillType.Gradient,
        enabled: true,
        gradient: {
          gradientType: sketch.Style.GradientType.Linear,
          from: { x: 0.5, y: 0.5 },
          to: { x: 0.5, y: 0.99 },
          stops: [{ position: 0, color: t.top }, { position: 1, color: t.bottom }],
        },
      }],
      borders: [],
      shadows: [{ enabled: true, color: '#00000080', x: 0, y: 4, blur: 10, spread: -1 }],
    });
    style.corners.style = sketch.Style.CornerStyle.Smooth;
    style.corners.radii = [51, 51, 51, 51];
    style.corners.smoothing = 0.6;
    if (t.name === 'Tile/Accent') {
      style.fills[0].gradient.stops[0].swatch = accent;
      style.fills[0].gradient.stops[1].swatch = accentDark;
    }
    doc.sharedLayerStyles.push({ name: t.name, style: style });
  });
  doc.processPendingChanges();
  console.log(JSON.stringify({
    ok: true,
    styles: doc.sharedLayerStyles.map(function (s) {
      var stops = s.style.fills.length ? s.style.fills[0].gradient.stops : [];
      return {
        name: s.name,
        stops: stops.map(function (st) { return st.swatch ? st.swatch.name : st.color; }),
        corners: s.style.corners.radii,
      };
    }),
  }));
}
