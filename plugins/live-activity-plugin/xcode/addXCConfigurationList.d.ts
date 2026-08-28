import { XcodeProject } from "@expo/config-plugins";
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
export declare function addXCConfigurationList(xcodeProject: XcodeProject, { targetName, currentProjectVersion, bundleIdentifier, deploymentTarget, marketingVersion, }: {
    targetName: string;
    currentProjectVersion: string;
    bundleIdentifier: string;
    deploymentTarget: string;
    marketingVersion?: string;
}): {
    uuid: string;
};
