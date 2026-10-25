// Minimal ustar writer so tests can build tarballs with entries the host OS
// could not create on disk (symlinks on Windows, `..` paths, devices).

import { gzipSync } from "node:zlib";

export type TarEntry =
  | { path: string; type: "file"; body: string; mode?: number }
  | { path: string; type: "dir" }
  | { path: string; type: "symlink" | "hardlink"; linkpath: string }
  | { path: string; type: "chardev" };

const TYPEFLAG = { file: "0", hardlink: "1", symlink: "2", chardev: "3", dir: "5" } as const;

function octal(n: number, width: number): string {
  return n.toString(8).padStart(width - 1, "0") + "\0";
}

function header(e: TarEntry, size: number): Buffer {
  const h = Buffer.alloc(512, 0);
  const put = (s: string, off: number, len: number) => h.write(s, off, len, "utf8");
  put(e.path, 0, 100);
  put(octal(e.type === "dir" ? 0o755 : e.type === "file" ? (e.mode ?? 0o644) : 0o777, 8), 100, 8);
  put(octal(0, 8), 108, 8);
  put(octal(0, 8), 116, 8);
  put(octal(size, 12), 124, 12);
  put(octal(1_700_000_000, 12), 136, 12);
  put("        ", 148, 8);
  put(TYPEFLAG[e.type], 156, 1);
  if (e.type === "symlink" || e.type === "hardlink") put(e.linkpath, 157, 100);
  put("ustar\0", 257, 6);
  put("00", 263, 2);
  let sum = 0;
  for (const b of h) sum += b;
  put(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8);
  return h;
}

/** Gzipped tarball. Entries are written as given; prefix them with a top dir like GitHub does. */
export function makeTarball(entries: TarEntry[]): Buffer {
  const blocks: Buffer[] = [];
  for (const e of entries) {
    const body = e.type === "file" ? Buffer.from(e.body, "utf8") : Buffer.alloc(0);
    blocks.push(header(e, body.length));
    if (body.length > 0) {
      blocks.push(body, Buffer.alloc((512 - (body.length % 512)) % 512, 0));
    }
  }
  blocks.push(Buffer.alloc(1024, 0));
  return gzipSync(Buffer.concat(blocks));
}
