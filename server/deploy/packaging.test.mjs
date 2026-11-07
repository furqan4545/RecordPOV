import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

const script = new URL('./egress-firewall.sh', import.meta.url);
const run = (env = {}) => execFileSync('bash', [fileURLToPath(script), 'render'], {
  env: {...process.env, ...env}, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
});

test('guard puts reply allowance before private denials and public-only ports', () => {
  const rules = run();
  assert(rules.indexOf('ESTABLISHED,RELATED') < rules.indexOf('-d 10.0.0.0/8'));
  for (const range of ['127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16']) {
    assert(rules.includes(`-d ${range} -j REJECT`));
  }
  assert(rules.includes('--dports 53,80,443 -j RETURN'));
  assert(rules.includes('-A RECORDPOV-HOST -j REJECT'));
  assert(rules.includes('-A RECORDPOV6-EGRESS -j REJECT'));
  assert(rules.includes('DOCKER-USER and INPUT, -i br-recordpov -s 172.30.83.2/32'));
  assert(!rules.includes('-F INPUT\n'));
  assert(!rules.includes('-F DOCKER-USER\n'));
});

test('guard rejects accidental host-wide bridge or public address configuration', () => {
  for (const env of [{RECORDPOV_BRIDGE: 'docker0'}, {RECORDPOV_ADDRESS: '1.1.1.1'},
    {RECORDPOV_SUBNET: '0.0.0.0/0'}, {RECORDPOV_ADDRESS: '172.30.83.0'}]) {
    assert.throws(() => run(env));
  }
  assert(run({RECORDPOV_ADDRESS: '172.30.83.4'}).includes('-s 172.30.83.4/32'));
});

test('runtime never auto-restarts before the guard and contains no admin secret', () => {
  const compose = readFileSync(new URL('./compose.yaml', import.meta.url), 'utf8');
  const unit = readFileSync(new URL('./recordpov.service', import.meta.url), 'utf8');
  assert.match(compose, /restart: "no"/);
  assert.match(compose, /127\.0\.0\.1:\$\{HOST_PORT/);
  assert.match(compose, /API_TOKEN: ""/);
  assert.match(unit, /PartOf=docker\.service/);
  assert(unit.indexOf('ExecStartPre=') < unit.indexOf('ExecStart='));
});
