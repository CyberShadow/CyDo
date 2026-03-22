import type { Reporter, TestCase, TestResult } from '@playwright/test/reporter';
import { readFileSync } from 'fs';

class LogReporter implements Reporter {
  onTestEnd(test: TestCase, result: TestResult) {
    if (result.status === 'passed' || result.status === 'skipped')
      return;

    for (const attachment of result.attachments) {
      if (attachment.name.startsWith('_')) continue;
      if (!attachment.contentType.startsWith('text/')) continue;

      let content: string | null = null;
      if (attachment.body) {
        content = attachment.body.toString();
      } else if (attachment.path) {
        try { content = readFileSync(attachment.path, 'utf-8'); } catch {}
      }
      if (!content) continue;

      const title = test.titlePath().slice(1).join(' > ');
      process.stdout.write(`\n${'─'.repeat(60)}\n`);
      process.stdout.write(`ATTACHMENT: ${attachment.name} [${title}]\n`);
      process.stdout.write(`${'─'.repeat(60)}\n`);
      process.stdout.write(content);
      if (!content.endsWith('\n')) process.stdout.write('\n');
    }
  }

  printsToStdio() { return false; }
}

export default LogReporter;
