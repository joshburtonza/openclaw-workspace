import React from "react";
import { useCurrentFrame, spring, interpolate, useVideoConfig } from "remotion";

interface ChatMessage {
  text: string;
  sender: string;
  is_ai?: boolean;
}

interface ChatBubblesProps {
  messages: ChatMessage[];
}

export const ChatBubbles: React.FC<ChatBubblesProps> = ({ messages }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const messageDelay = 20;

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
        padding: "20px 16px",
        gap: 12,
        fontFamily: "-apple-system, 'SF Pro Text', sans-serif",
      }}
    >
      {messages.map((msg, i) => {
        const entryFrame = i * messageDelay;
        const msgProgress = spring({
          frame: frame - entryFrame,
          fps,
          config: { stiffness: 240, damping: 24 },
          from: 0,
          to: 1,
        });
        const msgOpacity = interpolate(frame - entryFrame, [0, 8], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        });

        const isAI = msg.is_ai ?? false;
        const scaleX = interpolate(msgProgress, [0, 1], [0.7, 1]);

        return (
          <div
            key={i}
            style={{
              display: "flex",
              flexDirection: "column",
              alignItems: isAI ? "flex-start" : "flex-end",
              opacity: msgOpacity,
              transform: `scaleX(${scaleX})`,
              transformOrigin: isAI ? "left center" : "right center",
            }}
          >
            {/* Sender label */}
            <div
              style={{
                color: isAI ? "#93c5fd" : "rgba(255,255,255,0.4)",
                fontSize: 11,
                fontWeight: 600,
                letterSpacing: "0.5px",
                textTransform: "uppercase",
                marginBottom: 4,
                paddingLeft: isAI ? 14 : 0,
                paddingRight: isAI ? 0 : 14,
              }}
            >
              {msg.sender}
            </div>

            {/* Bubble */}
            <div
              style={{
                background: isAI
                  ? "linear-gradient(135deg, #1e3a5f 0%, #1a2f4e 100%)"
                  : "linear-gradient(135deg, #2b5278 0%, #1e3d5c 100%)",
                borderRadius: isAI
                  ? "4px 18px 18px 18px"
                  : "18px 4px 18px 18px",
                padding: "12px 16px",
                maxWidth: "82%",
                boxShadow: isAI
                  ? "0 4px 20px rgba(75, 158, 255, 0.15), 0 2px 8px rgba(0,0,0,0.3)"
                  : "0 4px 20px rgba(43, 82, 120, 0.3), 0 2px 8px rgba(0,0,0,0.3)",
                border: isAI
                  ? "1px solid rgba(147, 197, 253, 0.15)"
                  : "1px solid rgba(255,255,255,0.06)",
              }}
            >
              {/* AI indicator dot */}
              {isAI && (
                <div
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 6,
                    marginBottom: 6,
                  }}
                >
                  <div
                    style={{
                      width: 6,
                      height: 6,
                      borderRadius: "50%",
                      background: "#4B9EFF",
                      boxShadow: "0 0 6px #4B9EFF",
                    }}
                  />
                  <span
                    style={{
                      color: "#4B9EFF",
                      fontSize: 10,
                      fontWeight: 700,
                      letterSpacing: "0.5px",
                      textTransform: "uppercase",
                    }}
                  >
                    AI
                  </span>
                </div>
              )}

              <div
                style={{
                  color: "#e8e8e8",
                  fontSize: 15,
                  lineHeight: 1.5,
                  letterSpacing: "0.1px",
                }}
              >
                {msg.text}
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
};
