import React from "react";

interface IPhoneFrameProps {
  children: React.ReactNode;
  width?: number;
}

/**
 * Realistic iPhone 17 Pro frame using pure CSS.
 * No external assets. Dynamic island, side buttons, titanium finish.
 */
export const IPhoneFrame: React.FC<IPhoneFrameProps> = ({
  children,
  width = 320,
}) => {
  const height = width * 2.16; // iPhone 17 Pro aspect ratio ~430×930
  const radius = width * 0.14;
  const borderW = width * 0.03;
  const pillW = width * 0.28;
  const pillH = width * 0.045;

  return (
    <div
      style={{
        width,
        height,
        borderRadius: radius,
        background: "linear-gradient(145deg, #2a2a2a 0%, #1a1a1a 40%, #111 100%)",
        boxShadow: `
          0 0 0 ${borderW}px #3a3a3a,
          0 0 0 ${borderW + 2}px #222,
          0 ${width * 0.12}px ${width * 0.4}px rgba(0,0,0,0.9),
          inset 0 0 0 1px rgba(255,255,255,0.06)
        `,
        position: "relative",
        overflow: "hidden",
        flexShrink: 0,
      }}
    >
      {/* Titanium sheen on frame edge */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          borderRadius: radius,
          background:
            "linear-gradient(135deg, rgba(255,255,255,0.08) 0%, transparent 50%, rgba(255,255,255,0.04) 100%)",
          pointerEvents: "none",
          zIndex: 20,
        }}
      />

      {/* Screen bezel */}
      <div
        style={{
          position: "absolute",
          inset: borderW * 1.5,
          borderRadius: radius * 0.85,
          background: "#000",
          overflow: "hidden",
        }}
      >
        {/* Status bar */}
        <div
          style={{
            height: width * 0.12,
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            paddingLeft: width * 0.06,
            paddingRight: width * 0.06,
            background: "transparent",
            zIndex: 10,
            position: "relative",
          }}
        >
          <span
            style={{
              color: "#fff",
              fontSize: width * 0.042,
              fontWeight: 600,
              fontFamily: "-apple-system, sans-serif",
              letterSpacing: "-0.3px",
            }}
          >
            9:41
          </span>
          {/* Dynamic Island */}
          <div
            style={{
              position: "absolute",
              left: "50%",
              top: width * 0.025,
              transform: "translateX(-50%)",
              width: pillW,
              height: pillH,
              background: "#000",
              borderRadius: pillH,
              boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.08)",
            }}
          />
          {/* Status icons */}
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: width * 0.02,
            }}
          >
            <SignalIcon size={width * 0.035} />
            <WifiIcon size={width * 0.035} />
            <BatteryIcon size={width * 0.04} />
          </div>
        </div>

        {/* Screen content */}
        <div style={{ flex: 1, overflow: "hidden", height: `calc(100% - ${width * 0.12}px)` }}>
          {children}
        </div>
      </div>

      {/* Side button right */}
      <div
        style={{
          position: "absolute",
          right: -borderW * 0.6,
          top: "30%",
          width: borderW * 0.7,
          height: width * 0.15,
          background: "#3a3a3a",
          borderRadius: "0 3px 3px 0",
        }}
      />
      {/* Volume buttons left */}
      {[0.24, 0.35].map((top, i) => (
        <div
          key={i}
          style={{
            position: "absolute",
            left: -borderW * 0.6,
            top: `${top * 100}%`,
            width: borderW * 0.7,
            height: width * 0.1,
            background: "#3a3a3a",
            borderRadius: "3px 0 0 3px",
          }}
        />
      ))}
    </div>
  );
};

// ── Minimal status bar icons ──────────────────────────────────────────────────

const SignalIcon: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size * 3} height={size} viewBox="0 0 24 12" fill="white">
    <rect x="0" y="8" width="4" height="4" rx="0.5" opacity="0.4" />
    <rect x="5" y="5" width="4" height="7" rx="0.5" opacity="0.6" />
    <rect x="10" y="2" width="4" height="10" rx="0.5" opacity="0.8" />
    <rect x="15" y="0" width="4" height="12" rx="0.5" />
  </svg>
);

const WifiIcon: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size * 1.4} height={size} viewBox="0 0 20 14" fill="none">
    <path d="M10 12l2-2.5a2.8 2.8 0 00-4 0L10 12z" fill="white" />
    <path d="M5 7l1.5 1.5a5 5 0 017 0L15 7a7 7 0 00-10 0z" fill="white" opacity="0.7" />
    <path d="M2 4l1.5 1.5a8.5 8.5 0 0113 0L18 4a11 11 0 00-16 0z" fill="white" opacity="0.4" />
  </svg>
);

const BatteryIcon: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size * 1.6} height={size} viewBox="0 0 25 12" fill="none">
    <rect x="0" y="1" width="22" height="10" rx="2" stroke="white" strokeWidth="1.2" opacity="0.8" />
    <rect x="1.5" y="2.5" width="16" height="7" rx="1.2" fill="white" />
    <rect x="22.5" y="4" width="2" height="4" rx="1" fill="white" opacity="0.5" />
  </svg>
);
