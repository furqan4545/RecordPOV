import { createHash } from 'node:crypto';
import { put } from '@vercel/blob';

const emailPattern = /^[a-z0-9.!#$%&'*+/=?^_\x60{|}~-]{1,64}@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i;
const noStore = { 'Cache-Control': 'no-store' };

function result(request, outcome, status) {
  if (request.headers.get('accept')?.includes('application/json')) {
    return Response.json({ outcome }, { status, headers: noStore });
  }
  return new Response(null, {
    status: 303,
    headers: { ...noStore, Location: `/#waitlist-${outcome}` },
  });
}

export async function POST(request) {
  const origin = request.headers.get('origin');
  if (origin && origin !== new URL(request.url).origin) {
    return new Response(null, { status: 403, headers: noStore });
  }

  const contentType = request.headers.get('content-type')?.split(';')[0];
  if (contentType !== 'application/x-www-form-urlencoded') {
    return result(request, 'invalid', 415);
  }

  const body = await request.text();
  if (body.length > 2048) return result(request, 'invalid', 413);

  const fields = new URLSearchParams(body);
  const email = fields.get('email')?.trim().toLowerCase() ?? '';
  if (fields.get('company')) return result(request, 'joined', 200);
  if (email.length > 254 || !emailPattern.test(email)) return result(request, 'invalid', 400);

  const key = createHash('sha256').update(email).digest('hex');
  try {
    await put(`launch/v1/${key}.json`, JSON.stringify({ email, consentAt: new Date().toISOString() }), {
      access: 'private',
      addRandomSuffix: false,
      allowOverwrite: true,
      contentType: 'application/json',
    });
    return result(request, 'joined', 200);
  } catch {
    // Keep email addresses and storage credentials out of runtime logs.
    console.error('Could not save a launch signup.');
    return result(request, 'retry', 503);
  }
}
