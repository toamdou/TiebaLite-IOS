/**
 * Expo config plugin for the first-party `tieba-native` Live Activity widget.
 *
 * Scaffolds a pure-SwiftUI iOS Widget Extension. No JavaScript runs inside the
 * extension; it links only ActivityKit / WidgetKit / SwiftUI and shares the
 * `LiveActivityKitAttributes` type with the app by bare name.
 */
import { ConfigPlugin } from "@expo/config-plugins";
export interface Options {
    /** Name of the widget extension target / folder. Default `LiveActivityKitWidget`. */
    widgetName?: string;
    /** iOS deployment target for the extension. Default `16.2`. */
    deploymentTarget?: string;
    /**
     * App Group id. When set, the App Groups entitlement (with this id) is added
     * to BOTH the app and the extension — needed only to share extra data
     * (images / large state), not for Live Activities themselves.
     */
    appGroup?: string;
    /**
     * Add `NSSupportsLiveActivitiesFrequentUpdates` to the app Info.plist.
     * Default `false`.
     */
    frequentUpdates?: boolean;
    /**
     * Ensure the `aps-environment` entitlement (development) on the APP target so
     * push-driven Live Activity updates work. Default `true`.
     */
    enablePush?: boolean;
}
declare const _default: ConfigPlugin<void | Options>;
export default _default;
