/**
 * Plan/114 + plan/126 review, carried over (PR #128): the model-visible
 * failure text of show_file / show_image must never contain the resolved
 * absolute path. Node's own fs messages embed it, so the pipeline reports
 * the error code instead — and for errors without a code it redacts.
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

  test("without a code, quoted segments and absolute paths are redacted", () => {
    expect(fsErrorDetail(new Error("could not append to '/home/me/.pi/piper/registry.jsonl': EBUSY"))).toBe(
      "could not append to '…': EBUSY",
    );
    expect(fsErrorDetail(new Error("registry at /home/me/.pi/piper/files.json is locked"))).toBe(
      "registry at <path> is locked",
    );
    expect(fsErrorDetail(new Error("cannot write C:\\Users\\me\\.pi\\piper\\files.json"))).toBe("cannot write <path>");
    // Paths that contain spaces end at the whitespace: the rest is prose as
    // far as an error message can tell, and what remains is relative.
    expect(fsErrorDetail(new Error("spawn C:\\Program Files\\nodejs\\node.exe failed"))).toBe("spawn <path> Files\\nodejs\\node.exe failed");
    expect(fsErrorDetail(new Error("missing /home/me/My Documents/report.pdf"))).toBe("missing <path> Documents/report.pdf");
    // Parentheses and commas end a path too.
    expect(fsErrorDetail(new Error("lock held by /var/lock/piper.lock, retry"))).toBe("lock held by <path>, retry");
    // Relative paths and plain words survive: they carry no location.
    expect(fsErrorDetail(new Error("bad entry in pi/piper/files.json (relative)"))).toBe("bad entry in pi/piper/files.json (relative)");
  });

  test("non-Error values are stringified", () => {
    expect(fsErrorDetail("disk full at /var/tmp/x")).toBe("disk full at <path>");
    expect(fsErrorDetail(42)).toBe("42");
  });
});
