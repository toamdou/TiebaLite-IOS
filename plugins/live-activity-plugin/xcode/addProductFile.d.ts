import { XcodeProject } from "@expo/config-plugins";
/**
 * Register the `<targetName>.appex` product as a PBXFileReference so the new
 * target has something to produce and the app's "Embed Foundation Extensions"
 * copy-files phase has something to embed.
 *
 * `node-xcode`'s `addProductFile` returns an object carrying both `uuid`
 * (build-file) and `fileRef` (file-reference) ids that the later phases need.
 */
export declare function addProductFile(xcodeProject: XcodeProject, { targetName, groupName }: {
    targetName: string;
    groupName: string;
}): {
    uuid: string;
    fileRef: string;
    target: string;
    basename: string;
    group: string;
};
