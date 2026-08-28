/**
 * 图片水印文案解析（thermo 2026-08-26 Z2-C：收敛 ImageViewer.getWatermarkText
 * 与 PostContent 内联三层 ternary 两份同构逻辑）。
 *
 * 偏好语义（对齐设置页「图片水印」选项）：
 * - 'username'  → 当前账号昵称
 * - 'forum_name'→ 所属吧名
 * - 'none'/未知 → 空串（不渲染水印）
 */
export function resolveWatermarkText(
  mode: string,
  accountName?: string | null,
  forumName?: string | null,
): string {
  switch (mode) {
    case 'username':
      return accountName ?? '';
    case 'forum_name':
      return forumName ?? '';
    default:
      return '';
  }
}
