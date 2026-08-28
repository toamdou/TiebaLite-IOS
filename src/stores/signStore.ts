/**
 * Public sign store facade.
 *
 * The Zustand view model lives in src/services/sign/SignViewModel.ts and the
 * background task/scheduling logic lives in
 * src/services/sign/BackgroundSignService.ts. This file only wires the
 * singleton and re-exports the existing public API so existing imports keep
 * working unchanged.
 */

import { createSignViewModel } from '@/services/sign/SignViewModel';

export { createSignViewModel } from '@/services/sign/SignViewModel';
export type { SignState } from '@/services/sign/SignViewModel';
export type { SignProgressItem, SignStatus } from '@/services/sign/signTypes';

export const useSignStore = createSignViewModel();
