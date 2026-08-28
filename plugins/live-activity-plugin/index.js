"use strict";
/**
 * Expo config plugin for TiebaLite Live Activity widget extension.
 *
 * Scaffolds a PURE-SwiftUI iOS Widget Extension that renders Live Activities.
 * No JavaScript runs inside the extension — the appex links only ActivityKit /
 * WidgetKit / SwiftUI and shares the `LiveActivityKitAttributes` type with the
 * app by bare name. Running JS in a widget appex is what triggers the
 * Hermes-in-appex blank-render bug; this plugin deliberately avoids it by never
 * embedding the React Native runtime in the extension.
 *
 * What it does, each as a discrete `withX` mod so failures are localised:
 *
 *   1. App `Info.plist`     — `NSSupportsLiveActivities` (+ FrequentUpdates).
 *   2. App entitlements     — `aps-environment` (push) + App Group (optional).
 *   3. EAS app-extension    — register the appex under
 *      `extra.eas.build.experimental.ios.appExtensions` so EAS Build provisions
 *      a bundle id and (optional) App Group for the extension. Without this,
 *      EAS-managed credentials don't know the appex exists and signing fails.
 *   4. Widget files         — copy the SwiftUI + shared attributes file and
 *      write the extension `Info.plist` / `.entitlements` (dangerous mod).
 *   5. Xcode target         — add the app-extension `PBXNativeTarget`, embed it,
 *      and depend on it (node-xcode; the fragile part — see
 *      `withWidgetXcodeTarget`).
 *
 * Usage in `app.json` / `app.config.ts`:
 *
 *   ["./plugins/withTiebaLiveActivity", {
 *     "widgetName": "MyLiveActivity",
 *     "deploymentTarget": "16.2",
 *     "appGroup": "group.com.acme.app",
 *     "frequentUpdates": true,
 *     "enablePush": true
 *   }]
 */
Object.defineProperty(exports, "__esModule", { value: true });
const config_plugins_1 = require("@expo/config-plugins");
const withWidgetFiles_1 = require("./withWidgetFiles");
const withWidgetXcodeTarget_1 = require("./withWidgetXcodeTarget");
const pkg = require("../../package.json");
const DEFAULTS = {
    widgetName: "LiveActivityKitWidget",
    deploymentTarget: "16.2",
    frequentUpdates: false,
    // Off by default: the TiebaLite app itself does not subscribe to push
    // (app.json sets enablePush explicitly where needed). Setting it here only
    // adds `aps-environment` to the APP entitlements.
    enablePush: false,
};
const APP_GROUPS_KEY = "com.apple.security.application-groups";
// ───────────────────────────────────────────────────────────────────────────
// 1. App Info.plist — Live Activity support flags.
// ───────────────────────────────────────────────────────────────────────────
const withLiveActivityInfoPlist = (config, { frequentUpdates }) => (0, config_plugins_1.withInfoPlist)(config, (cfg) => {
    cfg.modResults.NSSupportsLiveActivities = true;
    if (frequentUpdates) {
        cfg.modResults.NSSupportsLiveActivitiesFrequentUpdates = true;
    }
    return cfg;
});
// ───────────────────────────────────────────────────────────────────────────
// 2. App entitlements — push + App Group (on the app side).
// ───────────────────────────────────────────────────────────────────────────
const withAppEntitlements = (config, { enablePush, appGroup }) => (0, config_plugins_1.withEntitlementsPlist)(config, (cfg) => {
    if (enablePush && !cfg.modResults["aps-environment"]) {
        // `development` is correct for dev + TestFlight; EAS rewrites this to
        // `production` for store builds via its credentials flow.
        cfg.modResults["aps-environment"] = "development";
    }
    if (appGroup) {
        const existing = Array.isArray(cfg.modResults[APP_GROUPS_KEY])
            ? cfg.modResults[APP_GROUPS_KEY]
            : [];
        if (!existing.includes(appGroup)) {
            cfg.modResults[APP_GROUPS_KEY] = [...existing, appGroup];
        }
    }
    return cfg;
});
// Merge an appex's declared entitlements with the patch this plugin writes:
// per-key, union-ing app-group id arrays so existing entries are never lost.
const mergeEntitlements = (base, patch) => {
    const merged = { ...(base !== null && base !== void 0 ? base : {}) };
    for (const [key, value] of Object.entries(patch)) {
        if (key === APP_GROUPS_KEY) {
            const existing = Array.isArray(merged[key])
                ? merged[key]
                : [];
            merged[key] = Array.from(new Set([...existing, ...value]));
        }
        else {
            merged[key] = value;
        }
    }
    return merged;
};
// ───────────────────────────────────────────────────────────────────────────
// 3. EAS app-extension registration (so EAS Build provisions the appex).
// ───────────────────────────────────────────────────────────────────────────
const withEasAppExtension = (config, { widgetName, bundleIdentifier, appGroup }) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r;
    const appExtensions = (_f = (_e = (_d = (_c = (_b = (_a = config.extra) === null || _a === void 0 ? void 0 : _a.eas) === null || _b === void 0 ? void 0 : _b.build) === null || _c === void 0 ? void 0 : _c.experimental) === null || _d === void 0 ? void 0 : _d.ios) === null || _e === void 0 ? void 0 : _e.appExtensions) !== null && _f !== void 0 ? _f : [];
    const entry = { targetName: widgetName, bundleIdentifier };
    if (appGroup) {
        entry.entitlements = { [APP_GROUPS_KEY]: [appGroup] };
    }
    const existingIndex = appExtensions.findIndex((ext) => ext.targetName === widgetName);
    const nextAppExtensions = existingIndex >= 0
        ? appExtensions.map((ext, i) => {
            if (i !== existingIndex) {
                return ext;
            }
            // Merge (not overwrite) entitlements: a wholesale `{ ...ext, ...entry }`
            // would drop keys the appex already declares (e.g. aps-environment).
            const mergedEntry = { ...ext, ...entry };
            if (entry.entitlements) {
                mergedEntry.entitlements = mergeEntitlements(ext.entitlements, entry.entitlements);
            }
            return mergedEntry;
        })
        : [...appExtensions, entry];
    config.extra = {
        ...config.extra,
        eas: {
            ...(_g = config.extra) === null || _g === void 0 ? void 0 : _g.eas,
            build: {
                ...(_j = (_h = config.extra) === null || _h === void 0 ? void 0 : _h.eas) === null || _j === void 0 ? void 0 : _j.build,
                experimental: {
                    ...(_m = (_l = (_k = config.extra) === null || _k === void 0 ? void 0 : _k.eas) === null || _l === void 0 ? void 0 : _l.build) === null || _m === void 0 ? void 0 : _m.experimental,
                    ios: {
                        ...(_r = (_q = (_p = (_o = config.extra) === null || _o === void 0 ? void 0 : _o.eas) === null || _p === void 0 ? void 0 : _p.build) === null || _q === void 0 ? void 0 : _q.experimental) === null || _r === void 0 ? void 0 : _r.ios,
                        appExtensions: nextAppExtensions,
                    },
                },
            },
        },
    };
    return config;
};
// ───────────────────────────────────────────────────────────────────────────
// Entry point.
// ───────────────────────────────────────────────────────────────────────────
const withLiveActivityKit = (config, options) => {
    var _a;
    const opts = { ...DEFAULTS, ...(options !== null && options !== void 0 ? options : {}) };
    const widgetName = opts.widgetName;
    // Fail fast at the plugin entry: widgetName is spliced into the filesystem
    // path `ios/<widgetName>/` and the Xcode target name, so it must be a bare
    // identifier. `withWidgetFiles` re-validates later as a second line of
    // defence (CWE-22), but the sooner we throw, the cleaner the error.
    if (!/^[A-Za-z0-9_]+$/.test(widgetName !== null && widgetName !== void 0 ? widgetName : "")) {
        throw new Error(`[tieba-live-activity] Invalid widgetName: ${JSON.stringify(widgetName)}. ` +
            "Only alphanumeric characters and underscores are allowed.");
    }
    const appBundleId = (_a = config.ios) === null || _a === void 0 ? void 0 : _a.bundleIdentifier;
    if (!appBundleId) {
        // Without the app bundle id we can't derive the extension's id, and EAS
        // signing would fail anyway. Fail loud and early with an actionable message.
        throw new Error("[tieba-live-activity] `ios.bundleIdentifier` must be set in your app config before this plugin runs " +
            "(it derives the widget extension bundle id from it).");
    }
    const extensionBundleId = `${appBundleId}.${widgetName}`;
    // 1. App Info.plist.
    config = withLiveActivityInfoPlist(config, {
        frequentUpdates: opts.frequentUpdates,
    });
    // 2. App entitlements.
    config = withAppEntitlements(config, {
        enablePush: opts.enablePush,
        appGroup: opts.appGroup,
    });
    // 3. EAS app-extension registration.
    config = withEasAppExtension(config, {
        widgetName,
        bundleIdentifier: extensionBundleId,
        appGroup: opts.appGroup,
    });
    // 4. Write the extension's Swift sources, Info.plist and entitlements.
    config = (0, withWidgetFiles_1.withWidgetFiles)(config, {
        widgetName,
        appGroup: opts.appGroup,
        frequentUpdates: opts.frequentUpdates,
    });
    // 5. Create + embed the Xcode target (must run after the files exist).
    config = (0, withWidgetXcodeTarget_1.withWidgetXcodeTarget)(config, {
        widgetName,
        bundleIdentifier: extensionBundleId,
        deploymentTarget: opts.deploymentTarget,
    });
    return config;
};
exports.default = (0, config_plugins_1.createRunOncePlugin)(withLiveActivityKit, pkg.name, pkg.version);
