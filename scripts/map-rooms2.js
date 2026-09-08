const { roomIdFor } = require('../pi-extension/dist/rooms.js');
const fs = require('fs');
const path = require('path');
const sessRoot = path.join(process.env.USERPROFILE, '.pi', 'agent', 'sessions');
const wanted = new Set(['Agq7sYHlSb_l', 'kayBNNVdkE4k', 'PYQld0n16yts', 'xmOGBN12dtYH', 'device']);
for (const d of fs.readdirSync(sessRoot)) {
  if (!d.startsWith('--')) continue;
  // --C--Users-Alessandro-source-pi-...--  → C:\Users\Alessandro\source\pi\...
  let inner = d.slice(2, -2); // strip leading -- and trailing --
  // first segment is drive letter + '' (e.g. 'C') — the original ':' became '-'
  const m = inner.match(/^([A-Za-z])(--|.)(.*)$/);
  if (!m) continue;
  const cwd = m[1] + ':\\' + m[3].replace(/-/g, '\\');
  try {
    const room = roomIdFor(cwd);
    if (wanted.has(room)) console.log(room.padEnd(16), '<=', cwd);
  } catch {}
}
// also try home itself
for (const extra of [process.env.USERPROFILE]) {
  try { console.log(roomIdFor(extra).padEnd(16), '<=', extra); } catch {}
}
