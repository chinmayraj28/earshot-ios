/**
 * The Earshot motif: a point of sound with rings fading out a short way.
 * Same geometry as Rings.swift. When `animated`, rings radiate outward ("listening");
 * the CSS turns that off for people who ask for reduced motion.
 */
export function Rings({ animated = false, size, className = "", rings = 3, dot = 0.16 }: {
  animated?: boolean;
  size?: number | string;
  className?: string;
  rings?: number;
  /** Radius of the centre dot as a fraction of the half-width. 0 hides the dot. */
  dot?: number;
}) {
  const half = 50;
  const dotRadius = half * dot;
  const still = Array.from({ length: rings }, (_, index) => {
    const t = (index + 1) / rings;
    return {
      r: dotRadius + (half - dotRadius) * t * 0.94,
      width: Math.max(1, half * 0.07 * (1 - t * 0.45)),
      opacity: 0.9 - t * 0.68,
    };
  });
  return (
    <svg
      className={`rings ${animated ? "rings--animated" : ""} ${className}`}
      viewBox="0 0 100 100"
      width={size}
      height={size}
      aria-hidden="true"
      focusable="false"
    >
      {dotRadius > 0 && <circle className="rings__dot" cx="50" cy="50" r={dotRadius} />}
      {still.map((ring, index) => (
        <circle
          key={`still-${index}`}
          className="rings__still"
          cx="50"
          cy="50"
          r={ring.r}
          strokeWidth={ring.width}
          strokeOpacity={ring.opacity}
        />
      ))}
      {animated &&
        Array.from({ length: rings }, (_, index) => (
          <circle
            key={`pulse-${index}`}
            className="rings__pulse"
            cx="50"
            cy="50"
            r={dotRadius}
            style={{ animationDelay: `${(-index * 3.2) / rings}s` }}
          />
        ))}
    </svg>
  );
}
