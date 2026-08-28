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
exports.addBuildPhases = addBuildPhases;
const util = __importStar(require("util"));
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
const paths_1 = require("../paths");
/**
 * Wire up the four build phases the extension needs, and the copy-files phase
 * on the APP target that actually embeds the `.appex`:
 *
 *   1. `PBXSourcesBuildPhase` on the EXTENSION — compiles the SwiftUI files
 *      (`LiveActivityKitAttributes.swift`, `LiveActivityKitLiveActivity.swift`,
 *      `LiveActivityKitWidgetBundle.swift`).
 *   2. `PBXCopyFilesBuildPhase` on the APP (`Embed Foundation Extensions`,
 *      dstSubfolderSpec 13) — copies the `.appex` into the app's `PlugIns`.
 *   3. `PBXFrameworksBuildPhase` on the EXTENSION — empty; WidgetKit / SwiftUI /
 *      ActivityKit are weak-linked by the Swift compiler, no explicit refs.
 *   4. `PBXResourcesBuildPhase` on the EXTENSION — empty (no asset catalog by
 *      default; the template renders SF Symbols, not bundled images).
 *
 * The copy-files phase is the subtle part: node-xcode's `addBuildPhase` with
 * `'app_extension'` folder type yields the right `dstSubfolderSpec`, but the
 * product build-file has to be pushed onto that phase's `files` array AND
 * registered in `PBXBuildFile` by hand. This is verbatim from the proven
 * `software-mansion-labs/expo-live-activity` plugin — it is the most fragile
 * step and should not be "simplified".
 */
function addBuildPhases(xcodeProject, { targetUuid, groupName, productFile, swiftFiles, widgetName }) {
    const buildPath = `""`;
    const folderType = "app_extension";
    // (1) Sources phase on the extension target.
    xcodeProject.addBuildPhase(swiftFiles, "PBXSourcesBuildPhase", groupName, targetUuid, folderType, buildPath);
    // (2) Embed App Extensions copy-files phase on the APP (first) target.
    xcodeProject.addBuildPhase([], "PBXCopyFilesBuildPhase", groupName, xcodeProject.getFirstTarget().uuid, folderType, buildPath);
    xcodeProject
        .buildPhaseObject("PBXCopyFilesBuildPhase", groupName, productFile.target)
        .files.push({
        value: productFile.uuid,
        comment: util.format("%s in %s", productFile.basename, productFile.group),
    });
    xcodeProject.addToPbxBuildFileSection(productFile);
    // (3) Frameworks phase (empty) on the extension target.
    xcodeProject.addBuildPhase([], "PBXFrameworksBuildPhase", groupName, targetUuid, folderType, buildPath);
    // (4) Resources phase (empty) on the extension target.
    xcodeProject.addBuildPhase([], "PBXResourcesBuildPhase", groupName, targetUuid, folderType, buildPath);
    // (4b) App icon resource on the extension: the widget's Dynamic Island
    // leading + lock-screen card loads it via `UIImage(named: "AppIcon")`.
    // The widget dir sits at `ios/<widgetName>/`; pass the relative path so
    // the file reference resolves against the project root.
    // Guard with the SAME existence check as the copy step in `withWidgetFiles`
    // (source = plugins/live-activity/AppIcon.png): if the icon was never
    // copied, adding the resource reference would point the Resources phase at
    // a file that doesn't exist and break the build.
    const appIconSource = path.join((0, paths_1.getPackageRoot)(), "plugins", "live-activity", "AppIcon.png");
    if (fs.existsSync(appIconSource)) {
        xcodeProject.addResourceFile(`${widgetName}/AppIcon.png`, { target: targetUuid });
    }
}
