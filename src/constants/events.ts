/**
 * Tab 重选事件：NativeTabs.Trigger 的 tabPress 监听器在“点中当前已聚焦的 Tab”时
 * 通过 DeviceEventEmitter 全局广播，各 Tab 页据此做轻量刷新/重拉
 * （emit 无订阅者时零开销）。
 *
 * 共用方：index / _layout / explore。notifications / profile 仍持有本地副本
 * （constants/events.ts 此前不存在），留待后续轮统一收敛。
 */
export const TAB_RESELECT_EVENT = 'tieba:tab-reselect';