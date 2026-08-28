// ============================================================
// TiebaLite React Native - Spacing / Radius / Shadows
// design-taste-frontend: 圆角按层级递减，禁止统一圆角
// ============================================================

// ---------- Spacing Scale ----------
export const Spacing = {
  /** 4pt */
  xs: 4,
  /** 8pt */
  sm: 8,
  /** 12pt */
  md: 12,
  /** 16pt — 标准页面水平边距 */
  lg: 16,
  /** 20pt */
  xl: 20,
  /** 28pt */
  xxl: 28,
  /** 36pt — 大区块间距/页面留白 */
  page: 36,
} as const;

export type SpacingKey = keyof typeof Spacing;

// ---------- Border Radius (按层级递减，禁止统一) ----------
// iOS 26 design language: continuous curvature (squircle) — corner curves
// transition smoothly instead of plain circular arcs, and radii scale up
// across the board vs. previous generations. Values still decrease by
// hierarchy to match the system continuous-corner style; never uniform.
export const Radius = {
  /** Small elements: chips, tags, badges */
  chip: 8,
  /** Input fields, search bars, segmented controls */
  input: 12,
  /** Standard cards */
  card: 20,        // was 16, iOS 26 uses 20
  /** Large cards, large media */
  cardLarge: 24,   // NEW
  /** Images, avatars with rounded corners */
  image: 16,       // was maybe 12
  /** Sheets, modals (formSheet corner) */
  sheet: 28,       // NEW — iOS 26 formSheet
  /** Full capsule / pill shape */
  capsule: 999,
} as const;

// ---------- Radius Style（连续圆角，全 App 统一） ----------
// 全应用圆角一律连续曲线（iOS squircle）：带圆角的样式直接引用
// `...RadiusStyle.<k>`（替代 `borderRadius: Radius.<k>`），保证
// borderCurve: 'continuous' 与层级圆角成对出现、不再散落裸值。
export const RadiusStyle = {
  chip: { borderRadius: Radius.chip, borderCurve: 'continuous' as const },
  input: { borderRadius: Radius.input, borderCurve: 'continuous' as const },
  card: { borderRadius: Radius.card, borderCurve: 'continuous' as const },
  cardLarge: { borderRadius: Radius.cardLarge, borderCurve: 'continuous' as const },
  image: { borderRadius: Radius.image, borderCurve: 'continuous' as const },
  sheet: { borderRadius: Radius.sheet, borderCurve: 'continuous' as const },
  // 胶囊/圆形：radius = 半尺寸时连续曲线与圆弧几何等价，不加 borderCurve
  //（保持设计师的圆形意图，勿在胶囊/圆形上补 continuous —— 2026-08-28 用户定案）
  capsule: { borderRadius: Radius.capsule },
} as const;

// ---------- Shadows (iOS 26: softer, larger spread) ----------
// 设计评审：iOS 以背景色差分层级而非投影；卡片阴影降至极轻，
// 分层主要由发丝边框 + 卡片/背景色差承担（Shadows.card ≈ 0）。
export const Shadows = {
  /** 卡片极轻投影（仅保留一丁点悬浮感） */
  card: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.03,
    shadowRadius: 12,
    elevation: 1,
  },
  /** Medium elevation for floating elements */
  floating: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 8 },
    shadowOpacity: 0.12,
    shadowRadius: 24,
    elevation: 8,
  },
  /** High elevation for modals, sheets */
  elevated: {
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 12 },
    shadowOpacity: 0.18,
    shadowRadius: 32,
    elevation: 12,
  },
  /** Glass elements: no shadow (glass has its own depth via refraction) */
  glass: {
    shadowColor: 'transparent',
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0,
    shadowRadius: 0,
    elevation: 0,
  },
} as const;

// ---------- Icon Sizes ----------
export const IconSize = {
  xs: 12,
  sm: 16,
  md: 20,
  tab: 24,
  lg: 28,
  xl: 32,
  xxl: 40,
  huge: 48,
} as const;
