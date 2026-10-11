/**
 * TUI renderer for received-image preview messages — split from pipeline.ts
 * (plan/143) because it is the only pi-tui consumer in the entry's static
 * graph. pipeline.ts stays node-builtin-only so importing it from the thin
 * entry costs ~nothing; this module pays the ~100 ms pi-tui load, which the
 * thin-entry budget (issue #61: marginal pi startup ≤ 0.3 s) can absorb.
 */

import { readFileSync } from "node:fs";
import { Box, Container, Image, Text } from "@earendil-works/pi-tui";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ReceivedImageDetails } from "../extension-state.js";
import { IMAGE_PREVIEW_MIME, REMOTE_PI_RECEIVED_IMAGE_TYPE } from "./codec.js";

export function registerReceivedImageRenderer(pi: ExtensionAPI): void {
  pi.registerMessageRenderer<ReceivedImageDetails>(
    REMOTE_PI_RECEIVED_IMAGE_TYPE,
    (message, _options, theme) => {
      const details = (message.details ?? {}) as Partial<ReceivedImageDetails>;
      const path = typeof details.path === "string" ? details.path : "";
      const previewPath = typeof details.previewPath === "string" ? details.previewPath : "";
      const mime = typeof details.mime === "string" ? details.mime : "application/octet-stream";
      const inlineImagePath = previewPath.length > 0
        ? previewPath
        : (mime === IMAGE_PREVIEW_MIME ? path : "");
      const size = typeof details.size === "number" ? details.size : undefined;
      const index = typeof details.index === "number" ? details.index : undefined;
      const text = typeof details.text === "string" ? details.text.trim() : "";
      const messageId = typeof details.messageId === "string" ? details.messageId : "unknown";
      const error = typeof details.error === "string" ? details.error : undefined;
      const reason = typeof details.reason === "string" ? details.reason : undefined;

      const label = `📷 Photo from Android (${messageId}${index !== undefined ? ` #${index}` : ""})`;
      const lines = [
        theme.fg("customMessageLabel", label),
        theme.fg("customMessageText", `Saved: ${path || "(not saved)"}`),
      ];
      if (size !== undefined) lines.push(theme.fg("customMessageText", `Size: ${size} bytes`));
      if (mime) lines.push(theme.fg("customMessageText", `MIME: ${mime}`));
      if (error) lines.push(theme.fg("customMessageText", `Error: ${error}`));
      if (reason) lines.push(theme.fg("customMessageText", `Reason: ${reason}`));
      if (text) lines.push(theme.fg("customMessageText", `Text: ${text}`));

      const container = new Container();
      const metadata = new Box(1, 1, (line) => theme.bg("customMessageBg", line));
      metadata.addChild(new Text(lines.join("\n")));
      container.addChild(metadata);

      if (inlineImagePath && !error) {
        try {
          const imageData = readFileSync(inlineImagePath).toString("base64");
          if (imageData.length > 0) {
            const image = new Image(imageData, IMAGE_PREVIEW_MIME, {
              fallbackColor: (str) => theme.fg("customMessageText", str),
            });
            // Keep Kitty image rows out of Box padding/background so pi-tui can
            // preserve the empty reserved rows that make inline images visible.
            container.addChild(image);
          }
        } catch {
          // Keep the metadata-only fallback on any IO/terminal issue.
        }
      }

      return container;
    },
  );
}
