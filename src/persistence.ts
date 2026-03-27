import type { Sandbox } from '@cloudflare/sandbox';

/**
 * Persistence layer using Sandbox SDK backup/restore API.
 *
 * Replaces the old rclone-based sync with atomic squashfs snapshots stored in R2.
 * The Sandbox DO handles R2 upload/download internally via presigned URLs —
 * no credentials need to be passed into the container.
 *
 * Backup handles are stored in KV for durability across Worker isolate restarts,
 * with an in-memory cache to avoid redundant KV reads within the same isolate.
 */

export interface BackupHandle {
  id: string;
  dir: string;
}

const KV_HANDLE_KEY = 'backup:handle';

// In-memory cache: has the backup been restored in this Worker isolate lifetime?
let restored = false;
// In-memory cache of the last backup handle (avoids re-reading from KV on every request)
let cachedHandle: BackupHandle | null = null;

export function clearPersistenceCache(): void {
  restored = false;
}

/**
 * Restore the most recent backup if one exists and hasn't been restored yet.
 * Called on every request before proxying to the gateway.
 *
 * This is idempotent: the `restored` flag prevents double-restoring within
 * the same Worker isolate lifetime. When the container sleeps and wakes,
 * the FUSE mount is lost, but the Worker isolate is also recycled, so
 * `restored` resets to false and we re-restore on the next request.
 */
export async function restoreIfNeeded(sandbox: Sandbox, kv?: KVNamespace): Promise<void> {
  if (restored) return;

  // If not cached in memory, try loading from KV (survives isolate restarts)
  if (!cachedHandle && kv) {
    try {
      const stored = await kv.get<BackupHandle>(KV_HANDLE_KEY, 'json');
      if (stored) {
        cachedHandle = stored;
        console.log(`[persistence] Loaded backup handle ${cachedHandle.id} from KV`);
      }
    } catch (err) {
      console.error('[persistence] Failed to read handle from KV:', err);
    }
  }

  if (!cachedHandle) {
    console.log('[persistence] No backup handle cached, skipping restore');
    restored = true;
    return;
  }

  console.log(`[persistence] Restoring backup ${cachedHandle.id}...`);
  const t0 = Date.now();
  try {
    await sandbox.restoreBackup(cachedHandle);
    console.log(`[persistence] Restore complete in ${Date.now() - t0}ms`);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes('BACKUP_EXPIRED') || msg.includes('BACKUP_NOT_FOUND')) {
      console.log(`[persistence] Backup ${cachedHandle.id} expired/gone, clearing`);
      cachedHandle = null;
      if (kv) {
        await kv.delete(KV_HANDLE_KEY).catch(() => {});
      }
    } else {
      console.error(`[persistence] Restore failed:`, err);
      throw err;
    }
  }
  restored = true;
}

/**
 * Create a new snapshot of /root (config + workspace + skills).
 * Stores the handle in memory and in KV for durability across isolate restarts.
 */
export async function createSnapshot(sandbox: Sandbox, kv?: KVNamespace): Promise<BackupHandle> {
  console.log('[persistence] Creating backup...');
  const t0 = Date.now();
  const handle = await sandbox.createBackup({
    dir: '/home/openclaw',
    ttl: 604800, // 7 days
    excludes: [
      '*.lock',
      '*.log',
      '*.tmp',
      '.git',
      'node_modules',
      '.config/rclone',
    ],
  });
  cachedHandle = handle;
  console.log(`[persistence] Backup ${handle.id} created in ${Date.now() - t0}ms`);

  // Persist handle to KV so it survives Worker isolate restarts
  if (kv) {
    try {
      await kv.put(KV_HANDLE_KEY, JSON.stringify(handle));
      console.log(`[persistence] Backup handle ${handle.id} saved to KV`);
    } catch (err) {
      console.error('[persistence] Failed to save handle to KV:', err);
    }
  }

  return handle;
}

/**
 * Get the current cached backup handle (for status reporting).
 */
export function getCachedHandle(): BackupHandle | null {
  return cachedHandle;
}

/**
 * Set the cached backup handle (e.g., restored from external storage).
 */
export function setCachedHandle(handle: BackupHandle | null): void {
  cachedHandle = handle;
}
