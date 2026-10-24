import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')) as { version: string };
const mockPort = Number(process.env['MOCK_PORT'] ?? 8741);
const mockTarget = `http://127.0.0.1:${mockPort}`;

// Files that must keep a fixed name at the web root (the server and the
// browser look them up by path).
const fixedNames: Record<string, string> = {
  sw: 'sw.js',
  'voice-worklet': 'voice-worklet.js',
};

export default defineConfig({
  base: '/',
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'es2022',
    assetsInlineLimit: 0,
    modulePreload: { polyfill: false },
    rollupOptions: {
      input: {
        index: fileURLToPath(new URL('./index.html', import.meta.url)),
        sw: fileURLToPath(new URL('./src/sw.ts', import.meta.url)),
        'voice-worklet': fileURLToPath(new URL('./src/voice/worklet.ts', import.meta.url)),
      },
      output: {
        entryFileNames: (chunk) => fixedNames[chunk.name] ?? 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
  server: {
    host: true,
    port: 5173,
    proxy: {
      '/ws': { target: mockTarget, ws: true },
      '/api': { target: mockTarget },
      '/remoto.crt': { target: mockTarget },
      '/__mock': { target: mockTarget },
    },
  },
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'node',
  },
});
