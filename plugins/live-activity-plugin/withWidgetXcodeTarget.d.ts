import { ConfigPlugin } from "@expo/config-plugins";
export interface WidgetXcodeTargetOptions {
    widgetName: string;
    /** `<appBundleId>.<widgetName>` — computed by the entrypoint. */
    bundleIdentifier: string;
    deploymentTarget: string;
}
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
export declare const withWidgetXcodeTarget: ConfigPlugin<WidgetXcodeTargetOptions>;
