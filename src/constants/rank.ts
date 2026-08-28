// ============================================================
// TiebaLite - 排名/热榜色板（数据维度色，跨屏共享）
// 热度/等级排行等"数据维度"颜色，避免各屏各自定义导致改色不同步。
// ============================================================

/** 热榜前三名排名色（红/橙/黄） */
export const HOT_RANK_COLORS = ['#FF3B30', '#FF9500', '#FFCC00'] as const;

export interface TopicChipColors {
  bg: string;
  rank: string;
  border: string;
}

/** 热门话题 chip 8 色轮换（bg 12% 透明度、rank 实色、border 30% 透明度） */
export const TOPIC_CHIP_COLORS: TopicChipColors[] = [
  { bg: '#FF3B3012', rank: '#FF3B30', border: '#FF3B3030' },
  { bg: '#FF950012', rank: '#FF9500', border: '#FF950030' },
  { bg: '#FFCC0012', rank: '#CC9900', border: '#FFCC0030' },
  { bg: '#34C75912', rank: '#34C759', border: '#34C75930' },
  { bg: '#5AC8FA12', rank: '#5AC8FA', border: '#5AC8FA30' },
  { bg: '#007AFF12', rank: '#007AFF', border: '#007AFF30' },
  { bg: '#5856D612', rank: '#5856D6', border: '#5856D630' },
  { bg: '#AF52DE12', rank: '#AF52DE', border: '#AF52DE30' },
];
