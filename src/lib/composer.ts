import {
  LocalStorage,
  LaunchType,
  closeMainWindow,
  environment,
  getPreferenceValues,
  launchCommand,
  open,
} from "@raycast/api";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { nativeAvatar } from "./avatar";
import { sendMessage } from "./bridge";
import { loadHistory } from "./history";
import { Bot, chatLink, loadRoster } from "./roster";

export async function openComposer(
  bot: Bot,
  folder: string,
  accountSlot: string,
  initialMessage: string,
) {
  const current = await loadRoster(folder);
  if (
    current.accountSlot !== accountSlot ||
    !current.bots.some((item) => item.id === bot.id && item.name === bot.name)
  ) {
    throw new Error(
      "The account or bot changed. Select the bot again from the current list.",
    );
  }
  const key = `chat-draft-${createHash("sha256").update(`${accountSlot}/${bot.id}`).digest("hex")}`;
  const saved = await LocalStorage.getItem<string>(key);
  let draft = initialMessage || (typeof saved === "string" ? saved : "");
  let messages = await loadHistory(folder, accountSlot, bot.id).catch(() => []);
  const preferences = getPreferenceValues<Preferences>();
  await closeMainWindow();
  const result = await new Promise<{ type: string; back?: boolean }>(
    (resolve, reject) => {
      const child = spawn(join(environment.assetsPath, "bot-chat"), [], {
        stdio: ["pipe", "pipe", "pipe"],
      });
      let buffer = "";
      let closed = false;
      let sending = false;
      let polling = false;
      let historyFailed = false;
      let closeResult: { type: string; back?: boolean } | undefined;
      let saveTimer: ReturnType<typeof setTimeout> | undefined;
      let saves = Promise.resolve();
      const persist = () => {
        const value = draft;
        saves = saves
          .catch(() => undefined)
          .then(() => LocalStorage.setItem(key, value));
        return saves;
      };
      const write = (state: object) => {
        if (!closed && !child.stdin.destroyed)
          child.stdin.write(`${JSON.stringify(state)}\n`);
      };
      const stop = () => {
        child.kill("SIGTERM");
      };
      process.once("exit", stop);
      const refresh = async () => {
        if (polling || closed) return;
        polling = true;
        try {
          const current = await loadRoster(folder);
          if (
            current.accountSlot !== accountSlot ||
            !current.bots.some((item) => item.id === bot.id)
          ) {
            historyFailed = true;
            write({
              messages: [],
              canSend: false,
              status:
                "The Grok Bot account or bot changed. Close this window and choose the bot again.",
              error: true,
            });
            return;
          }
          try {
            const latest = await loadHistory(folder, accountSlot, bot.id);
            messages = latest;
            write({
              messages,
              canSend: true,
              ...(historyFailed ? { status: "", error: false } : {}),
            });
            historyFailed = false;
          } catch {
            historyFailed = true;
            write({
              messages: [],
              canSend: true,
              status:
                "Recent messages are unavailable. Open this chat in Grok Bot to refresh them.",
              error: true,
            });
          }
        } catch (error) {
          historyFailed = true;
          write({
            messages: [],
            canSend: false,
            status: error instanceof Error ? error.message : String(error),
            error: true,
          });
        } finally {
          polling = false;
        }
      };
      const timer = setInterval(() => void refresh(), 2000);
      const handle = async (event: {
        type?: string;
        text?: string;
        draft?: string;
        back?: boolean;
        error?: string;
      }) => {
        if (event.error) {
          reject(new Error(event.error));
          child.kill("SIGTERM");
          return;
        }
        if (event.type === "draft" && typeof event.text === "string") {
          draft = event.text;
          clearTimeout(saveTimer);
          saveTimer = setTimeout(() => {
            void persist().catch(() =>
              write({ status: "The draft could not be saved.", error: true }),
            );
          }, 250);
        }
        if (event.type === "close" || event.type === "open") {
          if (typeof event.draft === "string") draft = event.draft;
          closeResult = { type: event.type, back: event.back };
        }
        if (
          event.type !== "send" ||
          typeof event.text !== "string" ||
          !event.text.trim() ||
          sending
        )
          return;
        sending = true;
        draft = event.text;
        clearTimeout(saveTimer);
        try {
          await persist();
          await sendMessage(bot, event.text, folder, accountSlot);
          if (closed) return;
          draft = "";
          write({
            sending: false,
            clearDraft: true,
            status: "Sent",
            error: false,
            focus: true,
          });
          await persist().catch(() =>
            write({
              status: "Sent. The saved draft could not be cleared.",
              error: true,
            }),
          );
          await refresh();
        } catch (error) {
          write({
            sending: false,
            status: error instanceof Error ? error.message : String(error),
            error: true,
            focus: true,
          });
        } finally {
          sending = false;
        }
      };
      child.stdout.setEncoding("utf8").on("data", (chunk: string) => {
        buffer += chunk;
        let newline: number;
        while ((newline = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          try {
            const event: unknown = JSON.parse(line);
            if (!event || typeof event !== "object" || Array.isArray(event))
              throw new Error("Invalid chat event.");
            void handle(event).catch((error) => {
              reject(error);
              child.kill("SIGTERM");
            });
          } catch {
            reject(new Error("The chat window returned an invalid response."));
            child.kill("SIGTERM");
          }
        }
      });
      child.stderr.resume();
      child.stdin.on("error", () => undefined);
      child.on("error", (error) => {
        clearInterval(timer);
        process.removeListener("exit", stop);
        reject(
          new Error(
            `Could not open the chat window. Run bun run build:native. ${error.message}`,
          ),
        );
      });
      child.on("close", () => {
        closed = true;
        clearInterval(timer);
        clearTimeout(saveTimer);
        process.removeListener("exit", stop);
        void persist()
          .then(() =>
            closeResult
              ? resolve(closeResult)
              : reject(
                  new Error(
                    "The chat window closed unexpectedly. Your draft was saved. Check Grok Bot before sending it again.",
                  ),
                ),
          )
          .catch(reject);
      });
      write({
        name: bot.name,
        ...nativeAvatar(bot, folder, environment.assetsPath),
        assetsPath: environment.assetsPath,
        draft,
        messages,
        windowPosition: preferences.chatWindowPosition,
        windowSize: preferences.chatWindowSize,
        textSize: Number(preferences.chatTextSize) || undefined,
      });
    },
  );
  if (result.type === "open")
    await open(chatLink(bot.id), "com.anysphere.sand");
  else if (result.back)
    await launchCommand({
      name: "send-message",
      type: LaunchType.UserInitiated,
    });
}
