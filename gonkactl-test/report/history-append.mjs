import { appendFileSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export function appendRenderedHistory(reportRoot, historyPath) {
  const pluginRoot = join(reportRoot, 'awesomeBDD');
  const summary = JSON.parse(readFileSync(join(pluginRoot, 'summary.json'), 'utf8'));
  const resultRoot = join(pluginRoot, 'data', 'test-results');
  const results = readdirSync(resultRoot)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((name) => JSON.parse(readFileSync(join(resultRoot, name), 'utf8')));
  if (!summary.meta?.reportId || !summary.name || results.length === 0) {
    throw new Error('rendered report lacks history provenance');
  }
  const testResults = {};
  for (const result of results) {
    if (!result.id || !result.historyId || !result.testCase?.id || !result.status) {
      throw new Error(`rendered result ${result.id ?? '<unknown>'} is incomplete`);
    }
    testResults[result.historyId] = {
      id: result.id,
      name: result.name,
      fullName: result.fullName,
      environment: result.environment,
      status: result.status,
      message: result.error?.message,
      trace: result.error?.trace,
      start: result.start,
      stop: result.stop,
      duration: result.duration,
      labels: result.labels,
      url: '',
      historyId: result.historyId,
      reportLinks: [],
    };
  }
  const point = {
    uuid: summary.meta.reportId,
    name: summary.name,
    timestamp: Date.now(),
    knownTestCaseIds: results.map((result) => result.testCase.id),
    testResults,
    metrics: {},
    url: '',
  };
  appendFileSync(historyPath, `${JSON.stringify(point)}\n`, { encoding: 'utf8', flush: true });
  return point;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  appendRenderedHistory(process.argv[2], process.argv[3]);
}
