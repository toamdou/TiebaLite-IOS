"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.addXCConfigurationList = addXCConfigurationList;
/**
 * Create the Debug + Release `XCBuildConfiguration` list for the widget
 * extension target and register it as an `XCConfigurationList`.
 *
 * The build settings here are the minimum needed for a WidgetKit app-extension
 * that ships a Live Activity:
 *   - `SWIFT_VERSION = 5.0`, `APPLICATION_EXTENSION_API_ONLY = YES` (extensions
 *     may only link the app-extension-safe API).
 *   - `INFOPLIST_FILE` / `CODE_SIGN_ENTITLEMENTS` point at the files the
 *     dangerous-mod writes into `ios/<targetName>/`.
 *   - `GENERATE_INFOPLIST_FILE = YES` so Xcode synthesises the standard
 *     `CFBundle*` keys at build time and merges them with the explicit
 *     `NSExtension` dictionary from our `Info.plist` (belt-and-braces: we also
 *     write those keys ourselves, see `withWidgetFiles`).
 *   - `CODE_SIGN_STYLE = Automatic` so EAS-managed credentials sign the appex.
 *
 * Mirrors the proven `software-mansion-labs/expo-live-activity` plugin. Quoting
 * matters: `xcode` (node-xcode) writes these values verbatim into the pbxproj,
 * so string values that must survive as quoted literals are wrapped in `"`.
 */
function addXCConfigurationList(xcodeProject, { targetName, currentProjectVersion, bundleIdentifier, deploymentTarget, marketingVersion, }) {
    const commonBuildSettings = {
        CLANG_ANALYZER_NONNULL: "YES",
        CLANG_ENABLE_OBJC_WEAK: "YES",
        CODE_SIGN_STYLE: "Automatic",
        CURRENT_PROJECT_VERSION: `"${currentProjectVersion}"`,
        GENERATE_INFOPLIST_FILE: "YES",
        INFOPLIST_FILE: `"${targetName}/Info.plist"`,
        INFOPLIST_KEY_CFBundleDisplayName: `"${targetName}"`,
        INFOPLIST_KEY_NSHumanReadableCopyright: '""',
        IPHONEOS_DEPLOYMENT_TARGET: `"${deploymentTarget}"`,
        LD_RUNPATH_SEARCH_PATHS: '"$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"',
        MARKETING_VERSION: `"${marketingVersion !== null && marketingVersion !== void 0 ? marketingVersion : "1.0"}"`,
        MTL_FAST_MATH: "YES",
        PRODUCT_BUNDLE_IDENTIFIER: `"${bundleIdentifier}"`,
        PRODUCT_NAME: '"$(TARGET_NAME)"',
        SKIP_INSTALL: "YES",
        SWIFT_EMIT_LOC_STRINGS: "YES",
        SWIFT_VERSION: "5.0",
        TARGETED_DEVICE_FAMILY: '"1"',
        CODE_SIGN_ENTITLEMENTS: `"${targetName}/${targetName}.entitlements"`,
        APPLICATION_EXTENSION_API_ONLY: "YES",
    };
    const buildConfigurationsList = [
        {
            name: "Debug",
            isa: "XCBuildConfiguration",
            buildSettings: {
                ...commonBuildSettings,
                DEBUG_INFORMATION_FORMAT: "dwarf",
                SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG",
                SWIFT_OPTIMIZATION_LEVEL: '"-Onone"',
            },
        },
        {
            name: "Release",
            isa: "XCBuildConfiguration",
            buildSettings: {
                ...commonBuildSettings,
                DEBUG_INFORMATION_FORMAT: '"dwarf-with-dsym"',
                SWIFT_OPTIMIZATION_LEVEL: '"-O"',
                COPY_PHASE_STRIP: "NO",
            },
        },
    ];
    const xCConfigurationList = xcodeProject.addXCConfigurationList(buildConfigurationsList, "Release", `Build configuration list for PBXNativeTarget "${targetName}"`);
    return xCConfigurationList;
}
