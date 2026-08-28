"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.addToPbxProjectSection = addToPbxProjectSection;
/**
 * Register the new target in the `PBXProject` section and stamp a
 * `TargetAttributes` entry for it (Xcode keys per-target metadata such as the
 * Swift migration marker here; without it Xcode 14+ may warn on first open).
 */
function addToPbxProjectSection(xcodeProject, target) {
    xcodeProject.addToPbxProjectSection(target);
    const projectSection = xcodeProject.pbxProjectSection();
    const projectUuid = xcodeProject.getFirstProject().uuid;
    const attributes = projectSection[projectUuid].attributes;
    if (!attributes.TargetAttributes) {
        attributes.TargetAttributes = {};
    }
    attributes.TargetAttributes[target.uuid] = {
        CreatedOnToolsVersion: "14.0",
        LastSwiftMigration: 1500,
    };
}
