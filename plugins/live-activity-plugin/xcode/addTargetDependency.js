"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.addTargetDependency = addTargetDependency;
/**
 * Make the app target depend on the widget extension target so the appex is
 * always (re)built before the app that embeds it.
 *
 * node-xcode's `addTargetDependency` will throw if the `PBXTargetDependency` /
 * `PBXContainerItemProxy` sections don't yet exist (a fresh prebuild often has
 * none), so we initialise them first — this guard is the proven idiom from
 * `software-mansion-labs/expo-live-activity`.
 */
function addTargetDependency(xcodeProject, target) {
    const objects = xcodeProject.hash.project.objects;
    if (!objects["PBXTargetDependency"]) {
        objects["PBXTargetDependency"] = {};
    }
    if (!objects["PBXContainerItemProxy"]) {
        objects["PBXContainerItemProxy"] = {};
    }
    xcodeProject.addTargetDependency(xcodeProject.getFirstTarget().uuid, [
        target.uuid,
    ]);
}
