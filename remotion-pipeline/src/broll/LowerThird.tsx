import React from "react";
import { useCurrentFrame, spring, interpolate, useVideoConfig } from "remotion";

interface LowerThirdProps {
  name: string;
  title: string;
  color?: string;
}

/**
 * Animated lower-third name plate.
 * White line slides in → name reveals out of it → title fades in below.
 */
export const LowerThird: React.FC<LowerThirdProps> = ({
  name,
  title,
  color = "#4B9EFF",
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Line slides in from left
  const lineProgress = spring({
    frame,
    fps,
    config: { stiffness: 200, damping: 24 },
    from: 0,
    to: 1,
  });

  // Name reveals after line (frame 10)
  const nameProgress = spring({
    frame: frame - 10,
    fps,
    config: { stiffness: 220, damping: 22 },
    from: 0,
    to: 1,
  });
  const nameOpacity = interpolate(frame - 10, [0, 8], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  // Title fades in after name (frame 20)
  const titleOpacity = interpolate(frame - 20, [0, 12], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const titleY = interpolate(
    spring({ frame: frame - 20, fps, config: { stiffness: 180, damping: 20 }, from: 0, to: 1 }),
    [0, 1],
    [8, 0]
  );

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        alignItems: "flex-end",
        padding: "0 0 6% 6%",
        fontFamily: "-apple-system, 'SF Pro Display', sans-serif",
      }}
    >
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {/* Coloured line */}
        <div
          style={{
            width: interpolate(lineProgress, [0, 1], [0, 180]),
            height: 3,
            background: color,
            borderRadius: 2,
            boxShadow: `0 0 12px ${color}88`,
          }}
        />

        {/* Name — clips out from behind line */}
        <div
          style={{
            overflow: "hidden",
            height: 36,
          }}
        >
          <div
            style={{
              color: "#fff",
              fontSize: 28,
              fontWeight: 700,
              letterSpacing: "-0.5px",
              lineHeight: 1,
              opacity: nameOpacity,
              transform: `translateY(${interpolate(nameProgress, [0, 1], [36, 0])}px)`,
              textShadow: "0 2px 12px rgba(0,0,0,0.8)",
            }}
          >
            {name}
          </div>
        </div>

        {/* Title */}
        <div
          style={{
            color: "rgba(255,255,255,0.65)",
            fontSize: 15,
            fontWeight: 500,
            letterSpacing: "0.3px",
            opacity: titleOpacity,
            transform: `translateY(${titleY}px)`,
            textShadow: "0 1px 8px rgba(0,0,0,0.8)",
          }}
        >
          {title}
        </div>
      </div>
    </div>
  );
};
