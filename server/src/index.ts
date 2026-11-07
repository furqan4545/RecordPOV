import { loadConfig } from "./config.js";
import { createDownloader } from "./downloader.js";
import { MediaStore } from "./store.js";
import { createApp } from "./app.js";
import { YouTubeBroker } from "./youtube-broker.js";

// Node's optional env-file support keeps deployment configuration explicit.
try { process.loadEnvFile(".env"); } catch (error) {
  if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
}
const config = loadConfig();
const store = new MediaStore(config, createDownloader(config));
await store.initialize();
const youtube = config.youtubeIPCPath ? new YouTubeBroker(config, config.youtubeIPCPath) : undefined;
const server = createApp(config, store, youtube);
server.listen(config.port, config.host, () => {
  console.log(`Roast media server: http://${config.host}:${config.port}`);
  console.log("Public links only. Imported source files expire automatically.");
  if (config.host !== "127.0.0.1" && config.host !== "localhost" && !config.apiToken) {
    console.log("Development access: set API_TOKEN before exposing this server outside your trusted network.");
  }
});
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    store.dispose();
    youtube?.dispose();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
