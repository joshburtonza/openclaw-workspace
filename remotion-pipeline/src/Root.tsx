import React from "react";
import { Composition } from "remotion";
import { TalkingHead } from "./TalkingHead";
import type { TalkingHeadProps } from "./types";

const defaultProps: TalkingHeadProps = {
  videoSrc: "",
  segments: [{ start: 0, end: 10 }],
  words: [],
  title: "Preview",
  fps: 30,
  width: 1080,
  height: 1920,
};

export const RemotionRoot: React.FC = () => {
  return (
    <Composition
      id="TalkingHead"
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      component={TalkingHead as React.ComponentType<any>}
      durationInFrames={300}
      fps={30}
      width={1080}
      height={1920}
      defaultProps={defaultProps}
      calculateMetadata={async ({ props: rawProps }) => {
        const props = rawProps as unknown as TalkingHeadProps;
        const totalSecs = (props.segments ?? []).reduce(
          (sum: number, s: { start: number; end: number }) =>
            sum + (s.end - s.start),
          0
        );
        const fps = props.fps ?? 30;
        return {
          durationInFrames: 60 + Math.ceil(totalSecs * fps),
          fps: fps as number,
          width: (props.width ?? 1080) as number,
          height: (props.height ?? 1920) as number,
        };
      }}
    />
  );
};
