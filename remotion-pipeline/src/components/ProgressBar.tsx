import React from "react";
import { useCurrentFrame, useVideoConfig } from "remotion";

export const ProgressBar: React.FC = () => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();

  const progress = (frame / durationInFrames) * 100;

  return (
    <div
      style={{
        position: "absolute",
        top: 0,
        left: 0,
        right: 0,
        height: 4,
        background: "rgba(255,255,255,0.08)",
        zIndex: 100,
      }}
    >
      <div
        style={{
          height: "100%",
          width: `${progress}%`,
          background: "linear-gradient(90deg, #4B9EFF, #a78bfa)",
          boxShadow: "0 0 6px rgba(75,158,255,0.7), 0 2px 8px rgba(167,139,250,0.5)",
          borderRadius: "0 2px 2px 0",
          transition: "width 0.05s linear",
        }}
      />
    </div>
  );
};
