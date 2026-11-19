import assert from "node:assert/strict";
import { link, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { createRecapStore } from "../src/recaps.js";

const id = (name) => Buffer.from(name).toString("base64url");
const latest = "2026-11-19 15.00 Globr.recap.md";

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "tape-recaps-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const folder = join(root, "Tape");
  await mkdir(folder);
  await writeFile(join(folder, latest), "# Globr\nសួស្តី\nShip the photo fix.");
  await writeFile(join(folder, "2026-11-18 09.00 Zoom.recap.md"), "# Kappy\nMerchant demo");
  await writeFile(join(folder, "2026-11-20 10.00 Private.transcript.txt"), "TRANSCRIPT");
  await writeFile(join(folder, "2026-11-20 10.00 Private.m4a"), "AUDIO");
  await writeFile(join(root, "Outside.recap.md"), "OUTSIDE");
  await symlink(join(root, "Outside.recap.md"), join(folder, "Symlink.recap.md"));
  await link(join(root, "Outside.recap.md"), join(folder, "Hardlink.recap.md"));
  return folder;
}

test("searches Khmer and English and applies inclusive recording dates", async (t) => {
  const store = createRecapStore(await fixture(t));
  assert.deepEqual((await store.search()).recaps.map(r => r.title), ["Globr", "Zoom"]);
  assert.equal((await store.search({ query: "GLOBR សួស្តី", after: "2026-11-19", before: "2026-11-19" })).recaps[0].id, id(latest));
  assert.equal((await store.search({ query: "merchant" })).recaps[0].title, "Zoom");
  assert.equal((await store.search({ after: "2026-11-20" })).recaps.length, 0);
  assert.match((await store.get(id(latest))).markdown, /Ship the photo fix/u);
});

test("blocks traversal, audio, transcript, symlinks, hardlinks and oversized recaps", async (t) => {
  const folder = await fixture(t);
  const store = createRecapStore(folder);
  await writeFile(join(folder, "Big.recap.md"), Buffer.alloc(262145));
  for (const name of ["../Outside.recap.md", "Symlink.recap.md", "Hardlink.recap.md", "Big.recap.md",
    "2026-11-20 10.00 Private.transcript.txt", "2026-11-20 10.00 Private.m4a"]) {
    assert.equal(await store.get(id(name)), null, name);
  }
  assert.equal((await store.search({ query: "OUTSIDE" })).recaps.length, 0);
  assert.equal((await store.search()).recaps.length, 2);
});

test("real MCP client searches and reads through the bundled stdio server", async (t) => {
  const folder = await fixture(t);
  const client = new Client({ name: "tape-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["build/server/index.cjs"],
    env: { TAPE_RECAPS_DIR: folder },
  });
  t.after(() => client.close());
  await client.connect(transport);
  const tools = (await client.listTools()).tools;
  assert.deepEqual(tools.map(x => x.name).sort(), ["get_recap", "search_recaps"]);
  assert.ok(tools.every(x => x.annotations.readOnlyHint));
  const call = (name, args) => client.callTool({ name, arguments: args });
  const search = await call("search_recaps", { query: "Globr" });
  assert.equal(JSON.parse(search.content[0].text).recaps[0].id, id(latest));
  assert.doesNotMatch(search.content[0].text, /Ship the photo fix/u);
  assert.match(JSON.parse((await call("get_recap", { id: id(latest) })).content[0].text).markdown, /សួស្តី/u);
  assert.equal((await call("get_recap", { id: id("../Outside.recap.md") })).isError, true);
  assert.equal((await call("search_recaps", { after: "2026-11-20", before: "2026-11-19" })).isError, true);
  await writeFile(join(folder, "2026-11-20 16.00 New Globr.recap.md"), "# New meeting");
  assert.equal(JSON.parse((await call("search_recaps", { query: "Globr" })).content[0].text).recaps.length, 2);
});
