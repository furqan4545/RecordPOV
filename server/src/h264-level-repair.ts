import { runCommand } from './process.js';

/**
 * Recalculate an overdeclared H.264 level without decoding or encoding samples.
 * The caller must first prove that level is the only video incompatibility and
 * then probe the output against the ordinary native-media policy. An automatic
 * level estimate is a trial, never permission to bypass that policy.
 */
export async function repairH264Level(
  inputPath: string, outputPath: string, ffmpeg: string, signal: AbortSignal,
): Promise<void> {
  await runCommand(ffmpeg, [
    '-nostdin', '-hide_banner', '-loglevel', 'error', '-protocol_whitelist', 'file,pipe', '-i', inputPath,
    '-map', '0:v:0', '-map', '0:a:0?', '-sn', '-dn', '-map_metadata', '-1', '-map_chapters', '-1',
    '-c', 'copy', '-bsf:v', 'h264_metadata=level=auto', '-movflags', '+faststart', outputPath,
  ], signal);
}
