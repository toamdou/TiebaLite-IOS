/**
 * Multi-key proto field picker — 吧页子页共用（forum detail / rules）的
 * 字段容错读取，替代两页各自漂移的本地 pick 副本。
 *
 * 语义（2026-08-25 统一裁决）：
 * - 跳过 undefined / null / ''（字段缺失或为空串）；
 * - 保留 0 与 false：数值 0 是真实数据（如冷门吧 member_count: 0），
 *   detail 旧版 `v !== 0` 会跳过真实零值，统一收敛为 rules 版语义（保留 0）。
 *   数值字段按 `!= null && v !== ''` 处理，与 usePagedList / endpoints 的
 *   pick 语义一致。
 *
 * T 由调用方显式声明（string / number 等），同时完成类型的本地收窄。
 */
export function pick<T = unknown>(obj: unknown, ...keys: string[]): T | undefined {
  if (!obj || typeof obj !== 'object') return undefined;
  const record = obj as Record<string, unknown>;
  for (const k of keys) {
    const v = record[k];
    if (v !== undefined && v !== null && v !== '') return v as T;
  }
  return undefined;
}
