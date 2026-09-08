// Map room id -> cwd for all remote_pi worktrees (uses the same code the ext runs).
const { roomIdFor } = require('../pi-extension/dist/rooms.js');
const fs = require('fs');
const path = require('path');
const base = path.join(process.env.USERPROFILE, 'source', 'pi', 'packages');
const targets = ['remote_pi'];
for (const n of fs.readdirSync(base)) if (n.startsWith('remote_pi_')) targets.push(n);
for (const t of targets) {
  const cwd = path.join(base, t);
  try {
    console.log(roomIdFor(cwd).padEnd(16), cwd);
  } catch (e) {
    console.log('ERR'.padEnd(16), cwd, e.message);
  }
}
