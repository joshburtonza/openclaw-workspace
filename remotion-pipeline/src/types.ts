export interface Word {
  word: string;
  start: number;
  end: number;
}

export interface Segment {
  start: number;
  end: number;
}

export interface TalkingHeadProps {
  videoSrc: string;    // absolute path to trimmed.mp4
  segments: Segment[]; // kept segments after silence removal
  words: Word[];       // word-level timestamps from Deepgram
  title: string;
  fps: number;
  width: number;       // 1080 (vertical) or 1920 (horizontal)
  height: number;      // 1920 (vertical) or 1080 (horizontal)
}
