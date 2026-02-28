import React from "react";
import {
  AbsoluteFill,
  OffthreadVideo,
  Sequence,
  staticFile,
  useVideoConfig,
} from "remotion";
import type { TalkingHeadProps } from "./types";
import { Intro } from "./components/Intro";
import { CaptionTrack } from "./components/CaptionTrack";
import { ProgressBar } from "./components/ProgressBar";

const INTRO_DURATION = 60; // 2s at 30fps

export const TalkingHead: React.FC<TalkingHeadProps> = ({
  videoSrc,
  segments,
  words,
  title,
  fps,
  width,
  height,
}) => {
  const { durationInFrames } = useVideoConfig();
  const isVertical = height > width;

  // Calculate total video duration from segments
  const totalVideoSecs = segments.reduce(
    (sum, seg) => sum + (seg.end - seg.start),
    0
  );
  const totalVideoFrames = Math.ceil(totalVideoSecs * fps);

  return (
    <AbsoluteFill style={{ background: "#000" }}>
      {/* Intro card — first 60 frames */}
      <Sequence from={0} durationInFrames={INTRO_DURATION}>
        <Intro title={title} />
      </Sequence>

      {/* Main section — video + captions + progress */}
      <Sequence from={INTRO_DURATION} durationInFrames={totalVideoFrames}>
        <MainSection
          videoSrc={videoSrc ? staticFile(videoSrc) : ""}
          segments={segments}
          words={words}
          isVertical={isVertical}
          fps={fps}
        />
      </Sequence>

      {/* Progress bar over everything */}
      <ProgressBar />
    </AbsoluteFill>
  );
};

interface MainSectionProps {
  videoSrc: string;
  segments: { start: number; end: number }[];
  words: { word: string; start: number; end: number }[];
  isVertical: boolean;
  fps: number;
}

const MainSection: React.FC<MainSectionProps> = ({
  videoSrc,
  segments,
  words,
  isVertical,
  fps,
}) => {
  if (!videoSrc) {
    // Preview mode: show placeholder
    return (
      <AbsoluteFill
        style={{
          background: "#111",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
        }}
      >
        <span style={{ color: "#666", fontSize: 32, fontFamily: "sans-serif" }}>
          No video source
        </span>
      </AbsoluteFill>
    );
  }

  // Build video segments as a flat timeline
  // Each segment plays consecutively, seeked to its start time in the source
  let frameOffset = 0;
  const segmentSequences = segments.map((seg, i) => {
    const segDurationSecs = seg.end - seg.start;
    const segDurationFrames = Math.ceil(segDurationSecs * fps);
    const from = frameOffset;
    frameOffset += segDurationFrames;

    return (
      <Sequence key={i} from={from} durationInFrames={segDurationFrames}>
        <AbsoluteFill>
          <OffthreadVideo
            src={videoSrc}
            startFrom={Math.round(seg.start * fps)}
            style={{
              width: "100%",
              height: "100%",
              objectFit: "cover",
            }}
          />
        </AbsoluteFill>
      </Sequence>
    );
  });

  return (
    <AbsoluteFill>
      {/* Video segments */}
      {segmentSequences}

      {/* Captions overlay */}
      <CaptionTrack
        words={words}
        isVertical={isVertical}
      />
    </AbsoluteFill>
  );
};
