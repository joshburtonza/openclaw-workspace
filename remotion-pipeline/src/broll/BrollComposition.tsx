import React from "react";
import { IPhoneFrame } from "./IPhoneFrame";
import { TelegramChatView } from "./TelegramChatView";
import { TerminalView } from "./TerminalView";
import { StatCard } from "./StatCard";
import { ChatBubbles } from "./ChatBubbles";
import { LowerThird } from "./LowerThird";
import { AnimatedTweet } from "./AnimatedTweet";
import { BarChart } from "./BarChart";

export interface BrollClipProps {
  type: "iphone_telegram" | "iphone_dashboard" | "terminal" | "chat_bubble" | "stat_card" | "lower_third" | "tweet" | "bar_chart";
  props: Record<string, unknown>;
  width: number;
  height: number;
}

/**
 * Dispatches to the correct B-roll scene component based on `type`.
 * Rendered by BrollRoot for each individual clip.
 */
export const BrollComposition: React.FC<BrollClipProps> = ({
  type,
  props,
  width,
  height,
}) => {
  const containerStyle: React.CSSProperties = {
    width,
    height,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    background: "transparent",
  };

  if (type === "iphone_telegram") {
    const phoneWidth = Math.min(width * 0.55, 280);
    return (
      <div style={containerStyle}>
        <IPhoneFrame width={phoneWidth}>
          <TelegramChatView
            chat_name={(props.chat_name as string) ?? "AOS"}
            messages={(props.messages as any[]) ?? []}
            show_notification_popup={(props.show_notification_popup as boolean) ?? false}
            notification_text={(props.notification_text as string) ?? ""}
            phone_width={phoneWidth}
          />
        </IPhoneFrame>
      </div>
    );
  }

  if (type === "iphone_dashboard") {
    // Placeholder — renders a clean "Mission Control" screen inside iPhone
    const phoneWidth = Math.min(width * 0.55, 280);
    const page = (props.page as string) ?? "Dashboard";
    const metric = (props.metric as string) ?? "";
    return (
      <div style={containerStyle}>
        <IPhoneFrame width={phoneWidth}>
          <div
            style={{
              width: "100%",
              height: "100%",
              background: "#0a0b14",
              display: "flex",
              flexDirection: "column",
              fontFamily: "-apple-system, 'SF Pro Display', sans-serif",
              padding: `${phoneWidth * 0.04}px`,
            }}
          >
            <div
              style={{
                color: "rgba(255,255,255,0.4)",
                fontSize: phoneWidth * 0.036,
                fontWeight: 600,
                letterSpacing: "0.5px",
                textTransform: "uppercase",
                marginBottom: phoneWidth * 0.02,
              }}
            >
              Mission Control
            </div>
            <div
              style={{
                color: "#fff",
                fontSize: phoneWidth * 0.06,
                fontWeight: 700,
                marginBottom: phoneWidth * 0.04,
              }}
            >
              {page}
            </div>
            {metric && (
              <div
                style={{
                  background: "rgba(75, 158, 255, 0.1)",
                  border: "1px solid rgba(75, 158, 255, 0.25)",
                  borderRadius: phoneWidth * 0.03,
                  padding: `${phoneWidth * 0.03}px ${phoneWidth * 0.04}px`,
                  color: "#4B9EFF",
                  fontSize: phoneWidth * 0.042,
                  fontWeight: 600,
                }}
              >
                {metric}
              </div>
            )}
          </div>
        </IPhoneFrame>
      </div>
    );
  }

  if (type === "terminal") {
    return (
      <div style={{ ...containerStyle, padding: "20px" }}>
        <TerminalView
          title={(props.title as string) ?? "bash"}
          lines={(props.lines as string[]) ?? []}
        />
      </div>
    );
  }

  if (type === "chat_bubble") {
    return (
      <div style={containerStyle}>
        <ChatBubbles messages={(props.messages as any[]) ?? []} />
      </div>
    );
  }

  if (type === "stat_card") {
    return (
      <div style={containerStyle}>
        <StatCard
          label={(props.label as string) ?? ""}
          value={(props.value as string) ?? ""}
          delta={props.delta as string | undefined}
          color={(props.color as string) ?? "#4ade80"}
        />
      </div>
    );
  }

  if (type === "lower_third") {
    return (
      <div style={containerStyle}>
        <LowerThird
          name={(props.name as string) ?? "Josh Burton"}
          title={(props.title as string) ?? "Amalfi AI"}
          color={(props.color as string) ?? "#4B9EFF"}
        />
      </div>
    );
  }

  if (type === "tweet") {
    return (
      <div style={containerStyle}>
        <AnimatedTweet
          display_name={(props.display_name as string) ?? ""}
          username={(props.username as string) ?? ""}
          content={(props.content as string) ?? ""}
          timestamp={props.timestamp as string | undefined}
          likes={props.likes as string | undefined}
          retweets={props.retweets as string | undefined}
        />
      </div>
    );
  }

  if (type === "bar_chart") {
    return (
      <div style={{ ...containerStyle, padding: "20px" }}>
        <BarChart
          title={(props.title as string) ?? ""}
          bars={(props.bars as any[]) ?? []}
          color={(props.color as string) ?? "#4B9EFF"}
          unit={(props.unit as string) ?? ""}
        />
      </div>
    );
  }

  return null;
};
