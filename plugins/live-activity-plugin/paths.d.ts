/**
 * Resolve the first-party `tieba-native` Swift sources that get copied into
 * the generated Live Activity widget extension.
 */
export declare function getPackageRoot(): string;
/**
 * The three Swift files that must be compiled into the widget extension.
 *
 *   - `LiveActivityKitAttributes.swift` is the shared source of truth also
 *     compiled into the app via the pod.
 *   - The two UI files under `plugins/live-activity/` are compiled only into
 *     the extension.
 */
export declare function getExtensionSwiftSources(packageRoot: string): {
    absolutePath: string;
    basename: string;
}[];
