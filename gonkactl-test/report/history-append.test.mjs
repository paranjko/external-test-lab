import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { appendRenderedHistory } from './history-append.mjs';

test('history append closes synchronously and emits one complete point', () => {
  assert.ok(process.env.TMPDIR, 'persistent TMPDIR is required');
  const root = mkdtempSync(join(process.env.TMPDIR, 'history-append-'));
  const plugin = join(root, 'render', 'awesomeBDD');
  const results = join(plugin, 'data', 'test-results');
  mkdirSync(results, { recursive: true });
  writeFileSync(join(plugin, 'summary.json'), JSON.stringify({ name: 'report', meta: { reportId: 'report-1' } }));
  writeFileSync(join(results, 'result.json'), JSON.stringify({ id: 'execution-1', historyId: 'history-1', testCase: { id: 'case-1' }, name: 'case', fullName: 'feature:case', environment: 'default', status: 'passed', start: 10, stop: 11, duration: 1, labels: [] }));
  const history = join(root, 'history.jsonl');
  appendRenderedHistory(join(root, 'render'), history);
  const lines = readFileSync(history, 'utf8').trim().split('\n');
  assert.equal(lines.length, 1);
  const point = JSON.parse(lines[0]);
  assert.equal(point.uuid, 'report-1');
  assert.deepEqual(point.knownTestCaseIds, ['case-1']);
  assert.equal(point.testResults['history-1'].id, 'execution-1');
});
