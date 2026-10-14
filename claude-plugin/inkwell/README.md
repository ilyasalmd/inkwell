# Inkwell for Claude

Lets Claude on your Mac look at the notebook pages you are writing in Inkwell on your iPad, so you stop taking screenshots.
Everything stays between your devices and your own iCloud Drive. There is no API key and no server.

## How it works

1. In Inkwell on the iPad: **Settings > Sync with iCloud**, then **Share with Claude on my Mac**.
2. Inkwell pauses 2–3 seconds after you stop writing, then saves that page as an image into
   `iCloud Drive/Inkwell/ForClaude`, together with a small `index.json`.
3. iCloud puts the same folder on your Mac, at
   `~/Library/Mobile Documents/iCloud~com~ilyas~inkwell/Documents/Inkwell/ForClaude`.
4. This plugin's local server (`server.py`, Python 3, standard library only) reads that folder for Claude.

## Install (Claude Code)

```bash
claude plugin marketplace add /path/to/Inkwell/claude-plugin
claude plugin install inkwell
```

Or point Claude Code at the folder directly: `claude --plugin-dir /path/to/Inkwell/claude-plugin/inkwell`.

## Install (Claude Desktop)

Add this to `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart Claude:

```json
{
  "mcpServers": {
    "inkwell": { "command": "python3", "args": ["/path/to/Inkwell/claude-plugin/inkwell/server.py"] }
  }
}
```

## What you can say

- "Look at what I'm writing" — shows the page you edited last.
- "List my Inkwell notebooks."
- "Read page 3 of Physics."
- "Go through my Lecture notes notebook and quiz me."

## Notes

- Needs the iCloud build of Inkwell (TestFlight/App Store). The free open download has no iCloud.
- Only pages that contain writing are shared. Turn the switch off and nothing new is written.
- Set `INKWELL_FOLDER` to read from a different folder.
