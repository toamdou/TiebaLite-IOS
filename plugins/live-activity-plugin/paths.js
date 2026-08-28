"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.getPackageRoot = getPackageRoot;
exports.getExtensionSwiftSources = getExtensionSwiftSources;
const path = __importStar(require("path"));
/**
 * Resolve the TiebaLite project root so the first-party Swift sources can be
 * copied into the generated widget extension.
 */
function getPackageRoot() {
    return path.resolve(__dirname, "..", "..");
}
/**
 * The three Swift files that must be compiled into the widget extension.
 *
 *   - `LiveActivityKitAttributes.swift` lives in `ios/` because it is the
 *     SHARED source of truth also compiled into the app via the pod. The plugin
 *     copies (does not symlink) it so the extension owns its own membership and
 *     EAS's clean checkout has the bytes it needs.
 *   - The two UI files under `plugins/live-activity/` are compiled only into
 *     the extension.
 */
function getExtensionSwiftSources(packageRoot) {
    const sources = [
        path.join(packageRoot, "modules", "tieba-native", "ios", "LiveActivityKitAttributes.swift"),
        path.join(packageRoot, "plugins", "live-activity", "LiveActivityKitLiveActivity.swift"),
        path.join(packageRoot, "plugins", "live-activity", "LiveActivityKitWidgetBundle.swift"),
    ];
    return sources.map((absolutePath) => ({
        absolutePath,
        basename: path.basename(absolutePath),
    }));
}
