/**
 * m:ss 时长格式化（thermo 2026-08-26 Z2-D：收敛 AudioSegment /
 * LiveActivityPreview 两份手写副本）。
 */
export function formatDuration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds || 0));
  const mins = Math.floor(total / 60);
  const secs = total % 60;
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}
