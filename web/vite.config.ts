import { defineConfig } from "vite";
import preact from "@preact/preset-vite";
import type { IncomingMessage } from "http";
import type { ServerOptions } from "https";
import { readFileSync, existsSync } from "fs";

const tlsCert = process.env.CYDO_TLS_CERT;
const tlsKey = process.env.CYDO_TLS_KEY;
const authUser = process.env.CYDO_AUTH_USER;
const authPass = process.env.CYDO_AUTH_PASS;
const backendPort = process.env.CYDO_LISTEN_PORT ?? "3940";

const backendProto = tlsCert && tlsKey ? "https" : "http";

const https: ServerOptions | undefined =
  tlsCert && tlsKey && existsSync(tlsCert) && existsSync(tlsKey)
    ? { cert: readFileSync(tlsCert!), key: readFileSync(tlsKey!) }
    : undefined;

// Forward basic auth header to backend proxy requests
const authHeader =
  authUser || authPass
    ? "Basic " + Buffer.from(`${authUser ?? ""}:${authPass ?? ""}`).toString("base64")
    : undefined;

function addAuthHeader(_proxyReq: unknown, _req: IncomingMessage, _res: unknown) {
  if (authHeader) {
    const proxyReq = _proxyReq as IncomingMessage & { setHeader(k: string, v: string): void };
    proxyReq.setHeader("Authorization", authHeader);
  }
}

export default defineConfig({
  plugins: [preact()],
  server: {
    https,
    proxy: {
      "/ws": {
        target: `${backendProto}://localhost:${backendPort}`,
        ws: true,
        secure: false,
        configure: (proxy) => {
          proxy.on("proxyReq", addAuthHeader);
          proxy.on("proxyReqWs", addAuthHeader);
        },
      },
      "/api": {
        target: `${backendProto}://localhost:${backendPort}`,
        secure: false,
        configure: (proxy) => {
          proxy.on("proxyReq", addAuthHeader);
        },
      },
    },
  },
  optimizeDeps: {
    esbuildOptions: {
      minify: false,
    },
  },
  build: {
    outDir: "dist",
    sourcemap: true,
  },
});
