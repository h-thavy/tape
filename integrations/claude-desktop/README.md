# Tape Recaps for Claude Desktop

A read-only Claude Desktop extension for regular chats on the Mac running Tape.
It reads only `.recap.md` files directly inside the folder selected at install.
It does not read audio, transcripts, nested folders, or links, and it does not
start recordings, write files, sync folders, or create chats. No extra API key
or hosted service is needed. Matching file content is searched locally; a recap
fetched by Claude becomes part of the conversation context sent to Claude.

## Install and try it

1. Open Claude Desktop on the Mac with Tape and open Settings → Desktop app →
   Manage next to Extensions → Advanced settings → Install Extension.
2. Choose `Tape-Recaps.mcpb` and select `~/Documents/Tape` or a separate folder
   containing only recaps you want Claude to use. If macOS asks, allow Claude
   Desktop to read Documents. A managed Claude workspace may require an admin
   to approve custom extensions.
3. In a regular chat, enable **Tape Recaps** under **+ → Connectors** if it is
   not already enabled. Ask: “Use Tape Recaps to find our last Globr meeting.
   What did we agree to do? Give the recap date.”
4. For a smoke test with no confidential data, choose a test folder, add
   `2026-11-19 15.00 Globr.recap.md` containing a made-up decision, and verify
   Claude finds the file and returns that decision. Add a newer recap while
   Claude is open and ask again; no reinstall or manual import is needed.

New files are picked up on the next search, not pushed into the chat. Project
names are ordinary search words: include the project in the recording title or
recap. If Tape runs on someone else's Mac, this does not share their recaps.

## Development

From `integrations/claude-desktop`, with Node 20 or later:

```sh
npm ci
npm run build
npm test
cp manifest.json build/manifest.json
cd build
npx --yes @anthropic-ai/mcpb@2.1.2 pack . Tape-Recaps.mcpb
```

The extension uses Claude Desktop's embedded Node runtime. The tests connect a
real MCP client over stdio to the bundled server. For a non-Claude MCP client,
point its command at `node /path/to/build/server/index.cjs` and set
`TAPE_RECAPS_DIR` to an absolute path.
