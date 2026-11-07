// Synthetic yt-dlp metadata shaped like the measured platform responses.
// URLs are fake; only their hosts and shapes matter.

/** Instagram reel: VP9 video-only dash entries (fps/filesize unknown), HE-AAC audio, three opaque progressive MP4s, no duration. */
export function instagramReel() {
  const ig = (path: string) => `https://scontent.cdninstagram.com/${path}?signature=synthetic-instagram`;
  const dashVideo = (id: string, width: number, height: number, tbr: number) => ({
    format_id: `dash-${id}v`, ext: 'mp4', container: 'mp4_dash', protocol: 'https', url: ig(`${id}v.mp4`),
    vcodec: 'vp09.00.40.08.00.01.01.01.00', acodec: 'none', width, height, fps: null, filesize: null, tbr,
  });
  return {
    title: 'Synthetic reel', duration: null, acodec: 'mp4a.40.5', width: 1080, height: 1920, fps: null,
    http_headers: { 'User-Agent': 'Synthetic/1', Cookie: 'never-forward' },
    formats: [
      ...['1', '2', '3'].map(format_id => ({ format_id, ext: 'mp4', protocol: 'https', url: ig(`progressive-${format_id}.mp4`),
        vcodec: null, acodec: null, width: null, height: null })),
      dashVideo('540', 540, 960, 600), dashVideo('720', 720, 1280, 1200), dashVideo('1080', 1080, 1920, 2500),
      { format_id: 'dash-a', ext: 'm4a', container: 'm4a_dash', protocol: 'https', url: ig('a.m4a'),
        vcodec: 'none', acodec: 'mp4a.40.5', asr: 44100, audio_channels: 2, abr: 64 },
    ],
  };
}

const yt = (itag: string) => `https://rr1.googlevideo.com/videoplayback?itag=${itag}&signature=synthetic-youtube`;
const ytVideo = (itag: string, ext: string, vcodec: string, width: number, height: number, fps: number, tbr: number) => ({
  format_id: itag, ext, protocol: 'https', url: yt(itag), vcodec, acodec: 'none', width, height, fps, tbr, dynamic_range: 'SDR',
});
const ytAudio = (itag: string, ext: string, acodec: string, abr: number) => ({
  format_id: itag, ext, protocol: 'https', url: yt(itag), vcodec: 'none', acodec, abr, asr: 48000, audio_channels: 2, language: 'en',
});

/** YouTube 4K60: AV1 MP4 and VP9 WebM above 1080p; H.264 MP4 only up to 1080p60; AAC-LC itag 140. */
export function youtube4K() {
  return {
    title: 'Synthetic 4K', duration: 212, acodec: 'opus', language: 'en',
    formats: [
      ytAudio('140', 'm4a', 'mp4a.40.2', 129), ytAudio('251', 'webm', 'opus', 140),
      ytVideo('136', 'mp4', 'avc1.4d401f', 1280, 720, 30, 1500),
      ytVideo('298', 'mp4', 'avc1.4d4020', 1280, 720, 60, 3000),
      ytVideo('299', 'mp4', 'avc1.64002a', 1920, 1080, 60, 6000),
      ytVideo('303', 'webm', 'vp9', 1920, 1080, 60, 4500),
      ytVideo('399', 'mp4', 'av01.0.09M.08', 1920, 1080, 60, 3500),
      ytVideo('315', 'webm', 'vp9', 3840, 2160, 60, 25000),
      ytVideo('401', 'mp4', 'av01.0.13M.08', 3840, 2160, 60, 18000),
    ],
  };
}

/** YouTube 1080p60 where H.264 matches the best original tier. */
export function youtube1080() {
  const value = youtube4K();
  return { ...value, formats: value.formats.filter(f => !['315', '401'].includes(f.format_id)) };
}

/** X: H.264 + AAC-LC progressive MP4s on video.twimg.com plus an HLS entry that must be ignored. */
export function xH264() {
  const tw = (path: string) => `https://video.twimg.com/ext_tw_video/${path}?tag=synthetic-x`;
  return {
    title: 'Synthetic X', duration: 24.1, acodec: 'mp4a.40.2',
    formats: [
      { format_id: 'hls-2176', ext: 'mp4', protocol: 'm3u8_native', url: tw('pl/1080.m3u8'), manifest_url: tw('pl/master.m3u8'), vcodec: 'avc1.640028', acodec: 'mp4a.40.2', width: 1080, height: 1920, fps: 30, tbr: 2176 },
      { format_id: 'http-832', ext: 'mp4', protocol: 'https', url: tw('vid/480x852.mp4'), vcodec: 'avc1.4d401f', acodec: 'mp4a.40.2', width: 480, height: 852, fps: 30, tbr: 832 },
      { format_id: 'http-2176', ext: 'mp4', protocol: 'https', url: tw('vid/1080x1920.mp4'), vcodec: 'avc1.640028', acodec: 'mp4a.40.2', width: 1080, height: 1920, fps: 30, tbr: 2176 },
    ],
  };
}

/** X as yt-dlp really reports it: progressive mp4 files without codec strings, HLS-only codecs, audio renditions without acodec. */
export function xOpaque() {
  const tw = (path: string) => `https://video.twimg.com/amplify_video/1790637571455840256/${path}?tag=16`;
  return {
    title: 'Real-shaped X', duration: 15.488, vcodec: 'avc1.64001F', acodec: null, width: 728, height: 720,
    formats: [
      { format_id: 'hls-audio-128000-Audio', ext: 'mp4', protocol: 'm3u8_native', url: tw('pl/mp4a/128000/a.m3u8'), manifest_url: tw('pl/master.m3u8'), vcodec: 'none', acodec: null, tbr: 128 },
      { format_id: 'http-288', ext: 'mp4', protocol: 'https', url: tw('vid/avc1/272x270/a.mp4'), vcodec: null, acodec: null, width: 272, height: 270, tbr: 288 },
      { format_id: 'hls-191', ext: 'mp4', protocol: 'm3u8_native', url: tw('pl/avc1/272x270/a.m3u8'), manifest_url: tw('pl/master.m3u8'), vcodec: 'avc1.4D400D', acodec: 'none', width: 272, height: 270, tbr: 191.874 },
      { format_id: 'http-832', ext: 'mp4', protocol: 'https', url: tw('vid/avc1/364x360/a.mp4'), vcodec: null, acodec: null, width: 364, height: 360, tbr: 832 },
      { format_id: 'http-2176', ext: 'mp4', protocol: 'https', url: tw('vid/avc1/728x720/a.mp4'), vcodec: null, acodec: null, width: 728, height: 720, tbr: 2176 },
      { format_id: 'hls-716', ext: 'mp4', protocol: 'm3u8_native', url: tw('pl/avc1/728x720/a.m3u8'), manifest_url: tw('pl/master.m3u8'), vcodec: 'avc1.64001F', acodec: 'none', width: 728, height: 720, tbr: 716.185 },
    ],
  };
}

/** TikTok: HEVC (bytevc1) and H.264 muxed files at the same raster and frame rate. */
export function tiktokSameRaster() {
  const tt = (path: string) => `https://v16-webapp-prime.tiktok.com/video/${path}?signature=synthetic-tiktok`;
  return {
    title: 'Synthetic TikTok', duration: 15.2, acodec: 'aac',
    formats: [
      { format_id: 'h264_1080p', ext: 'mp4', protocol: 'https', url: tt('h264-1080.mp4'), vcodec: 'h264', acodec: 'aac', width: 1080, height: 1920, fps: 30, tbr: 2200, filesize: 4_000_000 },
      { format_id: 'bytevc1_1080p', ext: 'mp4', protocol: 'https', url: tt('hevc-1080.mp4'), vcodec: 'bytevc1', acodec: 'aac', width: 1080, height: 1920, fps: 30, tbr: 1800, filesize: 3_000_000 },
    ],
  };
}

/** TikTok: muxed HEVC (bytevc1) original at 1080p beside a 720p H.264 file. */
export function tiktokHEVC() {
  const tt = (path: string) => `https://v16-webapp-prime.tiktok.com/video/${path}?signature=synthetic-tiktok`;
  return {
    title: 'Synthetic TikTok', duration: 15.2, acodec: 'aac',
    formats: [
      { format_id: 'h264_540p', ext: 'mp4', protocol: 'https', url: tt('h264-720.mp4'), vcodec: 'h264', acodec: 'aac', width: 720, height: 1280, fps: 30, tbr: 1200, filesize: 2_000_000 },
      { format_id: 'bytevc1_1080p', ext: 'mp4', protocol: 'https', url: tt('hevc-1080.mp4'), vcodec: 'bytevc1', acodec: 'aac', width: 1080, height: 1920, fps: 30, tbr: 1800, filesize: 3_000_000 },
    ],
  };
}
