import { constants } from "node:fs";
import { open, opendir, realpath } from "node:fs/promises";
import { basename, join } from "node:path";

const suffix = ".recap.md";
const maxBytes = 256 * 1024;
const maxScanned = 1000;
const normalize = (s) => s.normalize("NFKC").toLowerCase();
const validName = (name) =>
  name.length > suffix.length && !name.startsWith(".") &&
  !name.includes("/") && !name.includes("\\") && !name.includes("\0") &&
  basename(name) === name && name.endsWith(suffix);
const encode = (name) => Buffer.from(name).toString("base64url");

function describe(name, stat) {
  const stem = name.slice(0, -suffix.length);
  const timestamp = /^(\d{4}-\d{2}-\d{2}) (\d{2})\.(\d{2})(?: (.*))?$/u.exec(stem);
  return {
    id: encode(name),
    title: timestamp?.[4] || stem,
    date: timestamp?.[1] ?? null,
    lastUpdated: stat.mtime.toISOString(),
    _sortKey: timestamp ? `${timestamp[1]}T${timestamp[2]}:${timestamp[3]}` : stat.mtime.toISOString(),
  };
}

export function createRecapStore(folder) {
  async function read(root, name, includeBody) {
    const handle = await open(join(root, name), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const stat = await handle.stat();
      if (!stat.isFile() || stat.nlink !== 1 || stat.size > maxBytes) return null;
      const meta = describe(name, stat);
      if (!includeBody) return { meta };
      const bytes = Buffer.alloc(stat.size + 1);
      const { bytesRead } = await handle.read(bytes, 0, bytes.length, 0);
      if (bytesRead !== stat.size) return null;
      return { meta, markdown: new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, bytesRead)) };
    } finally {
      await handle.close();
    }
  }

  return {
    async search({ query = "", after, before, limit = 10 } = {}) {
      const root = await realpath(folder);
      const dir = await opendir(root);
      const terms = normalize(query).trim().split(/\s+/u).filter(Boolean);
      const matches = [];
      let scanned = 0;
      let scanLimitReached = false;
      for await (const entry of dir) {
        if (!entry.isFile() || !validName(entry.name)) continue;
        if (after && before && after > before) return { recaps: [], scanLimitReached: false };
        if (scanned >= maxScanned) {
          scanLimitReached = true;
          break;
        }
        scanned++;
        try {
          const recap = await read(root, entry.name, terms.length > 0);
          if (!recap || (after && (!recap.meta.date || recap.meta.date < after)) ||
              (before && (!recap.meta.date || recap.meta.date > before))) continue;
          if (terms.length > 0) {
            const haystack = normalize(`${entry.name}\n${recap.markdown}`);
            if (!terms.every((term) => haystack.includes(term))) continue;
          }
          matches.push(recap.meta);
        } catch (error) {
          if (!["ENOENT", "ELOOP", "EACCES", "EPERM", "ERR_ENCODING_INVALID_ENCODED_DATA"].includes(error?.code)) throw error;
        }
      }
      matches.sort((a, b) => b._sortKey.localeCompare(a._sortKey) || a.id.localeCompare(b.id));
      return { recaps: matches.slice(0, limit).map(({ _sortKey, ...meta }) => meta), scanLimitReached };
    },

    async get(id) {
      const name = Buffer.from(id, "base64url").toString("utf8");
      if (!validName(name) || encode(name) !== id) return null;
      try {
        const recap = await read(await realpath(folder), name, true);
        if (!recap) return null;
        const { _sortKey, ...meta } = recap.meta;
        return { ...meta, markdown: recap.markdown };
      } catch (error) {
        if (["ENOENT", "ELOOP", "EACCES", "EPERM", "ERR_ENCODING_INVALID_ENCODED_DATA"].includes(error?.code)) return null;
        throw error;
      }
    },
  };
}
