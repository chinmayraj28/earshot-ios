/**
 * Earshot's icon set: hand-drawn inline SVG on a 24-unit grid, 1.75 stroke, round caps.
 * Icons are decoration for screen readers (aria-hidden); the button around them carries the label.
 */
import type { ReactNode } from "react";

function Svg({ children, size = 22, filled = false }: { children: ReactNode; size?: number; filled?: boolean }) {
  return (
    <svg
      className="icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={filled ? "currentColor" : "none"}
      stroke={filled ? "none" : "currentColor"}
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {children}
    </svg>
  );
}

type P = { size?: number };

export const BackIcon = ({ size }: P) => <Svg size={size}><path d="M15 5l-7 7 7 7" /></Svg>;
export const ChevronRightIcon = ({ size }: P) => <Svg size={size}><path d="M9 5l7 7-7 7" /></Svg>;
export const GearIcon = ({ size }: P) => (
  <Svg size={size}>
    <circle cx="12" cy="12" r="3" />
    <path d="M12 2.8l1.6 2.3 2.7-.6.6 2.7 2.4 1.4-1 2.6 1 2.6-2.4 1.4-.6 2.7-2.7-.6L12 21.2l-1.6-2.3-2.7.6-.6-2.7-2.4-1.4 1-2.6-1-2.6 2.4-1.4.6-2.7 2.7.6z" />
  </Svg>
);
export const InfoIcon = ({ size }: P) => (
  <Svg size={size}>
    <circle cx="12" cy="12" r="9" />
    <path d="M12 11v5.5M12 7.6v.1" />
  </Svg>
);
export const SendIcon = ({ size }: P) => <Svg size={size}><path d="M12 19V5M6 11l6-6 6 6" /></Svg>;
export const ClockIcon = ({ size }: P) => (
  <Svg size={size}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 7.5V12l3 2" />
  </Svg>
);
export const AlertIcon = ({ size }: P) => (
  <Svg size={size}>
    <circle cx="12" cy="12" r="9" />
    <path d="M12 7.5v5.5M12 16.4v.1" />
  </Svg>
);
export const LockIcon = ({ size }: P) => (
  <Svg size={size}>
    <rect x="5" y="10.5" width="14" height="10" rx="2.5" />
    <path d="M8.5 10.5V8a3.5 3.5 0 017 0v2.5" />
  </Svg>
);
/** The seal used for "verified", drawn like the phone's checkmark.seal. */
export const SealIcon = ({ size, filled = true }: P & { filled?: boolean }) => (
  <svg className="icon" width={size ?? 18} height={size ?? 18} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <path
      d="M12 2.5l2.2 1.7 2.8-.2.9 2.6 2.4 1.5-.8 2.7.8 2.7-2.4 1.5-.9 2.6-2.8-.2L12 21.5l-2.2-1.7-2.8.2-.9-2.6-2.4-1.5.8-2.7-.8-2.7 2.4-1.5.9-2.6 2.8.2z"
      fill={filled ? "currentColor" : "none"}
      stroke="currentColor"
      strokeWidth={filled ? 0 : 1.75}
      strokeLinejoin="round"
    />
    <path className={filled ? "seal-check" : undefined} d="M8.6 12.2l2.3 2.3 4.6-4.8" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);
export const BellIcon = ({ size }: P) => (
  <Svg size={size}>
    <path d="M6 16.5V11a6 6 0 0112 0v5.5l1.5 1.5h-15z" />
    <path d="M10 20.5a2.2 2.2 0 004 0" />
  </Svg>
);
export const CloseIcon = ({ size }: P) => <Svg size={size}><path d="M6.5 6.5l11 11M17.5 6.5l-11 11" /></Svg>;
export const TrashIcon = ({ size }: P) => (
  <Svg size={size}>
    <path d="M4.5 7h15M9.5 7V4.8h5V7M6.5 7l.9 12.2h9.2l.9-12.2M10 10.5v5.5M14 10.5v5.5" />
  </Svg>
);
export const RetryIcon = ({ size }: P) => (
  <Svg size={size}>
    <path d="M19.5 12a7.5 7.5 0 11-2.2-5.3" />
    <path d="M19.5 4.5v4h-4" />
  </Svg>
);
/** A chain link pulled apart: "disconnect". */
export const UnlinkIcon = ({ size }: P) => (
  <Svg size={size}>
    <path d="M18.8 12.3l1.7-1.7a5 5 0 00-7.1-7.1l-1.7 1.7" />
    <path d="M5.2 11.7l-1.7 1.7a5 5 0 007.1 7.1l1.7-1.7" />
    <path d="M8 2v3M2 8h3M16 19v3M19 16h3" />
  </Svg>
);
export const WavesIcon = ({ size }: P) => (
  <Svg size={size}>
    <circle cx="12" cy="12" r="1.6" />
    <path d="M8.5 8.5a5 5 0 000 7M15.5 8.5a5 5 0 010 7M5.6 5.6a9 9 0 000 12.8M18.4 5.6a9 9 0 010 12.8" />
  </Svg>
);
export const PhoneIcon = ({ size }: P) => (
  <Svg size={size}>
    <rect x="7" y="2.8" width="10" height="18.4" rx="2.6" />
    <path d="M11 18h2" />
  </Svg>
);
export const LaptopIcon = ({ size }: P) => (
  <Svg size={size}>
    <rect x="4.5" y="5" width="15" height="10.5" rx="1.6" />
    <path d="M2.5 18.5h19" />
  </Svg>
);
export const ShieldIcon = ({ size }: P) => (
  <Svg size={size}>
    <path d="M12 3l7 2.8v5.4c0 4.5-3 8-7 9.8-4-1.8-7-5.3-7-9.8V5.8z" />
  </Svg>
);
export const BlockIcon = ({ size }: P) => (
  <Svg size={size}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M6 6l12 12" />
  </Svg>
);
export const StorageIcon = ({ size }: P) => (
  <Svg size={size}>
    <ellipse cx="12" cy="6" rx="7" ry="2.8" />
    <path d="M5 6v12c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8V6M5 12c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8" />
  </Svg>
);
export const TabIcon = ({ size }: P) => (
  <Svg size={size}>
    <rect x="3" y="5" width="18" height="14" rx="2" />
    <path d="M3 9h18M7 5v4" />
  </Svg>
);
export const ArrowDownIcon = ({ size }: P) => <Svg size={size}><path d="M12 5v14M6 13l6 6 6-6" /></Svg>;
export const EyeOffIcon = ({ size }: P) => (
  <Svg size={size}>
    <path d="M3.5 12S7 6 12 6c1.6 0 3 .5 4.2 1.2M20.5 12S17 18 12 18c-1.6 0-3-.5-4.2-1.2" />
    <path d="M4 20L20 4" />
  </Svg>
);
export const HandIcon = ({ size }: P) => (
  <Svg size={size}>
    <path d="M8 12V5.5a1.5 1.5 0 013 0V11M11 10.5V4.2a1.5 1.5 0 013 0V11M14 10.5V5.5a1.5 1.5 0 013 0V14c0 4-2.5 7-6 7-2.5 0-4-1.3-5.4-3.4L3.8 15a1.5 1.5 0 012.4-1.8L8 15" />
  </Svg>
);
