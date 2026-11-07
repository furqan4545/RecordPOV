import { createHash } from 'node:crypto';

export const QUALITY_VERSION = 2;
export const MAX_VIDEO_LONG_SIDE = 3840;
export const MAX_VIDEO_SHORT_SIDE = 2160;
export const MAX_VIDEO_FPS = 60;
export const MAX_H264_LEVEL = 52;
export const QUALITY_FORMAT_SORT = 'res:2160,fps:60,vcodec:h264,acodec:aac';

export function mediaSourceID(sourceURL: string): string {
  return createHash('sha256').update(`roast-quality-v2:${sourceURL}`).digest('hex').slice(0, 24);
}
