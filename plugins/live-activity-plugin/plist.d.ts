/**
 * Minimal, dependency-free plist (XML) serialiser.
 *
 * The plugin only writes two small, fixed-shape plists (the extension's
 * `Info.plist` and its `.entitlements`), so we render them directly rather than
 * taking a runtime dependency on `@expo/plist` / `plist` (neither is a declared
 * dependency of this package; relying on a hoisted transitive would be fragile
 * under EAS's clean installs). Supported value types: string, boolean, number,
 * array, and nested object — which is everything these two files use.
 */
type PlistValue = string | boolean | number | PlistValue[] | {
    [key: string]: PlistValue;
};
export declare function buildPlist(root: {
    [key: string]: PlistValue;
}): string;
export {};
