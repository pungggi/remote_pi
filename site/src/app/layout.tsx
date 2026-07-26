import type { Metadata } from "next";
import { Space_Grotesk, Hanken_Grotesk, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import { SiteHeader } from "@/components/header";
import { SiteFooter } from "@/components/footer";

const display = Space_Grotesk({
  variable: "--font-display",
  subsets: ["latin"],
  weight: ["500", "600", "700"],
  display: "swap",
});

const body = Hanken_Grotesk({
  variable: "--font-body",
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  display: "swap",
});

const mono = JetBrains_Mono({
  variable: "--font-mono",
  subsets: ["latin"],
  weight: ["400", "500"],
  display: "swap",
});

const siteTagline = "Piper — Your coding agents, in your pocket";
const siteDescription =
  "Pair your phone once, then drive any Pi coding agent from it — keep a fleet running 24/7 and link every machine into one mesh. Open source, relay on your own network.";

/// This fork has no deployed site and therefore no canonical domain. Next needs
/// a parseable `metadataBase` to resolve relative OG image URLs, so it falls
/// back to the dev server; whoever deploys sets NEXT_PUBLIC_SITE_URL. Pointing
/// it at the upstream project's domain would attribute this fork's pages to
/// someone else.
const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: {
    default: siteTagline,
    template: "%s · Piper",
  },
  description: siteDescription,
  applicationName: "Piper",
  keywords: [
    "Piper",
    "coding agents",
    "Pi coding agent",
    "mobile agent control",
    "24/7 agent daemon",
    "agent mesh",
    "self-hostable relay",
  ],
  openGraph: {
    type: "website",
    url: siteUrl,
    title: siteTagline,
    description: siteDescription,
    siteName: "Piper",
  },
  twitter: {
    card: "summary_large_image",
    title: siteTagline,
    description: siteDescription,
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${display.variable} ${body.variable} ${mono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col bg-bg text-fg">
        <div className="app flex min-h-full flex-1 flex-col" id="top">
          <SiteHeader />
          <main className="flex-1">{children}</main>
          <SiteFooter />
        </div>
      </body>
    </html>
  );
}
