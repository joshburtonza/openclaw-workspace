import React from "react";
import { useCurrentFrame, useVideoConfig, spring, interpolate } from "remotion";

interface TelegramMessage {
  text: string;
  time: string;
  is_outgoing?: boolean;
  is_ai?: boolean;
}

interface TelegramChatViewProps {
  chat_name: string;
  messages: TelegramMessage[];
  show_notification_popup?: boolean;
  notification_text?: string;
  phone_width: number;
}

const TELEGRAM_BG = "#17212b";
const TELEGRAM_HEADER = "#1c2733";
const BUBBLE_IN = "#182533";
const BUBBLE_OUT = "#2b5278";

export const TelegramChatView: React.FC<TelegramChatViewProps> = ({
  chat_name,
  messages,
  show_notification_popup,
  notification_text,
  phone_width,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const w = phone_width;

  const fs = (n: number) => w * n; // font-size helper

  // Stagger messages appearing
  const messageDelay = 12; // frames between each message

  // Notification popup animation (appears at frame 8)
  const notifProgress = show_notification_popup
    ? spring({ frame: frame - 8, fps, config: { stiffness: 160, damping: 18 }, from: 0, to: 1 })
    : 0;

  const notifY = interpolate(notifProgress, [0, 1], [-40, 0]);
  const notifOpacity = interpolate(notifProgress, [0, 0.3], [0, 1]);

  // Auto-dismiss notification after 2.5s (75 frames)
  const notifDismissOpacity = show_notification_popup
    ? interpolate(frame, [75, 90], [1, 0], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      })
    : 0;

  const finalNotifOpacity = notifOpacity * notifDismissOpacity;

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        background: TELEGRAM_BG,
        display: "flex",
        flexDirection: "column",
        fontFamily: "-apple-system, 'SF Pro Display', sans-serif",
        position: "relative",
        overflow: "hidden",
      }}
    >
      {/* Header */}
      <div
        style={{
          background: TELEGRAM_HEADER,
          padding: `${fs(0.04)}px ${fs(0.05)}px`,
          display: "flex",
          alignItems: "center",
          gap: fs(0.04),
          borderBottom: "1px solid rgba(255,255,255,0.06)",
          minHeight: fs(0.14),
          flexShrink: 0,
        }}
      >
        {/* Back arrow */}
        <span style={{ color: "#5ac8fa", fontSize: fs(0.055) }}>‹</span>
        {/* Avatar */}
        <div
          style={{
            width: fs(0.1),
            height: fs(0.1),
            borderRadius: "50%",
            background: "linear-gradient(135deg, #4B9EFF, #a78bfa)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: fs(0.048),
            color: "#fff",
            fontWeight: 700,
            flexShrink: 0,
          }}
        >
          {chat_name.charAt(0).toUpperCase()}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ color: "#fff", fontSize: fs(0.048), fontWeight: 600, lineHeight: 1.2 }}>
            {chat_name}
          </div>
          <div style={{ color: "#7dc8e8", fontSize: fs(0.035) }}>online</div>
        </div>
        {/* Call icon */}
        <span style={{ color: "#5ac8fa", fontSize: fs(0.05) }}>📞</span>
      </div>

      {/* Chat area */}
      <div
        style={{
          flex: 1,
          padding: `${fs(0.03)}px ${fs(0.04)}px`,
          overflowY: "hidden",
          display: "flex",
          flexDirection: "column",
          justifyContent: "flex-end",
          gap: fs(0.025),
        }}
      >
        {messages.map((msg, i) => {
          const entryFrame = i * messageDelay + 4;
          const msgProgress = spring({
            frame: frame - entryFrame,
            fps,
            config: { stiffness: 220, damping: 22 },
            from: 0,
            to: 1,
          });
          const msgOpacity = interpolate(frame - entryFrame, [0, 6], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          });
          const msgY = interpolate(msgProgress, [0, 1], [14, 0]);
          const isOut = msg.is_outgoing ?? false;

          return (
            <div
              key={i}
              style={{
                display: "flex",
                flexDirection: "column",
                alignItems: isOut ? "flex-end" : "flex-start",
                opacity: msgOpacity,
                transform: `translateY(${msgY}px)`,
              }}
            >
              <div
                style={{
                  background: isOut ? BUBBLE_OUT : BUBBLE_IN,
                  borderRadius: isOut
                    ? `${fs(0.05)}px ${fs(0.05)}px 4px ${fs(0.05)}px`
                    : `${fs(0.05)}px ${fs(0.05)}px ${fs(0.05)}px 4px`,
                  padding: `${fs(0.03)}px ${fs(0.045)}px`,
                  maxWidth: "85%",
                  boxShadow: "0 1px 2px rgba(0,0,0,0.3)",
                  border: "1px solid rgba(255,255,255,0.04)",
                }}
              >
                <div
                  style={{
                    color: "#e8e8e8",
                    fontSize: fs(0.042),
                    lineHeight: 1.45,
                    letterSpacing: "0.1px",
                  }}
                >
                  {msg.text}
                </div>
                <div
                  style={{
                    color: "rgba(255,255,255,0.35)",
                    fontSize: fs(0.03),
                    textAlign: "right",
                    marginTop: fs(0.01),
                    display: "flex",
                    justifyContent: "flex-end",
                    alignItems: "center",
                    gap: 3,
                  }}
                >
                  {msg.time}
                  {isOut && <span style={{ color: "#5ac8fa" }}>✓✓</span>}
                </div>
              </div>
            </div>
          );
        })}
      </div>

      {/* Input bar */}
      <div
        style={{
          background: TELEGRAM_HEADER,
          padding: `${fs(0.03)}px`,
          display: "flex",
          alignItems: "center",
          gap: fs(0.03),
          borderTop: "1px solid rgba(255,255,255,0.06)",
          flexShrink: 0,
        }}
      >
        <div
          style={{
            flex: 1,
            background: "#242f3d",
            borderRadius: fs(0.06),
            padding: `${fs(0.025)}px ${fs(0.04)}px`,
            color: "rgba(255,255,255,0.25)",
            fontSize: fs(0.04),
          }}
        >
          Message
        </div>
        <div
          style={{
            width: fs(0.09),
            height: fs(0.09),
            borderRadius: "50%",
            background: "#2b5278",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: fs(0.045),
            flexShrink: 0,
          }}
        >
          🎙
        </div>
      </div>

      {/* Notification popup (slides down from top) */}
      {show_notification_popup && notification_text && (
        <div
          style={{
            position: "absolute",
            top: fs(0.15),
            left: fs(0.03),
            right: fs(0.03),
            background: "rgba(28, 39, 51, 0.96)",
            backdropFilter: "blur(20px)",
            borderRadius: fs(0.04),
            padding: `${fs(0.03)}px ${fs(0.04)}px`,
            display: "flex",
            alignItems: "center",
            gap: fs(0.03),
            boxShadow: "0 8px 24px rgba(0,0,0,0.6)",
            transform: `translateY(${notifY}px)`,
            opacity: finalNotifOpacity,
            zIndex: 50,
            border: "1px solid rgba(255,255,255,0.08)",
          }}
        >
          {/* App icon */}
          <div
            style={{
              width: fs(0.09),
              height: fs(0.09),
              borderRadius: fs(0.018),
              background: "linear-gradient(135deg, #2ca5e0, #1a8ab5)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontSize: fs(0.055),
              flexShrink: 0,
            }}
          >
            ✈️
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ color: "#fff", fontSize: fs(0.038), fontWeight: 600 }}>
              Telegram
            </div>
            <div
              style={{
                color: "rgba(255,255,255,0.7)",
                fontSize: fs(0.035),
                overflow: "hidden",
                textOverflow: "ellipsis",
                whiteSpace: "nowrap",
              }}
            >
              {notification_text}
            </div>
          </div>
          <div style={{ color: "rgba(255,255,255,0.3)", fontSize: fs(0.03) }}>now</div>
        </div>
      )}
    </div>
  );
};
