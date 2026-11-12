import type { CSSProperties } from "react";
import type { LinkState } from "../engine/api";
import { avatarTone, initials } from "./format";

/** Initials on a muted tone, with an ember ring while connected (dashed while connecting). */
export function Avatar({ name, link, size = 44 }: { name: string; link?: LinkState; size?: number }) {
  return (
    <span
      className="avatar"
      data-link={link ?? "none"}
      data-tone={avatarTone(name)}
      style={{ "--avatar-size": `${size}px` } as CSSProperties}
      aria-hidden="true"
    >
      <span className="avatar__face">{initials(name)}</span>
    </span>
  );
}
