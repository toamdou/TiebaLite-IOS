import { useCallback, useEffect, useRef, useState } from 'react';
import { Alert, Modal, ScrollView, StyleSheet, View } from 'react-native';
import { Text as RNText } from '../../components/ui/CompatText';
import { Stack, useRouter } from 'expo-router';
import * as MediaLibrary from 'expo-media-library';
import { Image } from 'expo-image';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { hapticForScene } from '@/theme/hapticsMap';
import {
  Button,
  Form,
  Picker,
  ProgressView,
  RNHostView,
  Section,
  Text,
  TextField,
  useNativeState,
} from '@expo/ui/swift-ui';
import { disabled, pickerStyle, progressViewStyle, tag } from '@expo/ui/swift-ui/modifiers';
import { useFormTint } from '@/hooks/useFormTint';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { Avatar } from '@/components/ui/Avatar';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { Button as UIButton } from '@/components/ui/Button';
import { Toast, type ToastRef } from '@/components/ui/Toast';
import { useAuthStore } from '@/stores/authStore';
import { requireTbs } from '@/services/api/endpoints/helpers';
import { uploadPortrait } from '@/services/api/endpoints/social';
import { profile, profileModify } from '@/services/api/endpoints/user';
import { getStokenSync } from '@/services/storage/AuthSQLiteStorage';
import { useThemeColors } from '@/theme/ThemeContext';
import {Spacing, typographyStyles, RadiusStyle} from '@/theme';

export default function EditProfilePage() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();
  const formTint = useFormTint();
  const account = useAuthStore((s) => s.account);
  const [sex, setSex] = useState(0);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const nickNameState = useNativeState(account?.nameShow || account?.name || '');
  const introState = useNativeState('');
  const sexState = useNativeState(0);

  // ── 头像上传 ──
  const toastRef = useRef<ToastRef | null>(null);
  const [pickerVisible, setPickerVisible] = useState(false);
  const [pickerLoading, setPickerLoading] = useState(false);
  const [photos, setPhotos] = useState<{ id: string; uri: string }[]>([]);
  const [uploading, setUploading] = useState(false);

  // 已为该 uid 拉取过资料：防止 account 对象引用变化（如头像上传回写产生
  // 新对象）触发 effect 重跑、第二次拉取覆写用户尚未保存的编辑。
  const loadedUidRef = useRef<string | null>(null);

  useEffect(() => {
    let mounted = true;
    const uid = account?.uid;
    if (!uid) {
      setLoading(false);
      return;
    }
    // 同一 uid 只拉取一次；重复进入直接结束（数据已被首次拉取填充）。
    if (loadedUidRef.current === uid) {
      setLoading(false);
      return;
    }
    (async () => {
      try {
        const data = await profile(uid);
        if (mounted) {
          loadedUidRef.current = uid;
          const nextSex = data.user?.sex || 0;
          nickNameState.set(data.user?.nameShow || data.user?.name || '');
          introState.set(data.user?.intro || '');
          sexState.set(nextSex);
          setSex(nextSex);
        }
      } catch {
        // Keep account defaults on failure.
      } finally {
        if (mounted) setLoading(false);
      }
    })();
    return () => { mounted = false; };
    // 依赖收窄到 uid：头像上传回写（同 uid 新 account 对象）不再触发全量重载。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account?.uid, nickNameState, introState, sexState]);

  const handleSave = useCallback(async () => {
    if (!account?.uid) {
      Alert.alert('提示', '请先登录');
      return;
    }
    setSaving(true);
    try {
      await profileModify({
        intro: introState.get().trim(),
        sex: sexState.get(),
        nick_name: nickNameState.get().trim(),
        stoken: getStokenSync(),
      });
      hapticForScene('action-success');
      Alert.alert('已保存', '个人资料已更新');
      router.back();
    } catch (e: any) {
      Alert.alert('保存失败', e?.message || '网络错误，请稍后重试');
    } finally {
      setSaving(false);
    }
  }, [account, introState, sexState, nickNameState, router]);

  const openPicker = useCallback(async () => {
    try {
      const { status } = await MediaLibrary.requestPermissionsAsync();
      // 新版 expo-media-library：PermissionStatus 不再有 'limited'（iOS limited
      // 权限并入 granted 分支），旧判断会与类型系统冲突。
      if (status !== 'granted') {
        Alert.alert('需要相册权限', '请在系统设置中允许访问相册以选择头像。');
        return;
      }
      void hapticForScene('sheet-present');
      setPickerVisible(true);
      setPickerLoading(true);
      setPhotos([]);
      const { assets } = await MediaLibrary.getAssetsAsync({
        mediaType: 'photo',
        sortBy: ['creationTime'],
        first: 48,
      });
      // 48 张逐张串行解析会导致首屏卡顿，改为并行分批解析
      const CHUNK_SIZE = 12;
      const resolved: { id: string; uri: string }[] = [];
      for (let i = 0; i < assets.length; i += CHUNK_SIZE) {
        const chunk = assets.slice(i, i + CHUNK_SIZE);
        const chunkResults = await Promise.all(
          chunk.map(async (a) => {
            try {
              const info = await MediaLibrary.getAssetInfoAsync(a);
              return info?.localUri ? { id: info.id ?? a.id, uri: info.localUri } : null;
            } catch {
              // Skip assets that cannot be resolved to a local file.
              return null;
            }
          }),
        );
        for (const r of chunkResults) {
          if (r) resolved.push(r);
        }
      }
      setPhotos(resolved);
      if (resolved.length === 0) {
        Alert.alert('未找到照片', '相册中没有可用的照片，请先在相册中保存一张图片。');
      }
    } catch (e: any) {
      setPickerVisible(false);
      Alert.alert('打开相册失败', e?.message || '请稍后重试');
    } finally {
      setPickerLoading(false);
    }
  }, []);

  const handleUploadPortrait = useCallback(async (uri: string) => {
    setPickerVisible(false);
    setUploading(true);
    try {
      const tbs = await requireTbs();
      await uploadPortrait(uri, tbs);
      // 上传成功后仅回写 authStore 的 portrait 字段（用函数式更新取最新
      // account，避免闭包里的旧引用），使页面头像与「我的」页立即更新；
      // 因为加载 effect 依赖收窄为 uid，同 uid 下不会触发资料全量重载，
      // 也就不会覆写用户未保存的昵称/简介/性别编辑。
      useAuthStore.setState((s) => (
        s.account ? { account: { ...s.account, portrait: uri } } : {}
      ));
      hapticForScene('action-success');
      toastRef.current?.show({
        title: '头像已更新',
        type: 'success',
        icon: 'checkmark.circle.fill',
      });
    } catch (e: any) {
      hapticForScene('action-fail');
      toastRef.current?.show({
        title: '头像上传失败',
        message: e?.message || '网络错误，请稍后重试',
        type: 'error',
      });
    } finally {
      setUploading(false);
    }
  }, []);

  return (
    <>
      <Stack.Screen options={{ title: '编辑资料' }} />
      <ThemedHost style={{ flex: 1 }}>
        <Form modifiers={formTint}>
          {loading ? (
            <Section>
              <ProgressView modifiers={[progressViewStyle('circular')]} />
            </Section>
          ) : (
            <>
              <Section title="头像">
                <RNHostView matchContents>
                  <View style={styles.avatarRow}>
                    <Avatar
                      source={account?.portrait || undefined}
                      initials={(account?.nameShow || account?.name || '吧')?.charAt(0)}
                      size={64}
                    />
                    <View style={styles.avatarActions}>
                      <UIButton
                        title={uploading ? '上传中…' : '更换头像'}
                        icon="camera.fill"
                        variant="filled"
                        size="medium"
                        disabled={uploading}
                        onPress={openPicker}
                      />
                      {uploading && (
                        <View style={styles.uploadProgress}>
                          <ThemedHost matchContents>
                            <ProgressView modifiers={[progressViewStyle('circular')]} />
                          </ThemedHost>
                        </View>
                      )}
                    </View>
                  </View>
                </RNHostView>
              </Section>

              <Section title="昵称">
                <TextField
                  text={nickNameState}
                  placeholder="昵称"
                  maxLength={30}
                />
              </Section>

              <Section title="性别">
                <Picker
                  label="性别"
                  selection={sex}
                  onSelectionChange={(value: number) => {
                    setSex(value);
                    sexState.set(value);
                  }}
                  modifiers={[pickerStyle('inline')]}
                >
                  <Text modifiers={[tag(0)]}>保密</Text>
                  <Text modifiers={[tag(1)]}>男</Text>
                  <Text modifiers={[tag(2)]}>女</Text>
                </Picker>
              </Section>

              <Section title="个人简介">
                <TextField
                  text={introState}
                  placeholder="介绍一下自己"
                  axis="vertical"
                  maxLength={200}
                />
              </Section>

              <Section>
                {saving ? (
                  <Button
                    modifiers={[disabled(true)]}
                    onPress={handleSave}
                  >
                    <ProgressView modifiers={[progressViewStyle('circular')]} />
                  </Button>
                ) : (
                  <Button label="保存" onPress={handleSave} />
                )}
              </Section>
            </>
          )}
        </Form>
      </ThemedHost>

      <Modal
        visible={pickerVisible}
        animationType="slide"
        transparent={false}
        onRequestClose={() => setPickerVisible(false)}
      >
        {/* Modal 在页面 ThemedHost 之外，ProgressView 等 SwiftUI 组件默认按系统
            浅色渲染；包一层 ThemedHost 让原生组件跟随应用 isDark。 */}
        <ThemedHost style={{ flex: 1 }}>
          <View style={[styles.modal, { backgroundColor: colors.windowBackground, paddingTop: insets.top + Spacing.lg }]}>
            <View style={styles.modalHeader}>
              <RNText style={[typographyStyles.headline, { color: colors.text }]}>选择头像</RNText>
              <HdrPressable
                onPress={() => {
                  void hapticForScene('press');
                  setPickerVisible(false);
                }}
                hitSlop={8}
                accessibilityRole="button"
                accessibilityLabel="取消选择头像"
              >
                <RNText style={[typographyStyles.subhead, { color: colors.tint }]}>取消</RNText>
              </HdrPressable>
            </View>
            {pickerLoading ? (
              <View style={styles.modalLoading}>
                <ThemedHost matchContents>
                  <ProgressView modifiers={[progressViewStyle('circular')]} />
                </ThemedHost>
              </View>
            ) : (
              <ScrollView contentContainerStyle={styles.grid}>
                {photos.map((p) => (
                  <HdrPressable
                    key={p.id}
                    onPress={() => {
                      void hapticForScene('press');
                      handleUploadPortrait(p.uri);
                    }}
                    accessibilityRole="imagebutton"
                    accessibilityLabel="选择此照片作为头像"
                    style={styles.cell}
                  >
                    <Image
                      source={{ uri: p.uri }}
                      style={styles.thumb}
                      contentFit="cover"
                      transition={150}
                    />
                  </HdrPressable>
                ))}
              </ScrollView>
            )}
          </View>
        </ThemedHost>
      </Modal>

      {/* In-page toast (no global ToastProvider mounted) */}
      <Toast ref={toastRef} />
    </>
  );
}

const styles = StyleSheet.create({
  avatarRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.lg,
    paddingVertical: Spacing.sm,
  },
  avatarActions: {
    flex: 1,
    gap: Spacing.sm,
    alignItems: 'flex-start',
  },
  uploadProgress: {
    marginLeft: Spacing.md,
  },
  modal: {
    flex: 1,
    paddingHorizontal: Spacing.lg,
  },
  modalHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: Spacing.md,
  },
  modalLoading: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  grid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.sm,
    paddingBottom: Spacing.xxl,
  },
  cell: {
    width: '31%',
    aspectRatio: 1,
  },
  thumb: {
    width: '100%',
    height: '100%',
    ...RadiusStyle.card,
  },
});
