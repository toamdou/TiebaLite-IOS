import { XcodeProject } from "@expo/config-plugins";
/**
 * Register the new target in the `PBXProject` section and stamp a
 * `TargetAttributes` entry for it (Xcode keys per-target metadata such as the
 * Swift migration marker here; without it Xcode 14+ may warn on first open).
 */
export declare function addToPbxProjectSection(xcodeProject: XcodeProject, target: {
    uuid: string;
}): void;
