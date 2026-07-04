import { getSandbox } from '@cloudflare/sandbox';
import type { OpenClawEnv } from '../types';
import { buildSandboxOptions } from '../index';
import { ensureGateway, findExistingGatewayProcess } from '../gateway';
import { createSnapshot } from '../persistence';
import { shouldWakeContainer, DEFAULT_LEAD_TIME_MS, CRON_STORE_R2_KEY } from './wake';

/**
 * Handle Workers Cron Trigger:
 * 1. Auto-backup: checkpoint /home/openclaw if the gateway is currently running,
 *    so at most one cron interval of conversation/config is ever at risk of loss
 *    (e.g. from a crash-recovery restore reverting to a stale snapshot). Skipped
 *    when the gateway isn't running — nothing new to capture, and no point waking
 *    an idle container just to back it up.
 * 2. Wake the container if OpenClaw has upcoming cron jobs.
 *
 * Reads the cron job store from R2 (synced by the background sync loop in the container)
 * and checks if any job is scheduled to fire within the lead time window. If so, wakes
 * the container so OpenClaw's internal timers can fire on time.
 *
 * Configure via environment variables:
 * - CRON_WAKE_AHEAD_MINUTES: How many minutes before a cron job to wake (default: 10)
 *
 * Configure the check interval in wrangler.jsonc triggers.crons (default: every 30 minutes).
 */
export async function handleScheduled(env: OpenClawEnv): Promise<void> {
  const sandbox = getSandbox(env.Sandbox, 'openclaw', buildSandboxOptions(env));

  try {
    const gatewayProcess = await findExistingGatewayProcess(sandbox);
    if (gatewayProcess) {
      await createSnapshot(sandbox, env.BACKUP_BUCKET);
      console.log('[CRON] Auto-backup complete');
    } else {
      console.log('[CRON] Gateway not running, skipping auto-backup');
    }
  } catch (e) {
    console.error('[CRON] Auto-backup failed:', e);
  }

  const cronStoreObject = await env.BACKUP_BUCKET.get(CRON_STORE_R2_KEY);
  if (!cronStoreObject) {
    console.log('[CRON] No cron store found in R2, skipping wake check');
    return;
  }

  const cronStoreJson = await cronStoreObject.text();
  const leadMinutes = parseInt(env.CRON_WAKE_AHEAD_MINUTES || '', 10);
  const leadTimeMs = leadMinutes > 0 ? leadMinutes * 60 * 1000 : DEFAULT_LEAD_TIME_MS;
  const nowMs = Date.now();

  const earliestRun = shouldWakeContainer(cronStoreJson, nowMs, leadTimeMs);
  if (!earliestRun) {
    console.log('[CRON] No upcoming cron jobs within lead time, skipping wake');
    return;
  }

  const deltaMinutes = ((earliestRun - nowMs) / 60_000).toFixed(1);
  console.log(`[CRON] Cron job due in ${deltaMinutes}m, waking container`);

  await ensureGateway(sandbox, env);
  console.log('[CRON] Container woken successfully');
}
