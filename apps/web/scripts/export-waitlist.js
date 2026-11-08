import { writeFile } from 'node:fs/promises';
import { get, list } from '@vercel/blob';

const output = process.argv[2];
if (!output) throw new Error('Provide a private output path for the launch list.');

const subscribers = [];
let cursor;
do {
  const page = await list({ prefix: 'launch/v1/', cursor });
  for (const blob of page.blobs) {
    const item = await get(blob.pathname, { access: 'private', useCache: false });
    if (item?.statusCode !== 200) throw new Error('Could not read a launch signup.');
    const { email, consentAt } = await new Response(item.stream).json();
    subscribers.push({ email, consentAt });
  }
  cursor = page.hasMore ? page.cursor : undefined;
} while (cursor);

await writeFile(output, JSON.stringify(subscribers, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
console.log(`Exported ${subscribers.length} launch signups.`);
