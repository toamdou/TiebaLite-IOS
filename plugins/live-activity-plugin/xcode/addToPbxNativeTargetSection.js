"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.addToPbxNativeTargetSection = addToPbxNativeTargetSection;
/**
 * Create the `PBXNativeTarget` for the widget extension and add it to the
 * project's native-target section.
 *
 * `productType` MUST be `com.apple.product-type.app-extension` (quoted, because
 * node-xcode writes the value verbatim and Xcode expects the dotted identifier
 * as a quoted string). The returned `target` carries the `uuid` reused by the
 * project-section / dependency / build-phase steps.
 */
function addToPbxNativeTargetSection(xcodeProject, { targetName, targetUuid, productFile, xCConfigurationList, }) {
    const target = {
        uuid: targetUuid,
        pbxNativeTarget: {
            isa: "PBXNativeTarget",
            name: targetName,
            productName: targetName,
            productReference: productFile.fileRef,
            productType: '"com.apple.product-type.app-extension"',
            buildConfigurationList: xCConfigurationList.uuid,
            buildPhases: [],
            buildRules: [],
            dependencies: [],
        },
    };
    xcodeProject.addToPbxNativeTargetSection(target);
    return target;
}
