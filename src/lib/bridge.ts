import { closeMainWindow, environment } from "@raycast/api";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { Bot, loadRoster, persistenceFilename } from "./roster";

export async function sendMessage(
  bot: Bot,
  message: string,
  folder: string,
  accountSlot: string,
): Promise<void> {
  if (!message.trim()) throw new Error("Enter a message first.");
  const current = await loadRoster(folder);
  if (current.accountSlot !== accountSlot)
    throw new Error(
      "The Grok Bot account changed. Refresh the bot list before sending.",
    );
  const sameName = current.bots.filter((item) => item.name === bot.name);
  if (!sameName.some((item) => item.id === bot.id)) {
    throw new Error(
      "This bot changed or left the sidebar. Refresh the bot list before sending.",
    );
  }
  await closeMainWindow();
  await new Promise<void>((resolve, reject) => {
    const child = spawn(join(environment.assetsPath, "grok-bridge"), [], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let output = "";
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      reject(
        new Error(
          "Grok Bot timed out. Check the selected chat before retrying, as the message may have been sent.",
        ),
      );
    }, 35_000);
    child.stdout
      .setEncoding("utf8")
      .on("data", (chunk: string) => (output += chunk));
    child.stderr.resume();
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(
        new Error(
          `Could not start the Grok Bot bridge. Run bun run build:native. ${error.message}`,
        ),
      );
    });
    child.on("close", () => {
      clearTimeout(timeout);
      try {
        const result: { ok?: boolean; error?: string } = JSON.parse(output);
        if (result.ok) resolve();
        else
          reject(
            new Error(
              result.error ||
                "Could not send the message. Check Grok Bot before retrying.",
            ),
          );
      } catch {
        reject(
          new Error(
            "The Grok Bot bridge stopped unexpectedly. Check the chat before retrying.",
          ),
        );
      }
    });
    child.stdin.on("error", () => undefined);
    const persistence = join(folder, "sand-client-persistence");
    child.stdin.end(
      JSON.stringify({
        id: bot.id,
        name: bot.name,
        message,
        accountSlot,
        accountPath: join(
          persistence,
          persistenceFilename("sand.client.slice.client-meta.account-slot"),
        ),
        selectionPath: join(
          persistence,
          persistenceFilename(
            `sand.client.slice.account.${encodeURIComponent(accountSlot)}.selection.last-agent`,
          ),
        ),
        lockPath: join(environment.supportPath, "send.lock"),
        allowBackgroundReuse: sameName.length === 1,
      }),
    );
  });
}
