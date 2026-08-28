/**
 * dev-only 噪声过滤：expo-notifications 读模拟器 Keychain 的已知无害错误
 * （ERR_NOTIFICATIONS_KEYCHAIN_ACCESS，仅影响推送注册缓存，不影响功能）。
 *
 * 该错误在启动早期由 expo-notifications 内部自抛 console.error；LogBox.ignoreLogs
 * 在 RN 0.86 下对这类模块内错误偶发漏网，导致 dev 底部常驻全宽
 * "Open debugger to view warnings." 横幅——恰好遮住整个底栏区域，还跟着
 * 内容一起出现在"底栏自动隐藏后"的位置。这里在本模块最先 import 时于
 * 源头过滤，release 构建不参与。
 */
if (__DEV__) {
  const originalError = console.error.bind(console);
  console.error = (...args: unknown[]) => {
    const head = String(args[0] ?? '');
    if (
      head.includes('Error reading persisted server registration info') ||
      head.includes('ERR_NOTIFICATIONS_KEYCHAIN_ACCESS')
    ) {
      return;
    }
    originalError(...args);
  };
}