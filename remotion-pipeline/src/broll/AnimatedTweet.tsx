import React from "react";
import { useCurrentFrame, spring, interpolate, useVideoConfig } from "remotion";

interface AnimatedTweetProps {
  display_name: string;
  username: string;
  content: string;
  timestamp?: string;
  likes?: string;
  retweets?: string;
}

/**
 * Animated tweet card.
 * White container slides up → profile + content reveal → stats fade in.
 */
export const AnimatedTweet: React.FC<AnimatedTweetProps> = ({
  display_name,
  username,
  content,
  timestamp = "just now",
  likes = "247",
  retweets = "38",
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Card slides up and fades in
  const cardProgress = spring({
    frame,
    fps,
    config: { stiffness: 200, damping: 22 },
    from: 0,
    to: 1,
  });
  const cardOpacity = interpolate(frame, [0, 8], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const cardY = interpolate(cardProgress, [0, 1], [30, 0]);

  // Content fades in slightly after card (frame 12)
  const contentOpacity = interpolate(frame - 12, [0, 10], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  // Stats at the bottom (frame 22)
  const statsOpacity = interpolate(frame - 22, [0, 10], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const initials = display_name
    .split(" ")
    .map((w) => w[0])
    .join("")
    .slice(0, 2)
    .toUpperCase();

  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: "0 20px",
      }}
    >
      <div
        style={{
          background: "#15202b",
          borderRadius: 16,
          padding: "20px 20px 16px",
          width: "100%",
          maxWidth: 380,
          boxShadow: "0 12px 40px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08)",
          opacity: cardOpacity,
          transform: `translateY(${cardY}px)`,
          fontFamily: "-apple-system, 'SF Pro Text', sans-serif",
        }}
      >
        {/* Header */}
        <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 12 }}>
          {/* Avatar */}
          <div
            style={{
              width: 44,
              height: 44,
              borderRadius: "50%",
              background: "linear-gradient(135deg, #4B9EFF, #a78bfa)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              color: "#fff",
              fontSize: 16,
              fontWeight: 700,
              flexShrink: 0,
            }}
          >
            {initials}
          </div>

          {/* Name + handle */}
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ color: "#fff", fontSize: 15, fontWeight: 700 }}>
              {display_name}
            </div>
            <div style={{ color: "rgba(255,255,255,0.45)", fontSize: 13 }}>
              @{username}
            </div>
          </div>

          {/* X logo */}
          <svg width="20" height="20" viewBox="0 0 24 24" fill="white" opacity={0.6}>
            <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-4.714-6.231-5.401 6.231H2.744l7.73-8.835L1.254 2.25H8.08l4.213 5.567L18.244 2.25zm-1.161 17.52h1.833L7.084 4.126H5.117L17.083 19.77z" />
          </svg>
        </div>

        {/* Tweet content */}
        <div
          style={{
            color: "#e7e9ea",
            fontSize: 15,
            lineHeight: 1.6,
            letterSpacing: "0.1px",
            marginBottom: 14,
            opacity: contentOpacity,
          }}
        >
          {content}
        </div>

        {/* Timestamp */}
        <div
          style={{
            color: "rgba(255,255,255,0.35)",
            fontSize: 13,
            marginBottom: 12,
            paddingBottom: 12,
            borderBottom: "1px solid rgba(255,255,255,0.08)",
            opacity: contentOpacity,
          }}
        >
          {timestamp}
        </div>

        {/* Stats */}
        <div
          style={{
            display: "flex",
            gap: 24,
            opacity: statsOpacity,
          }}
        >
          {[
            { icon: "↩", label: retweets, name: "Reposts" },
            { icon: "♡", label: likes, name: "Likes" },
          ].map(({ icon, label, name }) => (
            <div
              key={name}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 6,
                color: "rgba(255,255,255,0.45)",
                fontSize: 13,
              }}
            >
              <span style={{ fontSize: 15 }}>{icon}</span>
              <span style={{ fontWeight: 600, color: "#e7e9ea" }}>{label}</span>
              <span>{name}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};
