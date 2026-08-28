/**
 * 应用锁覆盖层 —— 挂在根布局最顶层（ToastHost 之后）。
 *
 * 锁定态渲染一块不透明全屏遮罩：内容完全被盖住、触摸全部被拦截。
 * 解锁时机只有两条自动路径：
 * - 冷启动：启动闸在 splash 收起前已把 locked 置位，本组件挂载即弹验证；
 * - 后台 → 前台：AppState 监听里补弹。
 * 刻意不在「进后台瞬间」弹验证（那时 app 在后台，LAContext 弹不出来），
 * 用 AppState 前值判断区分这两条路径，也顺带避开 FaceID 系统弹窗自身
 * 引发的 inactive↔active 抖动造成「取消后立刻又弹」的死循环。
 */

import { useCallback, useEffect, useState } from 'react';
import { AppState, Pressable, StyleSheet, View } from 'react-native';
import { Text } from './ui/CompatText';

import { SymbolView } from '@/components/ui/SymbolView';
import { useThemeColors } from '@/theme/ThemeContext';
import { authenticateForUnlock, useAppLockStore } from '@/stores/appLockStore';

type LockUiState =
  | { kind: 'authenticating' }
  | { kind: 'failed'; message: string };

export function AppLockGate() {
  const { colors } = useThemeColors();
  const enabled = useAppLockStore((s) => s.enabled);
  const locked = useAppLockStore((s) => s.locked);
  const [ui, setUi] = useState<LockUiState>({ kind: 'authenticating' });

  const attemptUnlock = useCallback(async () => {
    setUi({ kind: 'authenticating' });
    const res = await authenticateForUnlock('使用面容 ID 解锁');
    if (res.ok) {
      // 验证成功才解除原生遮罩（此前 didBecomeActive 即撤，验证中途就
      // 露出内容——真机实测"面容还没验证完遮罩就没了"）
      try {
        // eslint-disable-next-line @typescript-eslint/no-require-imports -- 原生缺失静默降级
        require('../../modules/tieba-native/src/TiebaNative').TiebaNative.setPrivacyShieldUnlocked(true);
      } catch {}
      useAppLockStore.setState({ locked: false });
      setUi({ kind: 'authenticating' });
    } else {
      setUi({ kind: 'failed', message: res.message });
    }
  }, []);

  // 挂载/上锁时若处于前台则立即验证（覆盖冷启动；后台置锁由下面的
  // AppState 监听负责补弹）。authenticateForUnlock 自带 in-flight 去重。
  useEffect(() => {
    if (!enabled || !locked) return;
    if (AppState.currentState === 'active') {
      void attemptUnlock();
    }
  }, [enabled, locked, attemptUnlock]);

  useEffect(() => {
    if (!enabled) return;
    let prevState = AppState.currentState;
    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'background') {
        // 进后台即刻上锁：回前台前覆盖层必须已经立着
        useAppLockStore.getState().lock();
        setUi({ kind: 'authenticating' });
      } else if (
        state === 'active' &&
        prevState === 'background' &&
        useAppLockStore.getState().locked
      ) {
        void attemptUnlock();
      }
      prevState = state;
    });
    return () => sub.remove();
  }, [enabled, attemptUnlock]);

  if (!enabled || !locked) return null;

  const hint =
    ui.kind === 'authenticating' ? '正在验证面容…' : ui.message;

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <SymbolView name="faceid" size={64} weight="medium" tintColor={colors.primary} />
      <Text style={[styles.title, { color: colors.text }]}>应用已锁定</Text>
      <Text style={[styles.hint, { color: colors.textSecondary }]}>{hint}</Text>
      {ui.kind === 'failed' && (
        <Pressable
          onPress={() => void attemptUnlock()}
          style={({ pressed }) => [
            styles.unlockButton,
            { backgroundColor: colors.primary, opacity: pressed ? 0.7 : 1 },
          ]}
        >
          <Text style={[styles.unlockButtonText, { color: colors.textOnPrimary }]}>
            使用面容 ID 解锁
          </Text>
        </Pressable>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 10000,
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: {
    marginTop: 20,
    fontSize: 20,
    fontWeight: '600',
  },
  hint: {
    marginTop: 8,
    fontSize: 15,
    textAlign: 'center',
    paddingHorizontal: 32,
  },
  unlockButton: {
    marginTop: 28,
    paddingVertical: 12,
    paddingHorizontal: 32,
    borderRadius: 999,
  },
  unlockButtonText: {
    fontSize: 16,
    fontWeight: '600',
  },
});
