import { ConfigPlugin } from "@expo/config-plugins";
export interface WidgetFilesOptions {
    widgetName: string;
    /** App-group id to embed in the extension entitlements, or `undefined`. */
    appGroup?: string;
}
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
export declare const withWidgetFiles: ConfigPlugin<WidgetFilesOptions>;
