import { loadConfig } from './config.js';
import { createIdentity } from './auth.js';
import { createService } from './service.js';
import { createNodeServer } from './http.js';

process.umask(0o077);
const config = loadConfig();
const identity = await createIdentity(config);
const service = createService(config, identity);
const server = createNodeServer(config, service);
server.listen(config.port, config.host, () => console.log(`RecordPOV auth listening on ${config.host}:${config.port}`));
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => {
  server.close(() => { identity.close(); process.exit(0); });
  setTimeout(() => { server.closeAllConnections(); identity.close(); process.exit(0); }, 5000).unref();
});
