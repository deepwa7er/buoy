import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// In development the Vite dev server proxies API requests to the Rust backend on
// 127.0.0.1:8092. In production buoy-server serves the built assets directly, so
// requests are same-origin and no proxy applies.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8092",
        changeOrigin: true,
      },
    },
  },
});
