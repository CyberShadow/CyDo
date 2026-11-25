import { monitorEventLoopDelay } from "node:perf_hooks";

const HEARTBEAT_MS = 100;
const STALL_MS = 500;

export function monitorEventLoop(log) {
  const delay = monitorEventLoopDelay({ resolution: 20 });
  delay.enable();

  let previousTick = performance.now();
  let previousCpu = process.cpuUsage();
  let heartbeats = 0;
  let maxGap = 0;
  let stalls = 0;

  function sampleGap() {
    const now = performance.now();
    const gap = now - previousTick;
    const cpu = process.cpuUsage(previousCpu);
    previousTick = now;
    previousCpu = process.cpuUsage();
    maxGap = Math.max(maxGap, gap);
    if (gap > STALL_MS) {
      stalls++;
      log(
        `event loop stall start=${new Date(Date.now() - gap).toISOString()} gap=${gap.toFixed(1)}ms user=${(cpu.user / 1e3).toFixed(1)}ms system=${(cpu.system / 1e3).toFixed(1)}ms`,
      );
    }
  }

  setInterval(() => {
    heartbeats++;
    sampleGap();
  }, HEARTBEAT_MS).unref();

  process.once("SIGTERM", () => {
    sampleGap();
    log(
      `event loop summary heartbeats=${heartbeats} maxGap=${maxGap.toFixed(1)}ms stalls=${stalls} histogram max=${(delay.max / 1e6).toFixed(1)}ms p99=${(delay.percentile(99) / 1e6).toFixed(1)}ms mean=${(delay.mean / 1e6).toFixed(1)}ms`,
    );
    process.exit(0);
  });
}
