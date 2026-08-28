import { TiebaNative } from '../../modules/tieba-native/src/TiebaNative';
import {
  getBduss,
  getCookie,
  getStoken,
  getTbs,
  getUid,
  getZid,
} from '@/services/api/authState';
import { getClientId } from '@/services/api/config';

let knownForumIds: string[] = [];
let knownForumNames: string[] = [];

/** Drop the in-memory followed-forum mirror when switching accounts. */
export function resetBackgroundForums(): void {
  knownForumIds = [];
  knownForumNames = [];
}

/** Persist the followed-forum list and immediately refresh the native snapshot. */
export function setBackgroundForums(
  forumIds: string[],
  forumNames: string[],
): void {
  knownForumIds = forumIds;
  knownForumNames = forumNames;
  syncBackgroundSnapshot();
}

/**
 * Mirror the active session into the native Keychain snapshot so
 * BGAppRefreshTask/BGProcessingTask can run without starting Hermes.
 */
export function syncBackgroundSnapshot(): void {
  const bduss = getBduss();
  const uid = getUid();
  if (!bduss && !uid) {
    resetBackgroundForums();
    TiebaNative.clearBackgroundSnapshot();
    return;
  }
  TiebaNative.saveBackgroundSnapshot({
    bduss,
    stoken: getStoken(),
    cookie: getCookie(),
    uid,
    tbs: getTbs(),
    zid: getZid(),
    clientId: getClientId(),
    forumIds: knownForumIds,
    forumNames: knownForumNames,
  });
}

export function clearBackgroundSnapshot(): void {
  resetBackgroundForums();
  TiebaNative.clearBackgroundSnapshot();
}
