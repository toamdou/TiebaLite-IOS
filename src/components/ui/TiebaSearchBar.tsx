import type { StyleProp, ViewStyle } from 'react-native';
import { requireNativeViewManager } from 'expo-modules-core';

const NativeSearchBar = requireNativeViewManager('TiebaNative', 'TiebaSearchBarView');

/**
 * 系统原生搜索框（UISearchBar 直出，iOS 26 液态视觉）。
 *
 * 为什么存在：搜索页此前自绘胶囊搜索行，用户两次反馈「搜索栏不是系统原生
 * 样式」（2026-08-27）——直接托管 UISearchBar，外观/键盘/取消钮全部由系统
 * 承担；放在 LegendList 列表头内随滚动退出，UIKit hit-test 任意深度可点
 * （TiebaSegmentedControl 同款方案）。
 *
 * 受控 text：输入由 onTextChange 上行、JS 状态经 text 下行，事件上行期间
 * 原生侧不回写（防回声）。showCancel 有文字才显示（iOS 规范），cancel
 * 事件语义由页面层决定（有文字清空/无文字返回）。
 */
export function TiebaSearchBar({
  placeholder,
  text,
  showCancel,
  autoFocus,
  onTextChange,
  onSubmit,
  onCancel,
  style,
}: {
  placeholder: string;
  text: string;
  /** 是否有文字（系统取消钮仅在此时出现） */
  showCancel: boolean;
  /** 进入页面自动聚焦弹键盘（出结果后回页不打扰） */
  autoFocus?: boolean;
  onTextChange: (text: string) => void;
  onSubmit: (text: string) => void;
  onCancel: () => void;
  style?: StyleProp<ViewStyle>;
}) {
  return (
    <NativeSearchBar
      placeholder={placeholder}
      text={text}
      showCancel={showCancel}
      autoFocus={autoFocus ?? false}
      style={[{ height: 36 }, style]}
      onTextChange={(e: { nativeEvent: { text: string } }) => onTextChange(e.nativeEvent.text)}
      onSubmit={(e: { nativeEvent: { text: string } }) => onSubmit(e.nativeEvent.text)}
      onCancel={onCancel}
    />
  );
}