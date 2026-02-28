import React from "react";
import { useCurrentFrame, interpolate } from "remotion";

interface TerminalViewProps {
  title: string;
  lines: string[];
}

export const TerminalView: React.FC<TerminalViewProps> = ({ title, lines }) => {
  const frame = useCurrentFrame();

  // Each line appears every 18 frames with a typing effect
  const lineDelay = 18;

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        background: "#0d1117",
        borderRadius: 12,
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
        fontFamily: "'SF Mono', 'Fira Code', 'Fira Mono', monospace",
        boxShadow: "0 20px 60px rgba(0,0,0,0.8)",
        border: "1px solid rgba(255,255,255,0.08)",
      }}
    >
      {/* Title bar */}
      <div
        style={{
          background: "#1c1c1e",
          padding: "10px 16px",
          display: "flex",
          alignItems: "center",
          gap: 8,
          borderBottom: "1px solid rgba(255,255,255,0.06)",
          flexShrink: 0,
        }}
      >
        {/* Traffic lights */}
        {["#ff5f57", "#ffbd2e", "#28ca41"].map((color, i) => (
          <div
            key={i}
            style={{
              width: 12,
              height: 12,
              borderRadius: "50%",
              background: color,
            }}
          />
        ))}
        <div
          style={{
            flex: 1,
            textAlign: "center",
            color: "rgba(255,255,255,0.5)",
            fontSize: 13,
            marginLeft: -36,
          }}
        >
          {title}
        </div>
      </div>

      {/* Terminal content */}
      <div
        style={{
          flex: 1,
          padding: "16px 20px",
          overflowY: "hidden",
          display: "flex",
          flexDirection: "column",
          gap: 6,
        }}
      >
        {/* Prompt + command */}
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span style={{ color: "#4ade80", fontSize: 14 }}>❯</span>
          <span style={{ color: "#e2e8f0", fontSize: 14 }}>
            {interpolate(frame, [0, 6], [0, 1], {
              extrapolateLeft: "clamp",
              extrapolateRight: "clamp",
            }) > 0.5 &&
              lines.length > 0 &&
              lines[0]}
          </span>
        </div>

        {/* Output lines */}
        {lines.slice(1).map((line, i) => {
          const lineFrame = (i + 1) * lineDelay;
          const lineOpacity = interpolate(frame - lineFrame, [0, 8], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          });

          // Colour coding
          let color = "rgba(255,255,255,0.75)";
          if (line.startsWith("[") && line.includes("]")) {
            const tag = line.match(/\[([^\]]+)\]/)?.[1] ?? "";
            if (tag.includes("error") || tag.includes("fail")) color = "#f87171";
            else if (tag.includes("done") || tag.includes("complete") || tag.includes("success"))
              color = "#4ade80";
            else color = "#93c5fd";
          } else if (line.startsWith("✅")) color = "#4ade80";
          else if (line.startsWith("❌")) color = "#f87171";
          else if (line.startsWith("→") || line.startsWith("•")) color = "#fbbf24";

          return (
            <div
              key={i}
              style={{
                color,
                fontSize: 13,
                lineHeight: 1.6,
                opacity: lineOpacity,
                letterSpacing: "0.2px",
              }}
            >
              {line}
            </div>
          );
        })}

        {/* Blinking cursor */}
        {(() => {
          const lastLineFrame = (lines.length - 1) * lineDelay;
          const cursorOpacity =
            frame > lastLineFrame
              ? Math.floor((frame - lastLineFrame) / 15) % 2 === 0
                ? 1
                : 0
              : 0;
          return (
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 8,
                opacity: cursorOpacity,
              }}
            >
              <span style={{ color: "#4ade80", fontSize: 14 }}>❯</span>
              <div
                style={{
                  width: 8,
                  height: 16,
                  background: "#e2e8f0",
                  opacity: 0.8,
                }}
              />
            </div>
          );
        })()}
      </div>
    </div>
  );
};
