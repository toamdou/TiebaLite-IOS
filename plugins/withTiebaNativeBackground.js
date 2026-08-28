const { withInfoPlist } = require('@expo/config-plugins');

const TASK_IDS = [
  'com.tiebalite.app.notification-sync',
  'com.tiebalite.app.auto-sign',
];

// UIBackgroundModes entries required by our BGTaskScheduler tasks:
//   - `fetch`      — required for BGAppRefreshTask (notification-sync)
//   - `processing` — required for BGProcessingTask (auto-sign)
const EXTRA_BACKGROUND_MODES = ['fetch', 'processing'];

module.exports = function withTiebaNativeBackground(config) {
  return withInfoPlist(config, (cfg) => {
    const existing = cfg.modResults.BGTaskSchedulerPermittedIdentifiers ?? [];
    const merged = Array.from(new Set([...existing, ...TASK_IDS]));
    cfg.modResults.BGTaskSchedulerPermittedIdentifiers = merged;

    // MERGE (not overwrite) UIBackgroundModes: other plugins / app.json may
    // already contribute keys (e.g. `audio` from expo-audio). We only append
    // what our background tasks need and dedupe.
    const modes = Array.isArray(cfg.modResults.UIBackgroundModes)
      ? cfg.modResults.UIBackgroundModes
      : [];
    cfg.modResults.UIBackgroundModes = Array.from(
      new Set([...modes, ...EXTRA_BACKGROUND_MODES])
    );
    return cfg;
  });
};
