import React from "react";
import { useCurrentFrame, spring, interpolate, useVideoConfig } from "remotion";

interface Bar {
  label: string;
  value: number;
}

interface BarChartProps {
  title: string;
  bars: Bar[];
  color?: string;
  unit?: string;
}

/**
 * Animated bar chart — bars grow up one by one with spring easing.
 * Kinetic typography on labels and values.
 */
export const BarChart: React.FC<BarChartProps> = ({
  title,
  bars,
  color = "#4B9EFF",
  unit = "",
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const maxValue = Math.max(...bars.map((b) => b.value));
  const barDelay = 12; // frames between each bar

  // Title fade
  const titleOpacity = interpolate(frame, [0, 10], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        background: "linear-gradient(145deg, #1a1f2e 0%, #0f1319 100%)",
        borderRadius: 16,
        padding: "20px 24px 16px",
        display: "flex",
        flexDirection: "column",
        fontFamily: "-apple-system, 'SF Pro Display', sans-serif",
        border: "1px solid rgba(255,255,255,0.06)",
        boxShadow: "0 20px 60px rgba(0,0,0,0.6)",
      }}
    >
      {/* Title */}
      <div
        style={{
          color: "rgba(255,255,255,0.6)",
          fontSize: 13,
          fontWeight: 600,
          letterSpacing: "0.5px",
          textTransform: "uppercase",
          marginBottom: 16,
          opacity: titleOpacity,
        }}
      >
        {title}
      </div>

      {/* Bars */}
      <div
        style={{
          flex: 1,
          display: "flex",
          alignItems: "flex-end",
          gap: 8,
        }}
      >
        {bars.map((bar, i) => {
          const entryFrame = i * barDelay + 4;
          const barProgress = spring({
            frame: frame - entryFrame,
            fps,
            config: { stiffness: 160, damping: 18 },
            from: 0,
            to: 1,
          });
          const heightPct = (bar.value / maxValue) * 100;
          const animatedHeight = interpolate(barProgress, [0, 1], [0, heightPct]);

          const labelOpacity = interpolate(frame - entryFrame - 4, [0, 8], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          });

          return (
            <div
              key={i}
              style={{
                flex: 1,
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                gap: 6,
                height: "100%",
                justifyContent: "flex-end",
              }}
            >
              {/* Value label above bar */}
              <div
                style={{
                  color: color,
                  fontSize: 13,
                  fontWeight: 700,
                  opacity: labelOpacity,
                  letterSpacing: "-0.3px",
                }}
              >
                {unit}{bar.value}
              </div>

              {/* Bar */}
              <div
                style={{
                  width: "100%",
                  height: `${animatedHeight}%`,
                  background: `linear-gradient(180deg, ${color} 0%, ${color}88 100%)`,
                  borderRadius: "4px 4px 2px 2px",
                  boxShadow: `0 0 16px ${color}44`,
                  minHeight: 2,
                  transition: "none",
                }}
              />

              {/* Label below */}
              <div
                style={{
                  color: "rgba(255,255,255,0.5)",
                  fontSize: 11,
                  fontWeight: 500,
                  textAlign: "center",
                  opacity: labelOpacity,
                  lineHeight: 1.2,
                }}
              >
                {bar.label}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};
