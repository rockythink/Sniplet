import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://sniplet.elazer.wang',
  output: 'static',
  trailingSlash: 'always',
  // Keep processed scripts external so the deployed script-src 'self' CSP applies.
  vite: { build: { assetsInlineLimit: 0 } },
});
