// Verify that the final release bundle embeds only the configured browser
// Maps key. Never print the configured key or the generated config contents.

import { readFileSync } from 'node:fs';

const expected = process.env.ERAS_GOOGLE_MAPS_API_KEY;
if (!expected || !/^AIza[A-Za-z0-9_-]{35}$/.test(expected)) {
  console.error('ERAS_GOOGLE_MAPS_API_KEY is missing or malformed; value not shown.');
  process.exit(1);
}

const configPath = 'build/web/google_maps_config.js';
const indexPath = 'build/web/index.html';
const loaderPath = 'build/web/eras_google_maps_loader.js';
let config;
let indexHtml;
try {
  config = readFileSync(configPath, 'utf8');
  indexHtml = readFileSync(indexPath, 'utf8');
  readFileSync(loaderPath, 'utf8');
} catch {
  console.error('Release bundle is missing its Maps config, shared loader, or index.html.');
  process.exit(1);
}

const expectedConfig = `window.ERAS_GOOGLE_MAPS_API_KEY = '${expected}';`;
if (config.trim() !== expectedConfig) {
  console.error('Release bundle Maps key does not exactly match ERAS_GOOGLE_MAPS_API_KEY; value not shown.');
  process.exit(1);
}

const loaderReferences =
  indexHtml.split('eras_google_maps_loader.js').length - 1;
if (loaderReferences !== 1) {
  console.error('Release index.html must reference the shared Maps loader exactly once.');
  process.exit(1);
}
if (/maps\.googleapis\.com\/maps\/api\/js/.test(indexHtml)) {
  console.error('Release index.html contains an additional Maps API loader path.');
  process.exit(1);
}

console.log('Verified: release bundle uses the configured Maps browser key and shared loader.');
