import { beforeEach, describe, expect, it, vi } from "vitest";
import { Connection } from "./connection";

class MockWebSocket {
  static OPEN = 1;
  static instances: MockWebSocket[] = [];

  binaryType: BinaryType = "blob";
  readyState = MockWebSocket.OPEN;
  onopen: ((this: WebSocket, ev: Event) => unknown) | null = null;
  onclose: ((this: WebSocket, ev: CloseEvent) => unknown) | null = null;
  onerror: ((this: WebSocket, ev: Event) => unknown) | null = null;
  onmessage: ((this: WebSocket, ev: MessageEvent) => unknown) | null = null;
  readonly send = vi.fn();
  readonly close = vi.fn();

  constructor() {
    MockWebSocket.instances.push(this);
  }

  emitMessage(data: string) {
    this.onmessage?.call(
      this as unknown as WebSocket,
      {
        data,
      } as MessageEvent,
    );
  }
}

describe("Connection client error reporting", () => {
  beforeEach(() => {
    MockWebSocket.instances = [];
    Object.defineProperty(globalThis, "location", {
      value: { protocol: "http:", host: "localhost:3940" },
      configurable: true,
    });
    Object.defineProperty(globalThis, "WebSocket", {
      value: MockWebSocket as unknown as typeof WebSocket,
      configurable: true,
    });
  });

  it("reports invalid JSON payloads through onClientError", () => {
    const conn = new Connection();
    const errors: string[] = [];
    conn.onClientError = (message) => {
      errors.push(message);
    };

    conn.connect();
    const ws = MockWebSocket.instances[0]!;
    ws.emitMessage("{bad json");

    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("Failed to parse WebSocket message");
    expect(ws.close).not.toHaveBeenCalled();
  });

  it("reports task envelopes missing both event payload forms", () => {
    const conn = new Connection();
    const errors: string[] = [];
    conn.onClientError = (message) => {
      errors.push(message);
    };

    conn.connect();
    const ws = MockWebSocket.instances[0]!;
    ws.emitMessage(JSON.stringify({ tid: 7, seq: 1 }));

    expect(errors).toEqual([
      "Invalid task envelope for task 7: missing event payload",
    ]);
  });

  it("reports unknown top-level websocket messages", () => {
    const conn = new Connection();
    const errors: string[] = [];
    conn.onClientError = (message) => {
      errors.push(message);
    };

    conn.connect();
    const ws = MockWebSocket.instances[0]!;
    ws.emitMessage(JSON.stringify({ type: "future_protocol", payload: {} }));

    expect(errors).toEqual(["Unknown WebSocket message type: future_protocol"]);
  });

  it("routes agent_usage as a control message", () => {
    const conn = new Connection();
    const controls: string[] = [];
    conn.onControlMessage = (msg) => {
      controls.push(msg.type);
    };

    conn.connect();
    const ws = MockWebSocket.instances[0]!;
    ws.emitMessage(
      JSON.stringify({
        type: "agent_usage",
        agent: "claude",
        updated_at: 1715702400,
        limits: {
          five_hour: { utilization: 42.5, resetsAt: 1715703000 },
        },
      }),
    );

    expect(controls).toEqual(["agent_usage"]);
  });
});
