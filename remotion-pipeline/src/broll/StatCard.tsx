import React from "react";
import { useCurrentFrame, spring, interpolate, useVideoConfig } from "remotion";

interface StatCardProps {
  label: string;
  value: string;
  delta?: string;
  color?: string;
}

export const StatCard: React.FC<StatCardProps> = ({
  label,
  value,
  delta,
  color = "#4ade80",
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const cardProgress = spring({
    frame,
    fps,
    config: { stiffness: 180, damping: 20 },
    from: 0,
    to: 1,
  });

  const cardOpacity = interpolate(frame, [0, 8], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const valueProgress = spring({
    frame: frame - 10,
    fps,
    config: { stiffness: 200, damping: 22 },
    from: 0,
    to: 1,
  });

  const deltaOpacity = interpolate(frame - 20, [0, 10], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <div
        style={{
          background: "linear-gradient(145deg, #1a1f2e 0%, #0f1319 100%)",
          borderRadius: 20,
          padding: "28px 36px",
          border: `1px solid ${color}33`,
          boxShadow: `0 0 40px ${color}22, 0 20px 60px rgba(0,0,0,0.6)`,
          opacity: cardOpacity,
          transform: `scale(${interpolate(cardProgress, [0, 1], [0.85, 1])})`,
          minWidth: 220,
          textAlign: "center",
          fontFamily: "-apple-system, 'SF Pro Display', sans-serif",
        }}
      >
        {/* Label */}
        <div
          style={{
            color: "rgba(255,255,255,0.5)",
            fontSize: 15,
            fontWeight: 500,
            letterSpacing: "0.3px",
            marginBottom: 12,
            textTransform: "uppercase",
            fontSize: 12,
          }}
        >
          {label}
        </div>

        {/* Value */}
        <div
          style={{
            color,
            fontSize: 56,
            fontWeight: 800,
            lineHeight: 1,
            letterSpacing: "-2px",
            transform: `scale(${interpolate(valueProgress, [0, 1], [0.7, 1])})`,
            textShadow: `0 0 30px ${color}66`,
            marginBottom: delta ? 12 : 0,
          }}
        >
          {value}
        </div>

        {/* Delta */}
        {delta && (
          <div
            style={{
              opacity: deltaOpacity,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 6,
            }}
          >
            <div
              style={{
                background: `${color}22`,
                border: `1px solid ${color}44`,
                borderRadius: 100,
                padding: "4px 12px",
                color,
                fontSize: 13,
                fontWeight: 600,
              }}
            >
              {delta}
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
