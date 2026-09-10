import { defineConfig } from 'allure';

export default defineConfig({
  name: 'gonkactl-test M0 authentic event qualification',
  output: process.env.GONKACTL_TEST_REPORT_OUTPUT || '../build/gonkactl-test/report/render',
  historyPath: process.env.GONKACTL_TEST_HISTORY_PATH || '../build/gonkactl-test/history/m0/history.jsonl',
  appendHistory: process.env.GONKACTL_TEST_APPEND_HISTORY === 'true',
  plugins: {
    awesomeBDD: {
      import: '@allurereport/plugin-awesome',
      options: {
        reportName: 'gonkactl-test M0 authentic event qualification',
        singleFile: false,
        reportLanguage: 'en',
        open: false,
        groupBy: ['epic', 'feature', 'story'],
      },
    },
    dashboard: {
      options: {
        reportName: 'gonkactl-test M0 authentic event qualification',
        singleFile: false,
        reportLanguage: 'en',
      },
    },
    csv: { options: { fileName: 'report.csv' } },
  },
});
