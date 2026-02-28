import React from "react";
import { useCurrentFrame, interpolate, spring, useVideoConfig } from "remotion";

interface IntroProps {
  title: string;
}

export const Intro: React.FC<IntroProps> = ({ title }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const titleScale = spring({
    frame: frame - 8,
    fps,
    config: { stiffness: 180, damping: 22 },
    from: 0.8,
    to: 1.0,
  });

  const titleOpacity = interpolate(frame, [8, 16], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const subtitleOpacity = interpolate(frame, [20, 30], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const subtitleY = interpolate(frame, [20, 32], [12, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        background: "#0a0b14",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 20,
      }}
    >
      {/* Accent line */}
      <div
        style={{
          width: 64,
          height: 3,
          background: "linear-gradient(90deg, #4B9EFF, #a78bfa)",
          borderRadius: 2,
          opacity: subtitleOpacity,
          marginBottom: 8,
        }}
      />

      {/* Title */}
      <div
        style={{
          opacity: titleOpacity,
          transform: `scale(${titleScale})`,
          textAlign: "center",
          padding: "0 48px",
        }}
      >
        <span
          style={{
            color: "#ffffff",
            fontSize: 52,
            fontWeight: 800,
            lineHeight: 1.2,
            fontFamily: "sans-serif",
            letterSpacing: "-0.5px",
          }}
        >
          {title}
        </span>
      </div>

      {/* Subtitle */}
      <div
        style={{
          opacity: subtitleOpacity,
          transform: `translateY(${subtitleY}px)`,
        }}
      >
        <span
          style={{
            color: "#a78bfa",
            fontSize: 22,
            fontWeight: 500,
            fontFamily: "sans-serif",
            letterSpacing: "2px",
            textTransform: "uppercase",
          }}
        >
          Watch till the end
        </span>
      </div>
    </div>
  );
};
