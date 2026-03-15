import { defineConfig } from "vite";
import preact from "@preact/preset-vite";
import type { IncomingMessage } from "http";
import type { ServerOptions } from "https";
import { readFileSync, existsSync } from "fs";

const tlsCert = process.env.CYDO_TLS_CERT;
const tlsKey = process.env.CYDO_TLS_KEY;
const authUser = process.env.CYDO_AUTH_USER;
const authPass = process.env.CYDO_AUTH_PASS;

const backendProto =
  tlsCert && tlsKey && existsSync(tlsCert) && existsSync(tlsKey)
    ? "https"
    : "http";

const https: ServerOptions | undefined =
  backendProto === "https"
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
        target: `${backendProto}://localhost:3456`,
        ws: true,
        secure: false,
        configure: (proxy) => {
          proxy.on("proxyReq", addAuthHeader);
          proxy.on("proxyReqWs", addAuthHeader);
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
