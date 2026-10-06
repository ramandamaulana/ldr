import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

const runtimeConfigPlugin = {
  name: 'ldr-runtime-config',
  configureServer(server: import('vite').ViteDevServer) {
    const env = loadEnv(server.config.mode, process.cwd(), '');
    server.middlewares.use('/.well-known/ldr-config', (_request, response) => {
      response.setHeader('Content-Type','application/json; charset=utf-8');
      response.setHeader('Cache-Control','no-store');
      response.end(JSON.stringify({ url: env.SUPABASE_URL || process.env.SUPABASE_URL || '', key: env.SUPABASE_PUBLISHABLE_KEY || env.SUPABASE_ANON_KEY || process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY || '' }));
    });
  },
};

export default defineConfig({
  plugins: [react(),runtimeConfigPlugin], server: { port: 3000 }, preview: { port: 3000 },
  build: { rollupOptions: { output: { manualChunks(id) {
    if (id.includes('/node_modules/react') || id.includes('/node_modules/scheduler')) return 'react-vendor';
    if (id.includes('/node_modules/@supabase/')) return 'supabase-vendor';
    if (id.includes('/node_modules/@tanstack/')) return 'query-vendor';
    if (id.includes('/node_modules/zod/')) return 'validation-vendor';
  } } } },
});
