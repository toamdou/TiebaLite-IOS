import { XcodeProject } from "@expo/config-plugins";
/**
 * Create the `PBXNativeTarget` for the widget extension and add it to the
 * project's native-target section.
 *
 * `productType` MUST be `com.apple.product-type.app-extension` (quoted, because
 * node-xcode writes the value verbatim and Xcode expects the dotted identifier
 * as a quoted string). The returned `target` carries the `uuid` reused by the
 * project-section / dependency / build-phase steps.
 */
export declare function addToPbxNativeTargetSection(xcodeProject: XcodeProject, { targetName, targetUuid, productFile, xCConfigurationList, }: {
    targetName: string;
    targetUuid: string;
    productFile: {
        fileRef: string;
    };
    xCConfigurationList: {
        uuid: string;
    };
}): {
    uuid: string;
    pbxNativeTarget: Record<string, unknown>;
};
