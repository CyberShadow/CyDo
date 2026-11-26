import type { RunnerTask, RunnerTestFile } from "vitest";
import { VitestTestRunner } from "vitest/runners";

export default class TimeoutIsolationRunner extends VitestTestRunner {
  private readonly timedOutFiles = new WeakSet<RunnerTestFile>();

  override async onBeforeRunTask(task: RunnerTask) {
    if (
      this.timedOutFiles.has(task.file) &&
      (task.mode === "run" || task.mode === "queued")
    ) {
      task.mode = "skip";
      task.result = { state: "skip" };
    }
    await super.onBeforeRunTask(task);
  }

  override onAfterRunTask(task: RunnerTask) {
    // A timed-out body can keep running and interfere with later tests in its file.
    // Suite hooks have no test context signal. Expected failures report as passing.
    if (
      task.type === "test" &&
      task.result?.state === "fail" &&
      task.context.signal.aborted
    ) {
      this.timedOutFiles.add(task.file);
    }
    super.onAfterRunTask(task);
  }
}
