import './style.css';
import { analytics } from './analytics';
import { latestDownloadableRelease, releaseAPI, releasesURL } from './release.mjs';

analytics.capture('$pageview');
console.log('%cSide A%c  Read the source: https://github.com/arnenoori/side-a-source  (and try the Konami code)', 'font-weight:600', 'color:#657069');
const analyticsToggle = document.querySelector<HTMLInputElement>('#analytics-enabled')!;
analyticsToggle.checked = analytics.isEnabled();
analyticsToggle.disabled = analytics.privacySignal();
analyticsToggle.addEventListener('change', () => analytics.setDisabled(!analyticsToggle.checked));

document.querySelectorAll<HTMLButtonElement>('[data-open]').forEach(button => {
  button.addEventListener('click', () => {
    const dialog = document.getElementById(button.dataset.open!) as HTMLDialogElement;
    dialog.showModal();
    if (dialog.id === 'setup') analytics.capture('setup_opened');
  });
});
document.querySelectorAll<HTMLDialogElement>('dialog').forEach(dialog => {
  dialog.querySelector('[data-close]')?.addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });
});

const download = document.querySelector<HTMLAnchorElement>('#download')!;
const label = document.querySelector('#download-label')!;
const status = document.querySelector('#release-status')!;
let downloadVersion: string | undefined;
download.addEventListener('click', event => {
  if (download.getAttribute('aria-disabled') === 'true') { event.preventDefault(); return; }
  if (downloadVersion) analytics.capture('download_clicked', { version: downloadVersion });
  else if (download.href === releasesURL) analytics.capture('release_list_opened');
});
async function loadRelease() {
  try {
    const response = await fetch(releaseAPI, { signal: AbortSignal.timeout(7000), credentials: 'omit', headers: { Accept: 'application/vnd.github+json' } });
    if (!response.ok && response.status !== 404) throw new Error('Release lookup unavailable');
    const release = response.ok ? latestDownloadableRelease(await response.json()) : null;
    if (release) {
      download.href = release.url;
      downloadVersion = release.version;
      download.removeAttribute('aria-disabled');
      label.textContent = 'Download for Mac';
      status.textContent = `v${release.version} · ${(release.size / 1048576).toFixed(1)} MB · Free public preview`;
    } else {
      download.setAttribute('aria-disabled', 'true');
      label.textContent = 'Coming soon';
      status.textContent = 'The first signed download is on its way.';
    }
  } catch {
    analytics.capture('release_lookup_failed');
    download.href = releasesURL;
    download.removeAttribute('aria-disabled');
    label.textContent = 'View downloads';
    status.textContent = 'Check available versions on GitHub.';
  }
}
void loadRelease();
// The poster is a 2x frame of the live scene. Live 3D only loads on capable, idle desktops;
// everywhere else the poster is the product image.
const fallback = document.querySelector<HTMLImageElement>('#fallback')!;
const connection = (navigator as Navigator & { connection?: { saveData?: boolean } }).connection;
const lightweight = matchMedia('(prefers-reduced-motion: reduce), (max-width: 600px), (pointer: coarse)').matches
  || connection?.saveData === true || (navigator.hardwareConcurrency || 8) <= 4;
const idle = () => new Promise<void>(resolve => ('requestIdleCallback' in window
  ? requestIdleCallback(() => resolve(), { timeout: 2000 }) : setTimeout(resolve, 200)));
if (lightweight) {
  document.querySelector<HTMLCanvasElement>('#player')!.hidden = true;
} else {
  void fallback.decode().catch(() => {}).then(idle).then(() => import('./player')).then(({ startPlayer }) => startPlayer()).catch(error => {
    analytics.capture('demo_load_failed');
    console.warn('Interactive preview unavailable; showing the product image.', error);
    document.querySelector<HTMLCanvasElement>('#player')!.hidden = true;
  });
}

// WebMCP is progressive enhancement: current draft uses document; early browsers use navigator.
// These tools only expose the same public information a visitor can read on the page.
import { createAgentTools } from './agent-tools.mjs';
type ModelContext = { registerTool: (tool: ReturnType<typeof createAgentTools>[number]) => void | Promise<void> };
const modelContext = (document as Document & { modelContext?: ModelContext }).modelContext
  ?? (navigator as Navigator & { modelContext?: ModelContext }).modelContext;
if (modelContext?.registerTool) {
  for (const tool of createAgentTools()) {
    try { void Promise.resolve(modelContext.registerTool(tool)).catch(() => {}); } catch { /* Early implementations may differ. */ }
  }
}

// Easter egg: the logo disc turns with each tap; five quick taps shuffle the player's tracks.
const mark = document.querySelector<HTMLElement>('.disc-mark');
let turns = 0, taps = 0, lastTap = 0;
mark?.addEventListener('click', event => {
  event.preventDefault();
  mark.style.transform = `rotate(${++turns * 180}deg)`;
  taps = performance.now() - lastTap < 600 ? taps + 1 : 1;
  lastTap = performance.now();
  if (taps === 5) { taps = 0; dispatchEvent(new Event('sidea:shuffle')); }
});
