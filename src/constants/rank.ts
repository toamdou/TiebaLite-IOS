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

// ============================================================
// 等级徽标配色（Kotlin Util.getIconColorByLevel 权威映射，贴吧官方等级色）：
//   Lv1-3 青 #2FBEAB｜Lv4-9 蓝 #3AA7E9｜Lv10-15 橙 #FFA126｜Lv16-18 深橙 #FF9C19
//   ｜其余（0/19+）灰 #B7BCB6
// 全部经 greifyColor(color, 0.2)（Java ColorUtils.greifyColor 同款：HSV 降
// 饱和 0.2、亮度降 0.2/3）。徽标样式两式：作者行=等级色字 + 25% 透明度底
//（ThreadPage 作者徽标 copy(alpha=0.25f)）；头像角标=实底色 + 白字。
// ============================================================

/** 等级区间 → 官方基准色（RGB 0-255；Java switch 同款边界） */
function levelBaseRgb(level: number): [number, number, number] {
  if (level <= 3) return [0x2f, 0xbe, 0xab];
  if (level <= 9) return [0x3a, 0xa7, 0xe9];
  if (level <= 15) return [0xff, 0xa1, 0x26];
  if (level <= 18) return [0xff, 0x9c, 0x19];
  return [0xb7, 0xbc, 0xb6];
}

function rgbToHsv(r: number, g: number, b: number): [number, number, number] {
  const rn = r / 255;
  const gn = g / 255;
  const bn = b / 255;
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === rn) h = ((gn - bn) / d) % 6;
    else if (max === gn) h = (bn - rn) / d + 2;
    else h = (rn - gn) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  return [h, max === 0 ? 0 : d / max, max];
}

function hsvToRgb(h: number, s: number, v: number): [number, number, number] {
  const c = v * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = v - c;
  let rgb: [number, number, number];
  if (h < 60) rgb = [c, x, 0];
  else if (h < 120) rgb = [x, c, 0];
  else if (h < 180) rgb = [0, c, x];
  else if (h < 240) rgb = [0, x, c];
  else if (h < 300) rgb = [x, 0, c];
  else rgb = [c, 0, x];
  return [(rgb[0] + m) * 255, (rgb[1] + m) * 255, (rgb[2] + m) * 255];
}

const toHex = ([r, g, b]: number[]): string =>
  `#${[r, g, b]
    .map((v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0'))
    .join('')}`;

/**
 * 等级徽标色（Kotlin getIconColorByLevel + greifyColor 0.2 复刻）：
 * - color：等级字色（greify 后的官方色）
 * - bg：字色 25% 透明度底（作者行徽标同款，配等级字色）
 * - solidBg：实底色（头像角标同款，配白字）
 * 非法等级（<=0/NaN）返回 null，调用方自行隐藏徽标。
 */
export function levelBadgeColor(level: number): { color: string; bg: string; solidBg: string } | null {
  if (!(level > 0) || !Number.isFinite(level)) return null;
  const [h, s, v] = rgbToHsv(...levelBaseRgb(level));
  const color = toHex(hsvToRgb(h, Math.max(0, s - 0.2), Math.max(0, v - 0.2 / 3)));
  return { color, bg: `${color}40`, solidBg: color };
}
