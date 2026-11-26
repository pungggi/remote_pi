/**
 * Plan/114 + plan/126 review, carried over (PR #128): the model-visible
 * failure text of show_file / show_image must never contain the resolved
 * absolute path. Node's own fs messages embed it, so the pipeline reports
 * the error code instead — and for errors without a code no token with a
 * path separator survives.
 */
import { describe, expect, test } from "vitest";
import { fsErrorDetail } from "./pipeline.js";

describe("fsErrorDetail", () => {
  test("a coded fs error is reported by its code, never by Node's message", () => {
    const err = Object.assign(
      new Error("ENOENT: no such file or directory, stat '/home/me/secret/doc.md'"),
      { code: "ENOENT" },
    );
    expect(fsErrorDetail(err)).toBe("ENOENT");
  });

  test("absolute paths are redacted, quoted or not, POSIX or Windows", () => {
    expect(fsErrorDetail(new Error("could not append to '/home/me/.pi/piper/registry.jsonl': EBUSY"))).toBe(
      "could not append to '…': EBUSY",
    );
    expect(fsErrorDetail(new Error("registry at /home/me/.pi/piper/files.json is locked"))).toBe(
      "registry at <path> is locked",
    );
    expect(fsErrorDetail(new Error("cannot write C:\\Users\\me\\.pi\\piper\\files.json"))).toBe("cannot write <path>");
    // Parentheses and commas end a token.
    expect(fsErrorDetail(new Error("lock held by /var/lock/piper.lock, retry"))).toBe("lock held by <path>, retry");
  });

  test("a path with spaces is redacted token by token — nothing of it remains", () => {
    expect(fsErrorDetail(new Error("spawn C:\\Program Files\\nodejs\\node.exe failed"))).toBe("spawn <path> <path> failed");
    expect(fsErrorDetail(new Error("missing /home/me/My Documents/report.pdf"))).toBe("missing <path> <path>");
  });

  test("relative forms that name a location are redacted on both separators", () => {
    expect(fsErrorDetail(new Error("refused ../private/secret.txt"))).toBe("refused <path>");
    expect(fsErrorDetail(new Error("refused ..\\..\\Users\\me\\x.txt"))).toBe("refused <path>");
    expect(fsErrorDetail(new Error("refused ./secrets/key.pem"))).toBe("refused <path>");
    expect(fsErrorDetail(new Error("cannot read ~/private/key.pem"))).toBe("cannot read <path>");
    // The agent's own relative path appears in the error too; it is echoed
    // separately in details.path, so redacting it here loses nothing.
    expect(fsErrorDetail(new Error("bad entry in pi/piper/files.json"))).toBe("bad entry in <path>");
  });

  test("unbalanced quotes cannot smuggle a path through", () => {
    const out = fsErrorDetail(new Error("open '/home/o'brien/secret/key.pem' failed"));
    expect(out).not.toContain("/home");
    expect(out).not.toContain("brien");
    expect(out).not.toContain("key.pem");
    expect(out).toContain("failed");
  });

  test("prose survives; only tokens with a separator go; bare names stay", () => {
    expect(fsErrorDetail(new Error("registry limit reached for secret.txt (no path)"))).toBe(
      "registry limit reached for secret.txt (no path)",
    );
    expect(fsErrorDetail("disk full at /var/tmp/x")).toBe("disk full at <path>");
    expect(fsErrorDetail(42)).toBe("42");
  });
});
