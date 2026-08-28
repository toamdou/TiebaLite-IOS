import { XcodeProject } from "@expo/config-plugins";
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
export declare function addBuildPhases(xcodeProject: XcodeProject, { targetUuid, groupName, productFile, swiftFiles, }: {
    targetUuid: string;
    groupName: string;
    productFile: {
        uuid: string;
        target: string;
        basename: string;
        group: string;
    };
    swiftFiles: string[];
}): void;
