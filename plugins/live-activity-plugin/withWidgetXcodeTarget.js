"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.withWidgetXcodeTarget = void 0;
const config_plugins_1 = require("@expo/config-plugins");
const paths_1 = require("./paths");
const addBuildPhases_1 = require("./xcode/addBuildPhases");
const addPbxGroup_1 = require("./xcode/addPbxGroup");
const addProductFile_1 = require("./xcode/addProductFile");
const addTargetDependency_1 = require("./xcode/addTargetDependency");
const addToPbxNativeTargetSection_1 = require("./xcode/addToPbxNativeTargetSection");
const addToPbxProjectSection_1 = require("./xcode/addToPbxProjectSection");
const addXCConfigurationList_1 = require("./xcode/addXCConfigurationList");
/**
 * Add the widget-extension `PBXNativeTarget` to the Xcode project.
 *
 * ⚠️ Adding an app-extension target via node-xcode is inherently fragile: the
 * pbxproj is a hand-rolled object graph and the `xcode` package exposes only a
 * thin, partially-typed wrapper. This implementation deliberately follows the
 * exact call sequence proven by `software-mansion-labs/expo-live-activity`
 * (which scaffolded an identical Live Activity extension target) rather than
 * inventing one:
 *
 *   1. addXCConfigurationList   — Debug/Release build settings
 *   2. addProductFile           — the `.appex` product reference
 *   3. addToPbxNativeTargetSection — the target itself (app-extension type)
 *   4. addToPbxProjectSection   — register target + TargetAttributes
 *   5. addTargetDependency      — app target depends on the extension
 *   6. addBuildPhases           — Sources/Frameworks/Resources + app's Embed phase
 *   7. addPbxGroup              — navigator group for the files
 *
 * Idempotency: if a target named `<widgetName>` already exists (re-running
 * `expo prebuild`, or prebuild over a committed `ios/`), we bail out early so
 * the steps above never duplicate the target, product, or phases.
 */
const withWidgetXcodeTarget = (config, { widgetName, bundleIdentifier, deploymentTarget }) => (0, config_plugins_1.withXcodeProject)(config, (cfg) => {
    var _a, _b;
    const xcodeProject = cfg.modResults;
    // ── Idempotency guard ──────────────────────────────────────────────
    // `pbxTargetByName` returns the target if one with this name exists.
    const existingTarget = xcodeProject.pbxTargetByName(widgetName);
    if (existingTarget) {
        return cfg;
    }
    const targetUuid = xcodeProject.generateUuid();
    // "Embed Foundation Extensions" is the canonical group/phase name Xcode
    // itself uses for embedded app extensions; reusing it keeps the project
    // looking native and lets the copy-files phase land in the right place.
    const groupName = "Embed Foundation Extensions";
    const marketingVersion = (_a = cfg.version) !== null && _a !== void 0 ? _a : "1.0";
    const currentProjectVersion = ((_b = cfg.ios) === null || _b === void 0 ? void 0 : _b.buildNumber) || "1";
    // The Swift sources written by `withWidgetFiles` (referenced by basename;
    // the PBXGroup is rooted at `ios/<widgetName>/`).
    const swiftBasenames = (0, paths_1.getExtensionSwiftSources)((0, paths_1.getPackageRoot)()).map((s) => s.basename);
    const xCConfigurationList = (0, addXCConfigurationList_1.addXCConfigurationList)(xcodeProject, {
        targetName: widgetName,
        currentProjectVersion,
        bundleIdentifier,
        deploymentTarget,
        marketingVersion,
    });
    const productFile = (0, addProductFile_1.addProductFile)(xcodeProject, {
        targetName: widgetName,
        groupName,
    });
    const target = (0, addToPbxNativeTargetSection_1.addToPbxNativeTargetSection)(xcodeProject, {
        targetName: widgetName,
        targetUuid,
        productFile,
        xCConfigurationList,
    });
    (0, addToPbxProjectSection_1.addToPbxProjectSection)(xcodeProject, target);
    (0, addTargetDependency_1.addTargetDependency)(xcodeProject, target);
    (0, addBuildPhases_1.addBuildPhases)(xcodeProject, {
        targetUuid,
        groupName,
        productFile,
        swiftFiles: swiftBasenames,
        widgetName,
    });
    (0, addPbxGroup_1.addPbxGroup)(xcodeProject, {
        targetName: widgetName,
        // List the on-disk files so they appear under the navigator group.
        files: [...swiftBasenames, "Info.plist", `${widgetName}.entitlements`],
    });
    return cfg;
});
exports.withWidgetXcodeTarget = withWidgetXcodeTarget;
