// Run INSIDE the resolver container after installing the firewall.
// TCP handshakes only; no payload or credentials sent to blocked destinations.
import assert from 'node:assert/strict';
import net from 'node:net';
import {lookup} from 'node:dns/promises';

const gateway = process.env.PROBE_GATEWAY ?? '172.30.83.1';
const checks = [
  ['gateway', gateway, 80, false],
  ['private10', '10.0.0.1', 80, false],
  ['private192', '192.168.0.1', 443, false],
  ['metadata', '169.254.169.254', 80, false],
  ['publicHTTPS', '1.1.1.1', 443, true],
];
await lookup('www.youtube.com');
console.log('Public DNS: OK');
for (const [name, host, port, expected] of checks) {
  const connected = await new Promise(resolve => {
    const socket = net.createConnection({host, port});
    const finish = result => {socket.destroy(); resolve(result);};
    socket.setTimeout(2000, () => finish(false));
    socket.once('connect', () => finish(true));
    socket.once('error', () => finish(false));
  });
  assert.equal(connected, expected, `${name}: unexpected connection result`);
  console.log(`${name}: ${connected ? 'connected' : 'blocked/unavailable'}`);
}
console.log('Check host firewall counters too: connection refusal alone cannot prove a firewall rule.');
