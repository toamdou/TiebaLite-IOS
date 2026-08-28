"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.addPbxGroup = addPbxGroup;
/**
 * Create a PBXGroup for the extension (so the files show up under a
 * `<targetName>/` folder in the Xcode navigator) and attach it to the project's
 * top-level group.
 *
 * The "top-level group" is identified the proven way: the single PBXGroup that
 * has neither a `name` nor a `path` is the project root group.
 */
function addPbxGroup(xcodeProject, { targetName, files, }) {
    const { uuid: pbxGroupUuid } = xcodeProject.addPbxGroup(files, targetName, targetName);
    const groups = xcodeProject.hash.project.objects["PBXGroup"];
    if (pbxGroupUuid) {
        Object.keys(groups).forEach((key) => {
            if (groups[key].name === undefined &&
                groups[key].path === undefined &&
                typeof groups[key] === "object") {
                xcodeProject.addToPbxGroup(pbxGroupUuid, key);
            }
        });
    }
}
