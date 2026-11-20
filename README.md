# Grok Bot for Raycast

Find your Grok bots, message them, and open their chats from Raycast.

![Grok-style conversation window](docs/screenshots/chat.png)

- Automatically discovers the signed-in account's open bots and their avatars.
- Puts pinned bots first, then sorts each group by recent activity.
- Selects bots by number, including multi-digit numbers.
- Opens a Grok-style chat window with recent messages and saved drafts.
- Offers a Counter-Strike-inspired wheel and per-bot Quicklinks.

The screenshots use sample bots and conversations.

## Install

You need macOS, [Raycast](https://www.raycast.com/), the **Grok Bot macOS app** installed and signed in, and [Bun](https://bun.sh/docs/installation).

1. Install Apple's command-line developer tools if needed.

   ```sh
   xcode-select --install
   ```

2. Clone and install the extension.

   ```sh
   git clone https://github.com/dcbuild3r/grok-bot-raycast-extension.git
   cd grok-bot-raycast-extension
   bun install --frozen-lockfile
   bun run dev
   ```

   The build prepares artwork from your installed Grok Bot app, compiles the macOS helpers, and registers the extension in Raycast.

3. Open Raycast and search for **Message a Bot**. Choose a bot to open its conversation window.

4. When prompted for sending permission, enable **Raycast** in **System Settings → Privacy & Security → Accessibility**.

Keep `bun run dev` running while developing. After the first successful import, the installed commands remain available when you close Terminal. Keep the project folder for updates and rebuilds.

## Message a bot

1. Open **Message a Bot** in Raycast.
2. Search for a bot and press Return, or type its displayed number.
3. Write your message and press **⌘Return** or click the send button.

Recent messages refresh from Grok Bot's local cache every two seconds while the window is open. Drafts are saved in Raycast's local storage. **⌘O** opens the full Grok Bot chat. Escape closes the window. The back button returns to the bot list.

Numbering follows the pinned-first, most-recent order. A digit that can begin a longer number waits briefly for the next digit. The order stays fixed while you enter a number.

## Use the bot wheel

![Bot wheel](docs/screenshots/wheel.png)

Open **Bot Wheel**, then click a bot or type its number. Use the arrow keys or page buttons to browse six bots at a time. Escape closes the wheel. The numbers follow the same ordering as the list.

## Set up shortcuts

Assign a hotkey to any command in **Raycast Settings → Extensions → Grok Bot**.

In either bot list, choose **Create Chat Quicklink** from the actions menu to create a direct link to that bot. Assign the Quicklink its own hotkey in Raycast Settings.

In the bot list, **⌘O** opens the selected chat and **⌘R** refreshes the index.

## Update

Run these commands from the project folder.

```sh
git pull
bun install --frozen-lockfile
bun run dev
```

## Troubleshooting

- If an executable or artwork is missing, run `bun run dev` again.
- If the list is empty, open Grok Bot, sign in, wait for its sidebar to load, and refresh the Raycast list.
- If the message is already drafted in Grok Bot, press **⌘O** to open the chat and review the draft before sending. If Grok Bot has a different draft or an attachment, send or clear it there first.
- If the recipient cannot be verified, close duplicate chat windows and open the intended chat in Grok Bot to refresh its selection cache.

If you use a custom Electron user-data directory, set **Grok Bot Data Folder** in the extension preferences. The default is `~/Library/Application Support/Grok Bot`.

## Development

```sh
bun run test
bun run typecheck
bun run lint
bun run build
```

`bun run build` creates a release bundle in `dist/`. The helpers compile for your current Mac architecture. To regenerate the README screenshots after building, run `bun scripts/screenshots.mjs`.

The integration was developed against Grok Bot 1.2.0 with its English interface. It uses Grok Bot's local cache and macOS Accessibility controls. Changes to either may require an extension update.

## Security and license

The focused security review, data handling, and dependency audit results are documented in [SECURITY.md](SECURITY.md).

The extension code is [MIT licensed](LICENSE). Grok Bot branding and avatar artwork belong to their respective owners. Builds execute renderer code from your locally installed Grok Bot app to generate its artwork. This repository contains the extension source and sample screenshots.
