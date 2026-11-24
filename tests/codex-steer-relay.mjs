import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const args = process.argv.slice(2);
const appServer = args.includes("app-server");
const codex = spawn(process.env.CYDO_REAL_CODEX_BIN, args, {
  stdio: appServer ? ["pipe", "pipe", "inherit"] : "inherit",
});
codex.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code);
});

if (appServer) {
  let steer;
  const requests = createInterface({ input: process.stdin });
  const responses = createInterface({ input: codex.stdout });

  requests.on("line", async (line) => {
    const frame = JSON.parse(line);
    if (frame.method !== "turn/steer") {
      codex.stdin.write(line + "\n");
      return;
    }

    if (steer) throw new Error("The relay expects one outstanding steer");
    steer = { line, turnId: frame.params.expectedTurnId };
    const release = await fetch(
      "http://127.0.0.1:9000/api/release-rejected-steer-carrier",
      { method: "POST" },
    );
    if (!release.ok) throw new Error("The mock did not hold the carrier turn");
  });
  requests.on("close", () => codex.stdin.end());

  responses.on("line", (line) => {
    const frame = JSON.parse(line);
    process.stdout.write(line + "\n");
    if (
      frame.method === "turn/completed" &&
      steer &&
      frame.params.turn.id === steer.turnId
    ) {
      codex.stdin.write(steer.line + "\n");
      steer = undefined;
    }
  });
}
