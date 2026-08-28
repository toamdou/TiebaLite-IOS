import { useCallback, useEffect, useState } from 'react';
import { Alert, Pressable, StyleSheet, View } from 'react-native';
import { Text as RNText } from '../../components/ui/CompatText';
import { Form, Section, Button, Text, TextField, Toggle, Picker, ConfirmationDialog, RNHostView, useNativeState } from '@expo/ui/swift-ui';
import { pickerStyle, tag } from '@expo/ui/swift-ui/modifiers';
import { useFormTint } from '@/hooks/useFormTint';
import { hapticForScene } from '@/theme/hapticsMap';
import { BlockManager } from '@/utils/BlockManager';
import type { BlockedWord, BlockedUser } from '@/types';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { Avatar } from '@/components/ui/Avatar';
import { SkeletonList } from '@/components/ui/Skeleton';
import { EmptyState } from '@/components/ui/EmptyState';
import { Button as UIButton } from '@/components/ui/Button';
import { SymbolView } from '@/components/ui/SymbolView';
import { useThemeColors } from '@/theme/ThemeContext';
import { Spacing, typographyStyles } from '@/theme';
import { getBlacklist, delBlacklist, getDislikeForums } from '@/services/api/endpoints/social';
import type { SocialUser, DislikeForumItem } from '@/services/api/endpoints/social';
import { formatCount } from '@/utils';

// NOTE: 此页面使用本地 BlockManager（统一 SQLite kv 表）进行内容过滤。
// 下方的「云端黑名单」/「屏蔽吧」来自贴吧服务端（social API），
// 是另一套独立数据，与本地屏蔽互不干扰。

function blacklistTypeLabel(btype?: string): string {
  if (!btype) return '';
  const map: Record<string, string> = {
    FOLLOW: '禁关注',
    INTERACT: '禁互动',
    CHAT: '禁聊天',
  };
  return btype
    .split(',')
    .filter(Boolean)
    .map((t) => map[t] ?? t)
    .join('/');
}

export default function BlockPage() {
  const { colors } = useThemeColors();
  const formTint = useFormTint();
  const [activeTab, setActiveTab] = useState('keyword');
  const [keywords, setKeywords] = useState<BlockedWord[]>([]);
  const [users, setUsers] = useState<BlockedUser[]>([]);
  // 受控输入：绑定原生 state，切换 tab 清空时输入框同步清空（参照 edit-profile.tsx 模式）
  const addTextState = useNativeState('');
  const [isRegex, setIsRegex] = useState(false);
  const [isWhitelist, setIsWhitelist] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<string | null>(null);

  // ── 云端黑名单（社交黑名单 API）──
  const [blacklist, setBlacklist] = useState<SocialUser[]>([]);
  const [blacklistLoading, setBlacklistLoading] = useState(true);
  const [blacklistError, setBlacklistError] = useState('');
  const [removingUid, setRemovingUid] = useState<string | null>(null);

  // ── 屏蔽吧列表（云端）──
  const [dislikeForums, setDislikeForums] = useState<DislikeForumItem[]>([]);
  const [dislikeLoading, setDislikeLoading] = useState(true);
  const [dislikeError, setDislikeError] = useState('');

  useEffect(() => {
    (async () => {
      try {
        const words = await BlockManager.getBlockedWords();
        setKeywords(words);
        const blockedUsers = await BlockManager.getBlockedUsers();
        setUsers(blockedUsers);
      } catch {}
    })();
  }, []);

  const loadBlacklist = useCallback(async () => {
    setBlacklistLoading(true);
    setBlacklistError('');
    try {
      setBlacklist(await getBlacklist());
    } catch (e: any) {
      setBlacklistError(e?.message || '网络错误，请稍后重试');
    } finally {
      setBlacklistLoading(false);
    }
  }, []);

  const loadDislikeForums = useCallback(async () => {
    setDislikeLoading(true);
    setDislikeError('');
    try {
      const res = await getDislikeForums(1, 50);
      setDislikeForums(res.items);
    } catch (e: any) {
      setDislikeError(e?.message || '网络错误，请稍后重试');
    } finally {
      setDislikeLoading(false);
    }
  }, []);

  useEffect(() => {
    // 挂载时加载屏蔽列表/不感兴趣吧（loader 内置 loading 态）
    // eslint-disable-next-line react-hooks/set-state-in-effect -- mount-time data load
    loadBlacklist();
    loadDislikeForums();
  }, [loadBlacklist, loadDislikeForums]);

  const handleAdd = useCallback(async () => {
    const raw = addTextState.get().trim();
    if (!raw) return;
    if (activeTab === 'keyword') {
      if (isRegex) {
        try {
          new RegExp(raw);
        } catch (e: any) {
          Alert.alert('正则表达式无效', e?.message || '请输入有效的正则表达式');
          return;
        }
      }
      const newWord: BlockedWord = {
        id: Date.now().toString(),
        keyword: raw,
        isRegex,
        category: isWhitelist ? 'whitelist' : 'blacklist',
      };
      try {
        await BlockManager.addBlockedWord(newWord);
        setKeywords((prev) => [...prev, newWord]);
      } catch (e: any) {
        hapticForScene('action-fail');
        Alert.alert('添加失败', e?.message || '网络错误，请稍后重试');
        return;
      }
    } else {
      const newUser: BlockedUser = {
        id: Date.now().toString(),
        uid: raw,
      };
      try {
        await BlockManager.addBlockedUser(newUser);
        setUsers((prev) => [...prev, newUser]);
      } catch (e: any) {
        hapticForScene('action-fail');
        Alert.alert('添加失败', e?.message || '网络错误，请稍后重试');
        return;
      }
    }
    addTextState.set('');
    setIsRegex(false);
    setIsWhitelist(false);
    hapticForScene('action-success');
  }, [addTextState, activeTab, isRegex, isWhitelist]);

  const handleDeleteConfirm = useCallback(async () => {
    if (!deleteTarget) return;
    // 先取快照：失败时对话框保持打开，target 不变，可重试。
    const target = deleteTarget;
    try {
      if (activeTab === 'keyword') {
        await BlockManager.removeBlockedWord(target);
        setKeywords((prev) => prev.filter((k) => k.id !== target));
      } else {
        await BlockManager.removeBlockedUser(target);
        setUsers((prev) => prev.filter((u) => u.uid !== target));
      }
      hapticForScene('action-success');
      setDeleteTarget(null);
    } catch (e: any) {
      hapticForScene('action-fail');
      Alert.alert('删除失败', e?.message || '网络错误，请稍后重试');
    }
  }, [deleteTarget, activeTab]);

  const handleRemoveBlacklist = useCallback(
    (user: SocialUser) => {
      const displayName = user.nickName || user.userName || user.uid;
      Alert.alert(
        '解除云端黑名单',
        `确定要解除对「${displayName}」的黑名单吗？`,
        [
          { text: '取消', style: 'cancel' },
          {
            text: '解除',
            style: 'destructive',
            onPress: async () => {
              hapticForScene('destructive');
              setRemovingUid(user.uid);
              try {
                await delBlacklist(user.uid);
                setBlacklist((prev) => prev.filter((u) => u.uid !== user.uid));
                hapticForScene('action-success');
              } catch (e: any) {
                hapticForScene('action-fail');
                Alert.alert('解除失败', e?.message || '网络错误，请稍后重试');
              } finally {
                setRemovingUid(null);
              }
            },
          },
        ],
      );
    },
    [],
  );

  const renderBlacklist = () => {
    if (blacklistLoading) {
      return <SkeletonList variant="row" count={5} />;
    }
    if (blacklistError) {
      return (
        <View style={styles.errorBlock}>
          <RNText style={[typographyStyles.subhead, { color: colors.textSecondary }]}>
            云端黑名单加载失败
          </RNText>
          <UIButton title="重试" variant="tinted" size="small" onPress={loadBlacklist} />
        </View>
      );
    }
    if (blacklist.length === 0) {
      return (
        <EmptyState
          title="暂无云端黑名单"
          description="你还没有在贴吧服务端拉黑过用户"
          icon="person.crop.circle.badge.xmark"
        />
      );
    }
    return (
      <View style={styles.list}>
        {blacklist.map((user) => {
          const name = user.nickName || user.userName || user.uid;
          const typeLabel = blacklistTypeLabel(user.btype);
          return (
            <View key={user.uid} style={styles.row}>
              <Avatar source={user.portrait} initials={name.charAt(0)} size={40} />
              <View style={styles.rowBody}>
                <RNText numberOfLines={1} style={[typographyStyles.subheadBold, { color: colors.text }]}>
                  {name}
                </RNText>
                <RNText numberOfLines={1} style={[typographyStyles.footnote, { color: colors.textSecondary }]}>
                  {user.userName && user.nickName ? `@${user.userName}` : `UID ${user.uid}`}
                  {typeLabel ? ` · ${typeLabel}` : ''}
                </RNText>
              </View>
              <Pressable
                onPress={() => handleRemoveBlacklist(user)}
                disabled={removingUid === user.uid}
                hitSlop={8}
                accessibilityRole="button"
                accessibilityLabel={`解除 ${name} 的黑名单`}
                style={styles.removeBtn}
              >
                {removingUid === user.uid ? (
                  <RNText style={[typographyStyles.footnote, { color: colors.textTertiary }]}>解除中…</RNText>
                ) : (
                  <SymbolView name="minus.circle.fill" size={22} weight="medium" tintColor={colors.danger} />
                )}
              </Pressable>
            </View>
          );
        })}
      </View>
    );
  };

  const renderDislikeForums = () => {
    if (dislikeLoading) {
      return <SkeletonList variant="row" count={5} />;
    }
    if (dislikeError) {
      return (
        <View style={styles.errorBlock}>
          <RNText style={[typographyStyles.subhead, { color: colors.textSecondary }]}>
            屏蔽吧列表加载失败
          </RNText>
          <UIButton title="重试" variant="tinted" size="small" onPress={loadDislikeForums} />
        </View>
      );
    }
    if (dislikeForums.length === 0) {
      return (
        <EmptyState
          title="暂无屏蔽吧"
          description="未发现被屏蔽的贴吧"
          icon="hand.raised.fill"
        />
      );
    }
    return (
      <View style={styles.list}>
        {dislikeForums.map((f) => (
          <View key={f.fid} style={styles.row}>
            <Avatar source={undefined} initials={f.fname?.charAt(0) || '吧'} size={40} />
            <View style={styles.rowBody}>
              <RNText numberOfLines={1} style={[typographyStyles.subheadBold, { color: colors.text }]}>
                {f.fname}
              </RNText>
              <RNText numberOfLines={1} style={[typographyStyles.footnote, { color: colors.textSecondary }]}>
                {formatCount(f.memberNum)} 成员 · {formatCount(f.postNum)} 帖子
              </RNText>
            </View>
            <RNText style={[typographyStyles.caption1, { color: colors.textTertiary }]}>需在贴吧客户端解除</RNText>
          </View>
        ))}
      </View>
    );
  };

  // tab 切换时清空输入与辅助开关（受控 state 同步清空输入框）
  const handleTabChange = useCallback((v: string) => {
    hapticForScene('toggle');
    setActiveTab(v);
    addTextState.set('');
    setIsRegex(false);
    setIsWhitelist(false);
  }, [addTextState]);

  // 本地屏蔽列表按当前 tab 取：空态与删除对话框都据此判断，避免
  // 关键词为空但用户非空（或反之）时误显示「暂无屏蔽项」。
  const localList = activeTab === 'keyword' ? keywords : users;

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Form modifiers={formTint}>
        <Section>
          <Picker
            selection={activeTab}
            onSelectionChange={handleTabChange}
            modifiers={[pickerStyle('segmented')]}
          >
            <Text modifiers={[tag('keyword')]}>屏蔽词</Text>
            <Text modifiers={[tag('user')]}>屏蔽用户</Text>
            <Text modifiers={[tag('blacklist')]}>黑名单</Text>
            <Text modifiers={[tag('forums')]}>屏蔽吧</Text>
          </Picker>
        </Section>

        {activeTab === 'keyword' || activeTab === 'user' ? (
          <>
            <Section title={activeTab === 'keyword' ? '添加屏蔽词' : '添加屏蔽用户'}>
              <TextField
                text={addTextState}
                placeholder={activeTab === 'keyword' ? '输入屏蔽关键词' : '输入用户ID'}
              />
              {activeTab === 'keyword' && (
                <>
                  <Toggle
                    label="使用正则表达式"
                    isOn={isRegex}
                    onIsOnChange={(v) => { hapticForScene('toggle'); setIsRegex(v); }}
                  />
                  <Toggle
                    label="设为白名单"
                    isOn={isWhitelist}
                    onIsOnChange={(v) => { hapticForScene('toggle'); setIsWhitelist(v); }}
                  />
                </>
              )}
              <Button
                label="添加"
                systemImage="plus.circle.fill"
                onPress={handleAdd}
              />
            </Section>

            <Section title={activeTab === 'keyword' ? `屏蔽词列表 (${localList.length})` : `屏蔽用户 (${localList.length})`}>
              {localList.length > 0 && (
                <ConfirmationDialog
                  title="移除屏蔽项"
                  isPresented={!!deleteTarget}
                  onIsPresentedChange={(v) => { if (!v) setDeleteTarget(null); }}
                  titleVisibility="visible"
                >
                  <ConfirmationDialog.Trigger>
                    {activeTab === 'keyword'
                      ? keywords.map((word) => (
                          <Button
                            key={word.id}
                            role="destructive"
                            onPress={() => setDeleteTarget(word.id)}
                          >
                            <Text>{word.keyword}</Text>
                            <Text>{word.isRegex ? '正则' : ''}{word.category === 'whitelist' ? '白名单' : ''}</Text>
                          </Button>
                        ))
                      : users.map((user) => (
                          <Button
                            key={user.uid}
                            role="destructive"
                            onPress={() => setDeleteTarget(user.uid)}
                          >
                            <Text>{user.username || user.uid}</Text>
                          </Button>
                        ))}
                  </ConfirmationDialog.Trigger>
                  <ConfirmationDialog.Actions>
                    <Button label="删除" role="destructive" onPress={handleDeleteConfirm} />
                    <Button label="取消" role="cancel" />
                  </ConfirmationDialog.Actions>
                  <ConfirmationDialog.Message>
                    <Text>确定要移除此屏蔽项吗？</Text>
                  </ConfirmationDialog.Message>
                </ConfirmationDialog>
              )}
              {localList.length === 0 && (
                <Text>暂无屏蔽项</Text>
              )}
            </Section>
          </>
        ) : activeTab === 'blacklist' ? (
          <Section
            title="云端黑名单"
            footer={<Text>由贴吧服务端维护的社交黑名单，与本地屏蔽相互独立。</Text>}
          >
            <RNHostView matchContents>
              {renderBlacklist()}
            </RNHostView>
          </Section>
        ) : (
          <Section
            title="屏蔽吧（云端）"
            footer={<Text>由贴吧服务端记录，解除请在贴吧客户端中操作。</Text>}
          >
            <RNHostView matchContents>
              {renderDislikeForums()}
            </RNHostView>
          </Section>
        )}
      </Form>
    </ThemedHost>
  );
}

const styles = StyleSheet.create({
  list: {
    gap: Spacing.md,
    paddingVertical: Spacing.sm,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.sm,
  },
  rowBody: {
    flex: 1,
  },
  removeBtn: {
    paddingHorizontal: Spacing.xs,
    paddingVertical: Spacing.xs,
  },
  errorBlock: {
    alignItems: 'center',
    gap: Spacing.sm,
    paddingVertical: Spacing.lg,
  },
});
