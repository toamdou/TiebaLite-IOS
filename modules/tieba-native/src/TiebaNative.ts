import { requireOptionalNativeModule } from 'expo';
import type { SignLiveActivityState } from '../../../src/services/sign/signSnapshot';

export interface ProtoPostRequest {
  url: string;
  headers: Record<string, string>;
  formFields: [string, string][];
  protoDataBase64: string;
  skipSign: boolean;
  responseType: string;
  requestId: string;
  timeoutMs?: number;
}

export interface TiebaNativeModule {
  /** 大图查看器：隐藏/恢复状态栏（RN StatusBar 在 iOS 27 失效，须走原生 VC 级） */
  setModalStatusBarHidden(hidden: boolean): void;
  /** 设置 → 震动反馈总开关：同步给原生，闸住 chrome 按压触觉 */
  setHapticFeedbackEnabled(enabled: boolean): void;
  protoInitialize(json: string): void;
  /** SwiftProtobuf 原生编码：messagePath + JS 对象 JSON → wire base64（同步） */
  protoEncode(messagePath: string, json: string): string;
  /** 原生 MD5：任意字符串 → 32 位小写 hex（签名链用，挪出 JS 线程） */
  md5Hex(input: string): string;
  protoPost(
    url: string,
    headers: Record<string, string>,
    formFields: [string, string][],
    protoDataBase64: string,
    skipSign: boolean,
    responseType: string,
    requestId: string,
    timeoutMs?: number
  ): Promise<Record<string, any>>;
  cancelProtoRequest(requestId: string): void;
  makeThumbnail(
    sourceUri: string,
    width: number,
    height: number,
    cacheKey: string,
    referer?: string,
    targetWidth?: number
  ): Promise<string>;
  applyWatermark(sourceUri: string, text: string): Promise<string>;
  clearThumbnailCache(): void;
  /** 设置 → 最大缓存大小：调整原生缩略图磁盘上限（字节） */
  setThumbnailCacheLimit(bytes: number): void;
  isLiveActivitySupported(): boolean;
  areLiveActivitiesEnabled(): boolean;
  /** start 额外携带活动名（原生 ActivityConfiguration 用）；update/end 不需要 */
  startLiveActivity(state: SignLiveActivityState & { name: string }): Promise<string | null>;
  updateLiveActivity(
    activityId: string,
    state: SignLiveActivityState
  ): Promise<void>;
  endLiveActivity(
    activityId: string,
    state: SignLiveActivityState,
    dismissalPolicy: string
  ): Promise<void>;
  endAllLiveActivities(
    state: SignLiveActivityState,
    dismissalPolicy: string
  ): Promise<void>;
  saveBackgroundSnapshot(payload: Record<string, unknown>): void;
  clearBackgroundSnapshot(): void;
  /** 应用锁隐私遮罩：失活即盖原生模糊独立窗，防多任务快照露出内容（F1） */
  setPrivacyShieldEnabled(enabled: boolean): void;
  /** 应用锁会话解锁态：面容验证成功后 true（遮罩解除），上锁/进后台 false */
  setPrivacyShieldUnlocked(unlocked: boolean): void;
  /** 应用实际主题（是否深色）：原生顶栏 chrome/搜索栏跟随应用而非系统
   *  （Appearance.setColorScheme 只覆盖 RN 窗口宿主，原生栏仍随系统亮态） */
  setChromeUserInterfaceStyle(dark: boolean): void;
  /** 顶栏透明度无级调节（0-1 均一 mask alpha；设置-浏览 Slider 拖动即时生效） */
  setNavBarGlassAlpha(alpha: number): void;
  registerNotificationSync(minutes: number): void;
  cancelNotificationSync(): void;
  setNotificationCounts(
    uid: string,
    reply: number,
    at: number,
    agree: number,
    total: number
  ): void;
  getNotificationCounts(uid: string): {
    reply: number;
    at: number;
    agree: number;
    total: number;
  } | null;
  clearNotificationCounts(uid: string): void;
  registerAutoSign(hour: number, minute: number): void;
  cancelAutoSign(): void;
  cancelAllBackgroundTasks(): void;
  isAutoSignRegistered(): boolean;
  scheduleSignReminder(hour: number, minute: number): void;
  cancelSignReminder(): void;
  }

// Raw native surface: protoPost crosses the bridge as a JSON *string*
// (flat strings are far cheaper to bridge than deeply nested dictionaries).
type RawTiebaNativeModule = Omit<TiebaNativeModule, 'protoPost'> & {
  protoPost: (
    url: string,
    headers: Record<string, string>,
    formFields: [string, string][],
    protoDataBase64: string,
    skipSign: boolean,
    responseType: string,
    requestId: string,
    timeoutMs?: number
  ) => Promise<string>;
};

function requireTiebaNative(): RawTiebaNativeModule {
  const module = requireOptionalNativeModule<RawTiebaNativeModule>('TiebaNative');
  if (!module) {
    throw new Error(
      'TiebaNative is not linked. Build an iOS dev client with modules/tieba-native enabled.'
    );
  }
  return module;
}

/**
 * Public module surface. Signature is identical to the legacy contract
 * (protoPost returns a parsed object), so existing JS callers are unaffected.
 */
export const TiebaNative: TiebaNativeModule = (() => {
  const native = requireTiebaNative();
  return {
    ...native,
    protoPost: async (
      url,
      headers,
      formFields,
      protoDataBase64,
      skipSign,
      responseType,
      requestId,
      timeoutMs,
    ) =>
      JSON.parse(
        await native.protoPost(
          url,
          headers,
          formFields,
          protoDataBase64,
          skipSign,
          responseType,
          requestId,
          timeoutMs,
        ),
      ),
  };
})();

/**
 * 导航栏双击回顶事件订阅：原生给 UINavigationBar 挂双击手势（幂等安装），
 * 识别后发 onNavDoubleTap；页面侧经 useNavDoubleTapToTop 订阅并按焦点分发。
 * 原生模块未链接（旧包/Android）时返回空退订，调用方零分支。
 */
export function addNavDoubleTapListener(callback: () => void): () => void {
  const native = requireOptionalNativeModule<{
    addListener: (
      eventName: string,
      listener: (event: { source?: string }) => void,
    ) => { remove(): void };
  }>('TiebaNative');
  const subscription = native?.addListener?.('onNavDoubleTap', callback);
  return () => subscription?.remove();
}

