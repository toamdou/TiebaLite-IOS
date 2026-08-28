"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.withWidgetFiles = void 0;
const config_plugins_1 = require("@expo/config-plugins");
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
const paths_1 = require("./paths");
const plist_1 = require("./plist");
/**
 * Copy the canonical SwiftUI sources into `ios/<widgetName>/` and write the
 * extension's `Info.plist` + `<widgetName>.entitlements`.
 *
 * Uses `withDangerousMod('ios', ...)` because we're writing real files to the
 * prebuilt `ios/` directory (the `xcode` mod only edits the pbxproj, it can't
 * create the Swift files the Sources phase references). The mod runs BEFORE the
 * xcodeproj mod is committed — Expo orders `dangerous` mods ahead of the typed
 * `xcodeproj` mod within a platform — so by the time the target's Sources phase
 * is wired up, the files already exist on disk.
 *
 * Everything here is idempotent: copying overwrites with identical bytes and
 * `mkdir` is recursive, so re-running `expo prebuild` is a no-op in effect.
 */
const withWidgetFiles = (config, { widgetName, appGroup, frequentUpdates }) => {
    // 防御（CWE-22）：widgetName 会拼进 `ios/<widgetName>/` 目标目录
    // （path.join(platformRoot, widgetName)），`../` 可越出 ios/ 目录写文件。
    // Xcode target 命名本身也限制为字母数字下划线，此处拒绝其余字符。
    if (!/^[A-Za-z0-9_]+$/.test(widgetName ?? "")) {
        throw new Error(`[tieba-live-activity] Invalid widgetName: ${JSON.stringify(widgetName)}. ` +
            "Only alphanumeric characters and underscores are allowed.");
    }
    return (0, config_plugins_1.withDangerousMod)(config, [
    "ios",
    (cfg) => {
        const platformRoot = cfg.modRequest.platformProjectRoot; // <root>/ios
        // CWE-22 边界校验：path.resolve 生成目标后，必须仍在 <root>/ios/ 之内。
        const targetDir = path.resolve(platformRoot, widgetName);
        if (targetDir !== platformRoot && !targetDir.startsWith(platformRoot + path.sep)) {
            throw new Error(`[tieba-live-activity] widgetName escapes the ios/ directory: ${widgetName}`);
        }
        fs.mkdirSync(targetDir, { recursive: true });
        // 1. Copy the three first-party Swift sources into the extension.
        const packageRoot = (0, paths_1.getPackageRoot)();
        for (const source of (0, paths_1.getExtensionSwiftSources)(packageRoot)) {
            if (!fs.existsSync(source.absolutePath)) {
                throw new Error(`[tieba-live-activity] Expected Swift source not found: ${source.absolutePath}. ` +
                    `Check that 'modules/tieba-native/ios' and 'plugins/live-activity' are present.`);
            }
            fs.copyFileSync(source.absolutePath, path.join(targetDir, source.basename));
        }
        // 1b. Copy the app icon used by the widget's Dynamic Island leading
        //     view + lock-screen card (UIImage(named: "AppIcon") in the
        //     extension bundle; the Xcode target mod adds it to Resources).
        const appIconSource = path.join(packageRoot, "plugins", "live-activity", "AppIcon.png");
        if (fs.existsSync(appIconSource)) {
            fs.copyFileSync(appIconSource, path.join(targetDir, "AppIcon.png"));
        }
        // 2. Write the extension Info.plist. We set the keys explicitly (rather
        //    than relying solely on GENERATE_INFOPLIST_FILE) so the NSExtension
        //    point is guaranteed correct — a wrong/absent NSExtensionPointIdentifier
        //    is the classic "extension builds but never renders" failure.
        const infoPlist = (0, plist_1.buildPlist)({
            CFBundleDevelopmentRegion: "$(DEVELOPMENT_LANGUAGE)",
            CFBundleDisplayName: widgetName,
            CFBundleExecutable: "$(EXECUTABLE_NAME)",
            CFBundleIdentifier: "$(PRODUCT_BUNDLE_IDENTIFIER)",
            CFBundleInfoDictionaryVersion: "6.0",
            CFBundleName: "$(PRODUCT_NAME)",
            CFBundlePackageType: "$(PRODUCT_BUNDLE_PACKAGE_TYPE)",
            CFBundleShortVersionString: "$(MARKETING_VERSION)",
            CFBundleVersion: "$(CURRENT_PROJECT_VERSION)",
            // Mirror the app-side FrequentUpdates key so the extension also
            // advertises support for frequent push-driven refreshes.
            ...(frequentUpdates ? { NSSupportsLiveActivitiesFrequentUpdates: true } : {}),
            NSExtension: {
                NSExtensionPointIdentifier: "com.apple.widgetkit-extension",
            },
        });
        fs.writeFileSync(path.join(targetDir, "Info.plist"), infoPlist);
        // 3. Write the extension entitlements. App Groups only when requested;
        //    Live Activities themselves do not require an app group, so the file
        //    is an empty <dict/> otherwise (the build setting still references it).
        const entitlements = appGroup
            ? (0, plist_1.buildPlist)({
                "com.apple.security.application-groups": [appGroup],
            })
            : (0, plist_1.buildPlist)({});
        fs.writeFileSync(path.join(targetDir, `${widgetName}.entitlements`), entitlements);
        return cfg;
    },
]);
};
exports.withWidgetFiles = withWidgetFiles;
