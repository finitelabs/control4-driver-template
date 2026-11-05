// Joins the parts of a message from lib/ui.lua. Returns the message on its last part, null before that.
var gUiParts = {};
function uiJoin(command, frame) {
  var m = /^(\d+):(\d+):(\d+):([\s\S]*)$/.exec(frame || '');
  if (!m) return null;
  var message = gUiParts[command];
  if (!message || message.id !== m[1]) message = gUiParts[command] = { id: m[1], got: 0, chunks: [] };
  message.chunks[m[2] - 1] = m[4];
  message.got++;
  if (message.got < Number(m[3])) return null;
  delete gUiParts[command];
  return JSON.parse(message.chunks.join(''));
}
