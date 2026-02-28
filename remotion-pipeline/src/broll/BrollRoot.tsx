import React from "react";
import { Composition, registerRoot } from "remotion";
import { BrollComposition, BrollClipProps } from "./BrollComposition";

/**
 * Remotion root for rendering individual B-roll clips.
 * Entry point: src/broll/BrollRoot.tsx
 * Composition: "BrollClip"
 *
 * Props passed via --props JSON:
 *   { type, props, width, height, durationFrames, fps }
 */
const BrollRoot: React.FC = () => {
  return (
    <Composition
      id="BrollClip"
      component={BrollComposition as React.ComponentType<BrollClipProps>}
      durationInFrames={180} // default 6s at 30fps — overridden by --props
      fps={30}
      width={1080}
      height={1920}
      defaultProps={{
        type: "stat_card" as const,
        props: { label: "Preview", value: "42", delta: "+5 vs last week", color: "#4ade80" },
        width: 1080,
        height: 1920,
      }}
      calculateMetadata={({ props }) => ({
        durationInFrames: (props as any).durationFrames ?? 180,
        fps: (props as any).fps ?? 30,
        width: (props as any).width ?? 1080,
        height: (props as any).height ?? 1920,
      })}
    />
  );
};

registerRoot(BrollRoot);

export { BrollRoot };
