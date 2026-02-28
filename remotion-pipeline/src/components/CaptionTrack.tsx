import React from "react";
import { useCurrentFrame, useVideoConfig, spring, interpolate } from "remotion";
import type { Word } from "../types";

interface CaptionTrackProps {
  words: Word[];
  isVertical: boolean;
}

const WINDOW = 5; // words shown at once

function getWindowStart(words: Word[], activeIdx: number): number {
  if (activeIdx < 0) return 0;
  const ideal = activeIdx - Math.floor(WINDOW / 2);
  return Math.max(0, Math.min(ideal, words.length - WINDOW));
}

interface WordItemProps {
  text: string;
  isActive: boolean;
  isPast: boolean;
  wordEntryFrame: number; // local frame (relative to sequence start) when word starts
  fps: number;
}

const WordItem: React.FC<WordItemProps> = ({ text, isActive, isPast, wordEntryFrame, fps }) => {
  const frame = useCurrentFrame(); // local frame inside <Sequence>
  const framesSinceEntry = Math.max(0, frame - wordEntryFrame);

  const scale = isActive
    ? spring({
        frame: framesSinceEntry,
        fps,
        config: { stiffness: 200, damping: 20 },
        from: 0.98,
        to: 1.05,
      })
    : spring({
        frame: framesSinceEntry,
        fps,
        config: { stiffness: 200, damping: 20 },
        from: 0.75,
        to: 1.0,
      });

  const opacity = interpolate(framesSinceEntry, [0, 4], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const rotateX = interpolate(framesSinceEntry, [0, 6], [8, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const color = isActive ? "#FFE234" : isPast ? "rgba(255,255,255,0.7)" : "rgba(255,255,255,0.9)";
  const textShadow = isActive
    ? "0 3px 12px rgba(0,0,0,0.95), 0 0 20px rgba(255,226,52,0.4)"
    : "0 3px 12px rgba(0,0,0,0.95)";

  return (
    <span
      style={{
        display: "inline-block",
        transform: `scale(${scale}) perspective(400px) rotateX(${rotateX}deg)`,
        opacity: isPast ? 0.7 : opacity,
        color,
        textShadow,
        marginRight: "0.28em",
        transition: "color 0.1s ease",
        fontWeight: 800,
      }}
    >
      {text}
    </span>
  );
};

export const CaptionTrack: React.FC<CaptionTrackProps> = ({ words, isVertical }) => {
  // CaptionTrack is rendered inside <Sequence from={INTRO_DURATION}>.
  // useCurrentFrame() returns LOCAL frames — 0 = first frame of the video section.
  // Word timestamps from Deepgram are also 0-based (relative to trimmed.mp4 start).
  // No intro offset needed here.
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  if (words.length === 0) return null;

  const currentTimeSec = frame / fps;

  // Find active word index
  let activeIdx = -1;
  for (let i = 0; i < words.length; i++) {
    if (currentTimeSec >= words[i].start && currentTimeSec <= words[i].end) {
      activeIdx = i;
      break;
    }
    // Between words — keep the most recent word highlighted
    if (i < words.length - 1 && currentTimeSec > words[i].end && currentTimeSec < words[i + 1].start) {
      activeIdx = i;
      break;
    }
  }

  const windowStart = getWindowStart(words, activeIdx);
  const windowWords = words.slice(windowStart, windowStart + WINDOW);

  // Slight fade at window boundary transitions
  const windowFade = interpolate(frame % (fps * 2), [0, 4], [0.85, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const fontSize = isVertical ? 56 : 44;
  const bottomPos = isVertical ? "22%" : "10%";

  return (
    <div
      style={{
        position: "absolute",
        bottom: bottomPos,
        left: "50%",
        transform: "translateX(-50%)",
        width: "82%",
        textAlign: "center",
        fontFamily: "'Arial Black', 'Impact', sans-serif",
        fontSize,
        lineHeight: 1.3,
        opacity: windowFade,
        zIndex: 50,
      }}
    >
      {windowWords.map((w, i) => {
        const globalIdx = windowStart + i;
        const isActive = globalIdx === activeIdx;
        const isPast = globalIdx < activeIdx;
        // wordEntryFrame is local — just word.start * fps
        const wordEntryFrame = Math.round(w.start * fps);

        return (
          <WordItem
            key={globalIdx}
            text={w.word}
            isActive={isActive}
            isPast={isPast}
            wordEntryFrame={wordEntryFrame}
            fps={fps}
          />
        );
      })}
    </div>
  );
};
