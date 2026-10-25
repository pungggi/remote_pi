import type { Metadata } from "next";

/* Pages under /remote-pi belong to the sibling project, so they carry its name
   in the title bar instead of the root layout's "· Piper Cockpit" suffix. */
export const metadata: Metadata = {
  title: {
    default: "Piper",
    template: "%s · Piper",
  },
};

export default function RemotePiLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <>{children}</>;
}
