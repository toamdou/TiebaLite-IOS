import { XcodeProject } from "@expo/config-plugins";
/**
 * Make the app target depend on the widget extension target so the appex is
 * always (re)built before the app that embeds it.
 *
 * node-xcode's `addTargetDependency` will throw if the `PBXTargetDependency` /
 * `PBXContainerItemProxy` sections don't yet exist (a fresh prebuild often has
 * none), so we initialise them first — this guard is the proven idiom from
 * `software-mansion-labs/expo-live-activity`.
 */
export declare function addTargetDependency(xcodeProject: XcodeProject, target: {
    uuid: string;
}): void;
