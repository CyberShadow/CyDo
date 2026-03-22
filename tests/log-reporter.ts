import type { Reporter, TestCase, TestResult } from '@playwright/test/reporter';

type LogEntry = { ts: number; source: string; text: string };

class LogReporter implements Reporter {
  onTestEnd(test: TestCase, result: TestResult) {
    if (result.status === 'passed' || result.status === 'skipped')
      return;

    // Collect server log entries from JSON attachment
    const entries: LogEntry[] = [];

    for (const att of result.attachments) {
      if (att.name === 'server-log' && att.body) {
        try {
          const parsed: LogEntry[] = JSON.parse(att.body.toString());
          entries.push(...parsed);
        } catch {}
      }
    }

    // Flatten Playwright steps into log entries
    function flattenSteps(steps: TestResult['steps'], depth = 0) {
      for (const step of steps) {
        if (step.category === 'pw:api' || step.category === 'expect') {
          const suffix = step.error ? ' FAILED' : '';
          entries.push({
            ts: step.startTime.getTime(),
            source: 'pw',
            text: `${step.title}${suffix}`,
          });
        }
        if (step.steps.length > 0 && depth < 1) {
          flattenSteps(step.steps, depth + 1);
        }
      }
    }
    flattenSteps(result.steps);

    if (entries.length === 0) return;

    // Sort by timestamp and format
    entries.sort((a, b) => a.ts - b.ts);
    const t0 = entries[0].ts;
    const formatted = entries.map(e =>
      `+${String(e.ts - t0).padStart(6)}ms [${e.source.padEnd(8)}] ${e.text}`
    ).join('\n');

    const title = test.titlePath().slice(1).join(' > ');
    process.stdout.write(`\n${'─'.repeat(60)}\n`);
    process.stdout.write(`LOG: ${title}\n`);
    process.stdout.write(`${'─'.repeat(60)}\n`);
    process.stdout.write(formatted);
    if (!formatted.endsWith('\n')) process.stdout.write('\n');
  }

  printsToStdio() { return false; }
}

export default LogReporter;
