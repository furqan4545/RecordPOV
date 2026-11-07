import assert from 'node:assert/strict';
import { it } from 'node:test';
import { canCopyNativeVideo, canRemuxNative, type MediaProbe, type ProbeStream } from '../src/media-normalizer.js';

const video: ProbeStream = {
  codec_type: 'video', codec_name: 'h264', profile: 'High', level: 31, width: 1280, height: 720,
  pix_fmt: 'yuv420p', sample_aspect_ratio: '1:1', field_order: 'progressive', avg_frame_rate: '30000/1001', r_frame_rate: '30000/1001',
};
const audio: ProbeStream = { codec_type: 'audio', codec_name: 'aac', profile: 'LC', channels: 2, sample_rate: '48000', channel_layout: 'stereo' };
const source = (change: Partial<ProbeStream> = {}): MediaProbe => ({ format: { duration: '2' }, streams: [{ ...video, ...change }, audio] });

it('requires proven video compatibility rather than copying unknown, rotated, oversized or non-native pixels', () => {
  assert.ok(canRemuxNative(source()));
  for (const change of [
    { width: 4096, height: 2160 }, { width: 1279 }, { avg_frame_rate: '61/1' }, { r_frame_rate: '61/1' },
    { avg_frame_rate: '0/0' }, { sample_aspect_ratio: '4:3' }, { pix_fmt: 'yuv420p10le' }, { profile: 'High 10' },
    { profile: 'unknown' }, { field_order: 'tt' }, { level: 60 }, { tags: { rotate: '90' } },
    { side_data_list: [{ side_data_type: 'Display Matrix', rotation: 0, displaymatrix: '\n00000000: -65536 0 0\n00000001: 0 65536 0\n00000002: 0 0 1073741824\n' }] },
  ]) assert.equal(canCopyNativeVideo(source(change)), false, JSON.stringify(change));
  assert.equal(canCopyNativeVideo({ format: { duration: '2' }, streams: [{ codec_type: 'video', codec_name: 'h264', width: 1280, height: 720 }] }), false);
});

it('copies native 4K60 and portrait 4K without lowering raster or frame rate', () => {
  for (const [width, height] of [[3840, 2160], [2160, 3840]] as const) {
    assert.ok(canRemuxNative(source({ width, height, level: 52, avg_frame_rate: '60/1', r_frame_rate: '60/1' })));
  }
});

it('allows video-only copying while requiring AAC conversion for non-native audio', () => {
  for (const change of [{ codec_name: 'opus' }, { profile: 'HE-AAC' }, { channels: 6 }, { sample_rate: '96000' }]) {
    const probe: MediaProbe = { format: { duration: '2' }, streams: [video, { ...audio, ...change }] };
    assert.ok(canCopyNativeVideo(probe));
    assert.equal(canRemuxNative(probe), false);
  }
  assert.equal(canCopyNativeVideo({ format: { duration: '2' }, streams: [video, audio, audio] }), false);
});

it('infers square pixels only for absent-SAR genuine MP4 without contradictory display aspect', () => {
  const { sample_aspect_ratio: _sar, ...withoutSAR } = video;
  const probe: MediaProbe = { format: { duration: '2', format_name: 'mov,mp4,m4a,3gp,3g2,mj2', tags: { major_brand: 'isom' } }, streams: [withoutSAR] };
  assert.ok(canRemuxNative(probe));
  assert.ok(canRemuxNative({ ...probe, streams: [{ ...withoutSAR, display_aspect_ratio: '16:9' }] }));
  for (const rejected of [
    { ...probe, format: { duration: '2', format_name: 'matroska,webm' } },
    { ...probe, format: { ...probe.format, tags: { major_brand: 'qt  ' } } },
    { ...probe, format: { ...probe.format, tags: {} } },
    { ...probe, streams: [{ ...withoutSAR, display_aspect_ratio: '4:3' }] },
    { ...probe, streams: [{ ...withoutSAR, sample_aspect_ratio: '0:1' }] },
    { ...probe, streams: [{ ...withoutSAR, sample_aspect_ratio: '4:3' }] },
    { ...probe, streams: [{ ...withoutSAR, side_data_list: [{ side_data_type: 'Display Matrix', rotation: 0, displaymatrix: '\n00000000: -65536 0 0\n00000001: 0 65536 0\n00000002: 0 0 1073741824\n' }] }] },
  ]) assert.equal(canRemuxNative(rejected), false);
});
