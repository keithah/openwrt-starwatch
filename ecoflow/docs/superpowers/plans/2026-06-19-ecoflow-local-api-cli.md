# EcoFlow Local API and CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local-only Node/TypeScript CLI and HTTP API for monitoring and controlling an EcoFlow River 3 Plus at `192.168.8.112`.

**Architecture:** Create a portable `ecoflow-local` core with explicit TypeScript domain types, an adapter interface, a fake adapter for tests, a local probing adapter for live discovery, a Fastify HTTP server under `/v1`, and a thin CLI that emits JSON by default. The stable JSON API and `docs/protocol-river-3-plus.md` are deliverables so the implementation can be ported to Swift later.

**Tech Stack:** Node.js 20+, TypeScript, Vitest, tsx, Fastify, Commander, Zod.

---

## Command Locations

- Run npm commands from `/Users/keith/src/ecoflow`.
- Run git commands from `/Users/keith/src`, because `ecoflow` is a subdirectory of the shared git worktree.
- Stage only `ecoflow/...` paths so unrelated worktree changes are left alone.

## File Structure

- `package.json`: npm scripts, binary entry, runtime and dev dependencies.
- `tsconfig.json`: strict TypeScript build settings.
- `vitest.config.ts`: test runner configuration.
- `src/domain/types.ts`: portable enums, status models, command result models, diagnostics models, and error codes.
- `src/domain/normalize.ts`: small pure helpers for derived status fields.
- `src/config.ts`: environment and CLI/default configuration helpers.
- `src/local/adapter.ts`: `EcoFlowAdapter` interface used by HTTP and CLI.
- `src/local/fake-adapter.ts`: deterministic in-memory adapter for tests and offline development.
- `src/local/probe-adapter.ts`: live local adapter skeleton for LAN probing and future protocol mapping.
- `src/http/errors.ts`: stable JSON error helpers.
- `src/http/server.ts`: Fastify app factory exposing `/v1` endpoints.
- `src/cli.ts`: command-line interface.
- `src/index.ts`: public exports for reuse and Swift-port reference.
- `tests/domain.test.ts`: pure model and normalization tests.
- `tests/http.test.ts`: API contract tests with the fake adapter.
- `tests/cli.test.ts`: CLI JSON and exit-code tests.
- `docs/api.md`: stable API contract for integrations and Swift porting.
- `docs/protocol-river-3-plus.md`: live protocol notes and diagnostic log format.

## Task 1: Project Scaffold

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `vitest.config.ts`
- Create: `src/index.ts`

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "ecoflow-local",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "bin": {
    "ecoflow": "./dist/cli.js"
  },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "test": "vitest run",
    "test:watch": "vitest",
    "dev": "tsx src/cli.ts",
    "start": "node dist/cli.js"
  },
  "dependencies": {
    "@fastify/sensible": "^5.6.0",
    "commander": "^12.1.0",
    "fastify": "^4.28.1",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@types/node": "^20.14.10",
    "tsx": "^4.16.2",
    "typescript": "^5.5.3",
    "vitest": "^1.6.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true,
    "declaration": true,
    "sourceMap": true,
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src/**/*.ts"],
  "exclude": ["dist", "node_modules"]
}
```

- [ ] **Step 3: Create `vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["tests/**/*.test.ts"]
  }
});
```

- [ ] **Step 4: Create `src/index.ts`**

```ts
export * from "./domain/types.js";
export * from "./domain/normalize.js";
export * from "./local/adapter.js";
export * from "./local/fake-adapter.js";
export * from "./local/probe-adapter.js";
export * from "./http/server.js";
```

- [ ] **Step 5: Install dependencies**

Run: `npm install`

Expected: `package-lock.json` is created and npm exits successfully.

- [ ] **Step 6: Run scaffold checks**

Run: `npm run typecheck`

Expected: FAIL with missing exported files such as `Cannot find module './domain/types.js'`. This confirms the scaffold is wired and ready for the next task.

- [ ] **Step 7: Commit**

```bash
git add ecoflow/package.json ecoflow/package-lock.json ecoflow/tsconfig.json ecoflow/vitest.config.ts ecoflow/src/index.ts
git commit -m "chore: scaffold ecoflow typescript project"
```

## Task 2: Domain Types and Normalization

**Files:**
- Create: `src/domain/types.ts`
- Create: `src/domain/normalize.ts`
- Create: `tests/domain.test.ts`

- [ ] **Step 1: Write failing domain tests**

```ts
import { describe, expect, it } from "vitest";
import { buildStats, netWatts, outputControllableFromCapability } from "../src/domain/normalize.js";
import type { DeviceStatus } from "../src/domain/types.js";

describe("domain normalization", () => {
  it("computes negative net watts while discharging", () => {
    expect(netWatts(0, 34)).toBe(-34);
  });

  it("computes positive net watts while charging", () => {
    expect(netWatts(125, 10)).toBe(115);
  });

  it("builds stats from a status snapshot", () => {
    const status: DeviceStatus = {
      battery: { percent: 72, state: "discharging" },
      power: { inputWatts: 0, outputWatts: 34, netWatts: -34 },
      outputs: {
        ac: { state: "on", watts: 28 },
        dc: { state: "off", watts: 0 },
        usb: { state: "unknown", watts: null }
      },
      updatedAt: "2026-06-19T09:00:00.000Z"
    };

    expect(buildStats(status)).toEqual({
      batteryPercent: 72,
      inputWatts: 0,
      outputWatts: 34,
      netWatts: -34,
      estimatedMinutesRemaining: null,
      estimatedMinutesToFull: null,
      isEstimateDerived: false,
      updatedAt: "2026-06-19T09:00:00.000Z"
    });
  });

  it("uses capability values for output controllability", () => {
    expect(outputControllableFromCapability("supported")).toBe("supported");
    expect(outputControllableFromCapability("unsupported")).toBe("unsupported");
    expect(outputControllableFromCapability("unknown")).toBe("unknown");
  });
});
```

- [ ] **Step 2: Run test to verify failure**

Run: `npm test -- tests/domain.test.ts`

Expected: FAIL with missing `src/domain/types.ts` or `src/domain/normalize.ts`.

- [ ] **Step 3: Implement `src/domain/types.ts`**

```ts
export type Capability = "supported" | "unsupported" | "unknown";
export type BatteryState = "charging" | "discharging" | "idle" | "full" | "unknown";
export type OutputState = "on" | "off" | "unknown";
export type OutputTarget = "ac" | "dc" | "usb";
export type CommandResult = "applied" | "rejected" | "unsupported" | "unknown" | "failed";
export type DiagnosticDirection = "inbound" | "outbound";

export interface DeviceIdentity {
  name: string;
  model: "river_3_plus";
  ip: string;
  serialNumber: string | null;
  firmwareVersion: string | null;
}

export interface DeviceCapabilities {
  outputs: Record<OutputTarget, Capability>;
  shutdown: Capability;
  diagnostics: Capability;
}

export interface DeviceInfo {
  device: DeviceIdentity;
  capabilities: DeviceCapabilities;
}

export interface BatteryStatus {
  percent: number | null;
  state: BatteryState;
}

export interface PowerStatus {
  inputWatts: number | null;
  outputWatts: number | null;
  netWatts: number | null;
}

export interface OutputStatus {
  state: OutputState;
  watts: number | null;
}

export interface OutputStatusWithControllability extends OutputStatus {
  controllable: Capability;
}

export interface DeviceStatus {
  battery: BatteryStatus;
  power: PowerStatus;
  outputs: Record<OutputTarget, OutputStatus>;
  updatedAt: string;
}

export interface DeviceStats {
  batteryPercent: number | null;
  inputWatts: number | null;
  outputWatts: number | null;
  netWatts: number | null;
  estimatedMinutesRemaining: number | null;
  estimatedMinutesToFull: number | null;
  isEstimateDerived: boolean;
  updatedAt: string;
}

export interface OutputsSnapshot {
  outputs: Record<OutputTarget, OutputStatusWithControllability>;
  updatedAt: string;
}

export interface ControlResponse {
  target: OutputTarget | "device";
  requestedState: OutputState | "shutdown";
  result: CommandResult;
  observedState: OutputState | "unknown";
  message: string | null;
}

export interface DiagnosticObservation {
  timestamp: string;
  transport: string;
  direction: DiagnosticDirection;
  raw: string;
  decoded: unknown;
  notes: string;
}

export interface DiagnosticsSnapshot {
  deviceIp: string;
  observations: DiagnosticObservation[];
}

export type ErrorCode =
  | "device_unreachable"
  | "protocol_timeout"
  | "protocol_decode_failed"
  | "invalid_request"
  | "unsupported_operation"
  | "command_rejected"
  | "command_unverified"
  | "internal_error";

export interface ApiErrorBody {
  error: {
    code: ErrorCode;
    message: string;
    details: Record<string, unknown>;
  };
}
```

- [ ] **Step 4: Implement `src/domain/normalize.ts`**

```ts
import type {
  Capability,
  DeviceCapabilities,
  DeviceStats,
  DeviceStatus,
  OutputsSnapshot
} from "./types.js";

export function netWatts(inputWatts: number | null, outputWatts: number | null): number | null {
  if (inputWatts === null || outputWatts === null) {
    return null;
  }

  return inputWatts - outputWatts;
}

export function buildStats(status: DeviceStatus): DeviceStats {
  return {
    batteryPercent: status.battery.percent,
    inputWatts: status.power.inputWatts,
    outputWatts: status.power.outputWatts,
    netWatts: status.power.netWatts,
    estimatedMinutesRemaining: null,
    estimatedMinutesToFull: null,
    isEstimateDerived: false,
    updatedAt: status.updatedAt
  };
}

export function outputControllableFromCapability(capability: Capability): Capability {
  return capability;
}

export function buildOutputsSnapshot(status: DeviceStatus, capabilities: DeviceCapabilities): OutputsSnapshot {
  return {
    outputs: {
      ac: { ...status.outputs.ac, controllable: outputControllableFromCapability(capabilities.outputs.ac) },
      dc: { ...status.outputs.dc, controllable: outputControllableFromCapability(capabilities.outputs.dc) },
      usb: { ...status.outputs.usb, controllable: outputControllableFromCapability(capabilities.outputs.usb) }
    },
    updatedAt: status.updatedAt
  };
}
```

- [ ] **Step 5: Run tests**

Run: `npm test -- tests/domain.test.ts`

Expected: PASS.

- [ ] **Step 6: Run typecheck**

Run: `npm run typecheck`

Expected: FAIL because adapter/server exports in `src/index.ts` are not implemented yet.

- [ ] **Step 7: Commit**

```bash
git add ecoflow/src/domain ecoflow/tests/domain.test.ts
git commit -m "feat: add ecoflow domain contract"
```

## Task 3: Adapter Interface and Fake Adapter

**Files:**
- Create: `src/local/adapter.ts`
- Create: `src/local/fake-adapter.ts`
- Create: `src/local/probe-adapter.ts`
- Create: `tests/fake-adapter.test.ts`

- [ ] **Step 1: Write failing fake adapter tests**

```ts
import { describe, expect, it } from "vitest";
import { FakeEcoFlowAdapter } from "../src/local/fake-adapter.js";

describe("FakeEcoFlowAdapter", () => {
  it("returns River 3 Plus identity and unknown local capabilities", async () => {
    const adapter = new FakeEcoFlowAdapter({ host: "192.168.8.112" });

    await expect(adapter.getDeviceInfo()).resolves.toEqual({
      device: {
        name: "EcoFlow River 3 Plus",
        model: "river_3_plus",
        ip: "192.168.8.112",
        serialNumber: null,
        firmwareVersion: null
      },
      capabilities: {
        outputs: { ac: "unknown", dc: "unknown", usb: "unknown" },
        shutdown: "unknown",
        diagnostics: "supported"
      }
    });
  });

  it("updates fake AC state and reports applied", async () => {
    const adapter = new FakeEcoFlowAdapter({ host: "192.168.8.112" });

    await expect(adapter.setOutput("ac", "on")).resolves.toEqual({
      target: "ac",
      requestedState: "on",
      result: "applied",
      observedState: "on",
      message: null
    });

    const status = await adapter.getStatus();
    expect(status.outputs.ac.state).toBe("on");
  });

  it("reports shutdown unsupported by default", async () => {
    const adapter = new FakeEcoFlowAdapter({ host: "192.168.8.112" });

    await expect(adapter.shutdown()).resolves.toEqual({
      target: "device",
      requestedState: "shutdown",
      result: "unsupported",
      observedState: "unknown",
      message: "Whole-device shutdown is not exposed by the verified local protocol."
    });
  });
});
```

- [ ] **Step 2: Run test to verify failure**

Run: `npm test -- tests/fake-adapter.test.ts`

Expected: FAIL with missing `src/local/fake-adapter.ts`.

- [ ] **Step 3: Implement `src/local/adapter.ts`**

```ts
import type {
  ControlResponse,
  DeviceInfo,
  DeviceStatus,
  DiagnosticsSnapshot,
  OutputState,
  OutputTarget
} from "../domain/types.js";

export interface EcoFlowAdapter {
  getDeviceInfo(): Promise<DeviceInfo>;
  getStatus(): Promise<DeviceStatus>;
  getDiagnostics(): Promise<DiagnosticsSnapshot>;
  setOutput(target: OutputTarget, state: Exclude<OutputState, "unknown">): Promise<ControlResponse>;
  shutdown(): Promise<ControlResponse>;
}

export interface AdapterOptions {
  host: string;
  pollIntervalMs?: number;
}
```

- [ ] **Step 4: Implement `src/local/fake-adapter.ts`**

```ts
import { buildOutputsSnapshot, buildStats } from "../domain/normalize.js";
import type {
  ControlResponse,
  DeviceCapabilities,
  DeviceInfo,
  DeviceStatus,
  DiagnosticsSnapshot,
  OutputState,
  OutputTarget
} from "../domain/types.js";
import type { AdapterOptions, EcoFlowAdapter } from "./adapter.js";

export class FakeEcoFlowAdapter implements EcoFlowAdapter {
  private readonly host: string;
  private readonly capabilities: DeviceCapabilities = {
    outputs: { ac: "unknown", dc: "unknown", usb: "unknown" },
    shutdown: "unknown",
    diagnostics: "supported"
  };

  private status: DeviceStatus;

  constructor(options: AdapterOptions) {
    this.host = options.host;
    this.status = {
      battery: { percent: 72, state: "discharging" },
      power: { inputWatts: 0, outputWatts: 34, netWatts: -34 },
      outputs: {
        ac: { state: "off", watts: 0 },
        dc: { state: "off", watts: 0 },
        usb: { state: "unknown", watts: null }
      },
      updatedAt: "2026-06-19T09:00:00.000Z"
    };
  }

  async getDeviceInfo(): Promise<DeviceInfo> {
    return {
      device: {
        name: "EcoFlow River 3 Plus",
        model: "river_3_plus",
        ip: this.host,
        serialNumber: null,
        firmwareVersion: null
      },
      capabilities: this.capabilities
    };
  }

  async getStatus(): Promise<DeviceStatus> {
    return this.status;
  }

  async getStats() {
    return buildStats(this.status);
  }

  async getOutputs() {
    return buildOutputsSnapshot(this.status, this.capabilities);
  }

  async getDiagnostics(): Promise<DiagnosticsSnapshot> {
    return {
      deviceIp: this.host,
      observations: [
        {
          timestamp: this.status.updatedAt,
          transport: "fake",
          direction: "inbound",
          raw: "",
          decoded: this.status,
          notes: "Deterministic fake status for tests."
        }
      ]
    };
  }

  async setOutput(target: OutputTarget, state: Exclude<OutputState, "unknown">): Promise<ControlResponse> {
    this.status = {
      ...this.status,
      outputs: {
        ...this.status.outputs,
        [target]: {
          ...this.status.outputs[target],
          state
        }
      },
      updatedAt: this.status.updatedAt
    };

    return {
      target,
      requestedState: state,
      result: "applied",
      observedState: state,
      message: null
    };
  }

  async shutdown(): Promise<ControlResponse> {
    return {
      target: "device",
      requestedState: "shutdown",
      result: "unsupported",
      observedState: "unknown",
      message: "Whole-device shutdown is not exposed by the verified local protocol."
    };
  }
}
```

- [ ] **Step 5: Implement `src/local/probe-adapter.ts`**

```ts
import type {
  ControlResponse,
  DeviceInfo,
  DeviceStatus,
  DiagnosticsSnapshot,
  OutputState,
  OutputTarget
} from "../domain/types.js";
import type { AdapterOptions, EcoFlowAdapter } from "./adapter.js";

export class ProbeEcoFlowAdapter implements EcoFlowAdapter {
  private readonly host: string;

  constructor(options: AdapterOptions) {
    this.host = options.host;
  }

  async getDeviceInfo(): Promise<DeviceInfo> {
    return {
      device: {
        name: "EcoFlow River 3 Plus",
        model: "river_3_plus",
        ip: this.host,
        serialNumber: null,
        firmwareVersion: null
      },
      capabilities: {
        outputs: { ac: "unknown", dc: "unknown", usb: "unknown" },
        shutdown: "unknown",
        diagnostics: "supported"
      }
    };
  }

  async getStatus(): Promise<DeviceStatus> {
    const now = new Date().toISOString();

    return {
      battery: { percent: null, state: "unknown" },
      power: { inputWatts: null, outputWatts: null, netWatts: null },
      outputs: {
        ac: { state: "unknown", watts: null },
        dc: { state: "unknown", watts: null },
        usb: { state: "unknown", watts: null }
      },
      updatedAt: now
    };
  }

  async getDiagnostics(): Promise<DiagnosticsSnapshot> {
    return {
      deviceIp: this.host,
      observations: [
        {
          timestamp: new Date().toISOString(),
          transport: "probe",
          direction: "inbound",
          raw: "",
          decoded: null,
          notes: "Live local probing is scaffolded; protocol mapping is implemented in a later task."
        }
      ]
    };
  }

  async setOutput(target: OutputTarget, state: Exclude<OutputState, "unknown">): Promise<ControlResponse> {
    return {
      target,
      requestedState: state,
      result: "unknown",
      observedState: "unknown",
      message: "Local control command has not been verified for this device yet."
    };
  }

  async shutdown(): Promise<ControlResponse> {
    return {
      target: "device",
      requestedState: "shutdown",
      result: "unsupported",
      observedState: "unknown",
      message: "Whole-device shutdown is not exposed by the verified local protocol."
    };
  }
}
```

- [ ] **Step 6: Run tests**

Run: `npm test -- tests/domain.test.ts tests/fake-adapter.test.ts`

Expected: PASS.

- [ ] **Step 7: Run typecheck**

Run: `npm run typecheck`

Expected: FAIL because `src/http/server.ts` export is not implemented yet.

- [ ] **Step 8: Commit**

```bash
git add ecoflow/src/local ecoflow/tests/fake-adapter.test.ts
git commit -m "feat: add ecoflow adapter contract"
```

## Task 4: HTTP API

**Files:**
- Create: `src/http/errors.ts`
- Create: `src/http/server.ts`
- Create: `tests/http.test.ts`

- [ ] **Step 1: Write failing HTTP tests**

```ts
import { afterEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { createServer } from "../src/http/server.js";
import { FakeEcoFlowAdapter } from "../src/local/fake-adapter.js";

describe("HTTP API", () => {
  let app: FastifyInstance | undefined;

  afterEach(async () => {
    if (app) {
      await app.close();
      app = undefined;
    }
  });

  it("returns device info", async () => {
    app = createServer({ adapter: new FakeEcoFlowAdapter({ host: "192.168.8.112" }) });

    const response = await app.inject({ method: "GET", url: "/v1/device" });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      device: { model: "river_3_plus", ip: "192.168.8.112" },
      capabilities: { diagnostics: "supported" }
    });
  });

  it("returns normalized status", async () => {
    app = createServer({ adapter: new FakeEcoFlowAdapter({ host: "192.168.8.112" }) });

    const response = await app.inject({ method: "GET", url: "/v1/status" });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      battery: { percent: 72, state: "discharging" },
      power: { inputWatts: 0, outputWatts: 34, netWatts: -34 }
    });
  });

  it("returns invalid_request for bad output state", async () => {
    app = createServer({ adapter: new FakeEcoFlowAdapter({ host: "192.168.8.112" }) });

    const response = await app.inject({
      method: "POST",
      url: "/v1/outputs/ac",
      payload: { state: "invalid" }
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: {
        code: "invalid_request",
        message: "Request body must include state set to on or off.",
        details: { target: "ac" }
      }
    });
  });

  it("applies AC output command", async () => {
    app = createServer({ adapter: new FakeEcoFlowAdapter({ host: "192.168.8.112" }) });

    const response = await app.inject({
      method: "POST",
      url: "/v1/outputs/ac",
      payload: { state: "on" }
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      target: "ac",
      requestedState: "on",
      result: "applied",
      observedState: "on",
      message: null
    });
  });
});
```

- [ ] **Step 2: Run test to verify failure**

Run: `npm test -- tests/http.test.ts`

Expected: FAIL with missing `src/http/server.ts`.

- [ ] **Step 3: Implement `src/http/errors.ts`**

```ts
import type { ApiErrorBody, ErrorCode } from "../domain/types.js";

export class ApiError extends Error {
  readonly statusCode: number;
  readonly code: ErrorCode;
  readonly details: Record<string, unknown>;

  constructor(statusCode: number, code: ErrorCode, message: string, details: Record<string, unknown> = {}) {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
  }

  toBody(): ApiErrorBody {
    return {
      error: {
        code: this.code,
        message: this.message,
        details: this.details
      }
    };
  }
}
```

- [ ] **Step 4: Implement `src/http/server.ts`**

```ts
import sensible from "@fastify/sensible";
import Fastify from "fastify";
import { z } from "zod";
import { buildOutputsSnapshot, buildStats } from "../domain/normalize.js";
import type { OutputTarget } from "../domain/types.js";
import type { EcoFlowAdapter } from "../local/adapter.js";
import { ApiError } from "./errors.js";

const outputBodySchema = z.object({
  state: z.enum(["on", "off"])
});

const outputTargets = ["ac", "dc", "usb"] as const satisfies readonly OutputTarget[];

export interface CreateServerOptions {
  adapter: EcoFlowAdapter;
}

export function createServer(options: CreateServerOptions) {
  const app = Fastify({ logger: false });

  void app.register(sensible);

  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof ApiError) {
      void reply.status(error.statusCode).send(error.toBody());
      return;
    }

    void reply.status(500).send({
      error: {
        code: "internal_error",
        message: "Internal server error.",
        details: {}
      }
    });
  });

  app.get("/v1/device", async () => options.adapter.getDeviceInfo());

  app.get("/v1/status", async () => options.adapter.getStatus());

  app.get("/v1/stats", async () => buildStats(await options.adapter.getStatus()));

  app.get("/v1/outputs", async () => {
    const [status, info] = await Promise.all([options.adapter.getStatus(), options.adapter.getDeviceInfo()]);
    return buildOutputsSnapshot(status, info.capabilities);
  });

  for (const target of outputTargets) {
    app.post(`/v1/outputs/${target}`, async (request) => {
      const parsed = outputBodySchema.safeParse(request.body);
      if (!parsed.success) {
        throw new ApiError(400, "invalid_request", "Request body must include state set to on or off.", { target });
      }

      return options.adapter.setOutput(target, parsed.data.state);
    });
  }

  app.post("/v1/power/shutdown", async () => options.adapter.shutdown());

  app.get("/v1/diagnostics", async () => options.adapter.getDiagnostics());

  return app;
}
```

- [ ] **Step 5: Run HTTP tests**

Run: `npm test -- tests/http.test.ts`

Expected: PASS.

- [ ] **Step 6: Run full tests and typecheck**

Run: `npm test`

Expected: PASS.

Run: `npm run typecheck`

Expected: PASS after HTTP export exists.

- [ ] **Step 7: Commit**

```bash
git add ecoflow/src/http ecoflow/tests/http.test.ts
git commit -m "feat: expose ecoflow http api"
```

## Task 5: CLI and Config

**Files:**
- Create: `src/config.ts`
- Create: `src/cli.ts`
- Create: `tests/cli.test.ts`

- [ ] **Step 1: Write failing CLI tests**

```ts
import { describe, expect, it } from "vitest";
import { runCli } from "../src/cli.js";
import { FakeEcoFlowAdapter } from "../src/local/fake-adapter.js";

describe("CLI", () => {
  it("prints JSON status", async () => {
    const writes: string[] = [];
    const code = await runCli(["status", "--host", "192.168.8.112"], {
      adapterFactory: (host) => new FakeEcoFlowAdapter({ host }),
      stdout: (text) => writes.push(text),
      stderr: () => undefined
    });

    expect(code).toBe(0);
    expect(JSON.parse(writes.join(""))).toMatchObject({
      battery: { percent: 72, state: "discharging" }
    });
  });

  it("returns zero when a control command is applied", async () => {
    const writes: string[] = [];
    const code = await runCli(["output", "ac", "on", "--host", "192.168.8.112"], {
      adapterFactory: (host) => new FakeEcoFlowAdapter({ host }),
      stdout: (text) => writes.push(text),
      stderr: () => undefined
    });

    expect(code).toBe(0);
    expect(JSON.parse(writes.join(""))).toEqual({
      target: "ac",
      requestedState: "on",
      result: "applied",
      observedState: "on",
      message: null
    });
  });

  it("returns non-zero when shutdown is unsupported", async () => {
    const writes: string[] = [];
    const code = await runCli(["shutdown", "--host", "192.168.8.112"], {
      adapterFactory: (host) => new FakeEcoFlowAdapter({ host }),
      stdout: (text) => writes.push(text),
      stderr: () => undefined
    });

    expect(code).toBe(2);
    expect(JSON.parse(writes.join(""))).toMatchObject({
      target: "device",
      result: "unsupported"
    });
  });
});
```

- [ ] **Step 2: Run test to verify failure**

Run: `npm test -- tests/cli.test.ts`

Expected: FAIL with missing `src/cli.ts`.

- [ ] **Step 3: Implement `src/config.ts`**

```ts
export const defaultHost = "192.168.8.112";
export const defaultListen = "127.0.0.1:8787";
export const defaultPollIntervalMs = 2000;

export function hostFrom(value: string | undefined, env: NodeJS.ProcessEnv = process.env): string {
  return value ?? env.ECOFLOW_HOST ?? defaultHost;
}

export function listenFrom(value: string | undefined, env: NodeJS.ProcessEnv = process.env): string {
  return value ?? env.ECOFLOW_HTTP_LISTEN ?? defaultListen;
}

export function pollIntervalFrom(value: string | undefined, env: NodeJS.ProcessEnv = process.env): number {
  const raw = value ?? env.ECOFLOW_POLL_INTERVAL_MS;
  if (!raw) {
    return defaultPollIntervalMs;
  }

  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : defaultPollIntervalMs;
}

export function parseListenAddress(listen: string): { host: string; port: number } {
  const [host, portText] = listen.split(":");
  const port = Number.parseInt(portText ?? "", 10);

  if (!host || !Number.isFinite(port)) {
    throw new Error(`Invalid listen address: ${listen}`);
  }

  return { host, port };
}
```

- [ ] **Step 4: Implement `src/cli.ts`**

```ts
#!/usr/bin/env node
import { Command } from "commander";
import { buildOutputsSnapshot, buildStats } from "./domain/normalize.js";
import type { ControlResponse, OutputState, OutputTarget } from "./domain/types.js";
import { createServer } from "./http/server.js";
import type { EcoFlowAdapter } from "./local/adapter.js";
import { ProbeEcoFlowAdapter } from "./local/probe-adapter.js";
import { hostFrom, listenFrom, parseListenAddress } from "./config.js";

export interface CliRuntime {
  adapterFactory?: (host: string) => EcoFlowAdapter;
  stdout?: (text: string) => void;
  stderr?: (text: string) => void;
}

function printJson(stdout: (text: string) => void, value: unknown): void {
  stdout(`${JSON.stringify(value, null, 2)}\n`);
}

function exitCodeForControl(response: ControlResponse): number {
  return response.result === "applied" ? 0 : 2;
}

function adapterFor(host: string, runtime: CliRuntime): EcoFlowAdapter {
  return runtime.adapterFactory?.(host) ?? new ProbeEcoFlowAdapter({ host });
}

export async function runCli(argv: string[], runtime: CliRuntime = {}): Promise<number> {
  const stdout = runtime.stdout ?? ((text) => process.stdout.write(text));
  const stderr = runtime.stderr ?? ((text) => process.stderr.write(text));
  const program = new Command();

  program.name("ecoflow").exitOverride();
  program.configureOutput({
    writeOut: stdout,
    writeErr: stderr
  });

  program
    .command("status")
    .option("--host <host>")
    .action(async (options) => {
      const adapter = adapterFor(hostFrom(options.host), runtime);
      printJson(stdout, await adapter.getStatus());
    });

  program
    .command("stats")
    .option("--host <host>")
    .action(async (options) => {
      const adapter = adapterFor(hostFrom(options.host), runtime);
      printJson(stdout, buildStats(await adapter.getStatus()));
    });

  program
    .command("outputs")
    .option("--host <host>")
    .action(async (options) => {
      const adapter = adapterFor(hostFrom(options.host), runtime);
      const [status, info] = await Promise.all([adapter.getStatus(), adapter.getDeviceInfo()]);
      printJson(stdout, buildOutputsSnapshot(status, info.capabilities));
    });

  program
    .command("output")
    .argument("<target>")
    .argument("<state>")
    .option("--host <host>")
    .action(async (target: OutputTarget, state: Exclude<OutputState, "unknown">, options) => {
      if (!["ac", "dc", "usb"].includes(target) || !["on", "off"].includes(state)) {
        stderr("Usage: ecoflow output <ac|dc|usb> <on|off>\n");
        process.exitCode = 1;
        return;
      }

      const adapter = adapterFor(hostFrom(options.host), runtime);
      const response = await adapter.setOutput(target, state);
      printJson(stdout, response);
      process.exitCode = exitCodeForControl(response);
    });

  program
    .command("shutdown")
    .option("--host <host>")
    .action(async (options) => {
      const adapter = adapterFor(hostFrom(options.host), runtime);
      const response = await adapter.shutdown();
      printJson(stdout, response);
      process.exitCode = exitCodeForControl(response);
    });

  program
    .command("diagnostics")
    .option("--host <host>")
    .action(async (options) => {
      const adapter = adapterFor(hostFrom(options.host), runtime);
      printJson(stdout, await adapter.getDiagnostics());
    });

  program
    .command("serve")
    .option("--host <host>")
    .option("--listen <listen>")
    .action(async (options) => {
      const host = hostFrom(options.host);
      const listen = parseListenAddress(listenFrom(options.listen));
      const app = createServer({ adapter: adapterFor(host, runtime) });
      await app.listen(listen);
      stdout(JSON.stringify({ listening: `${listen.host}:${listen.port}`, deviceHost: host }) + "\n");
    });

  try {
    await program.parseAsync(argv, { from: "user" });
    return process.exitCode && process.exitCode > 0 ? process.exitCode : 0;
  } catch (error) {
    stderr(`${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  } finally {
    process.exitCode = undefined;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const code = await runCli(process.argv.slice(2));
  process.exit(code);
}
```

- [ ] **Step 5: Run CLI tests**

Run: `npm test -- tests/cli.test.ts`

Expected: PASS.

- [ ] **Step 6: Run full checks**

Run: `npm test`

Expected: PASS.

Run: `npm run typecheck`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ecoflow/src/config.ts ecoflow/src/cli.ts ecoflow/tests/cli.test.ts
git commit -m "feat: add ecoflow cli"
```

## Task 6: API and Protocol Documentation

**Files:**
- Create: `docs/api.md`
- Create: `docs/protocol-river-3-plus.md`
- Modify: `README.md`

- [ ] **Step 1: Create `docs/api.md`**

```md
# EcoFlow Local API

Base URL: `http://127.0.0.1:8787`

All endpoints return JSON. Integrations must treat only a control `result` of `applied` as success.

## Capability Values

- `supported`
- `unsupported`
- `unknown`

## Control Result Values

- `applied`: command was sent and observed state matches the request.
- `rejected`: device returned an explicit rejection or error.
- `unsupported`: the local protocol is known not to support the request.
- `unknown`: command was attempted, but the outcome could not be verified.
- `failed`: transport or implementation failure prevented the command attempt.

## Endpoints

### `GET /v1/device`

Returns device identity and capabilities.

### `GET /v1/status`

Returns battery percentage, charge state, input watts, output watts, net watts, and output group state.

### `GET /v1/stats`

Returns charge/discharge stats and estimates when available.

### `GET /v1/outputs`

Returns AC, DC, and USB output states plus controllability.

### `POST /v1/outputs/ac`

Request: `{ "state": "on" }` or `{ "state": "off" }`

### `POST /v1/outputs/dc`

Request: `{ "state": "on" }` or `{ "state": "off" }`

### `POST /v1/outputs/usb`

Request: `{ "state": "on" }` or `{ "state": "off" }`

### `POST /v1/power/shutdown`

Attempts whole-device shutdown only when verified local support exists.

### `GET /v1/diagnostics`

Returns recent probe observations for local protocol mapping.
```

- [ ] **Step 2: Create `docs/protocol-river-3-plus.md`**

````md
# EcoFlow River 3 Plus Local Protocol Notes

Device IP: `192.168.8.112`

## Status

Local protocol mapping is not yet verified for this River 3 Plus. The current implementation exposes stable API shapes and diagnostics while keeping unverified commands from reporting false success.

## Tested Local Transports

No live transport has been verified yet.

## Known Telemetry Fields

No raw River 3 Plus telemetry fields have been mapped yet.

## Known Control Commands

No local output control command has been verified yet.

## Unsupported or Unverified Controls

- Whole-device shutdown is treated as `unsupported` until a verified local command is found.
- AC, DC, and USB output controls are treated as `unknown` in the live probe adapter until verified.

## Swift Port Notes

- Mirror the TypeScript domain models in `src/domain/types.ts` before porting transport code.
- Preserve the control result distinction between `applied`, `rejected`, `unsupported`, `unknown`, and `failed`.
- Do not treat a sent packet as success unless a later observed state confirms the requested change.
- Record raw frames in hex or base64 with timestamp, transport, direction, decoded payload if available, and notes.

## Diagnostic Observation Format

```json
{
  "timestamp": "2026-06-19T09:00:00.000Z",
  "transport": "probe",
  "direction": "inbound",
  "raw": "",
  "decoded": null,
  "notes": "Live local probing is scaffolded; protocol mapping is implemented in a later task."
}
```
````

- [ ] **Step 3: Create `README.md`**

````md
# EcoFlow Local

Local-only Node/TypeScript CLI and HTTP API for an EcoFlow River 3 Plus.

## Install

```sh
npm install
```

## CLI

```sh
npm run dev -- status --host 192.168.8.112
npm run dev -- stats --host 192.168.8.112
npm run dev -- outputs --host 192.168.8.112
npm run dev -- output ac on --host 192.168.8.112
npm run dev -- shutdown --host 192.168.8.112
```

CLI output is JSON by default. Control commands exit `0` only when the result is `applied`.

## HTTP API

```sh
npm run dev -- serve --host 192.168.8.112 --listen 127.0.0.1:8787
```

API documentation lives in [`docs/api.md`](docs/api.md).

## Protocol Notes

River 3 Plus local protocol notes live in [`docs/protocol-river-3-plus.md`](docs/protocol-river-3-plus.md).

## Safety

Live tests are opt-in. Do not run live control tests unless the connected loads can safely lose power.
````

- [ ] **Step 4: Run checks**

Run: `npm test`

Expected: PASS.

Run: `npm run typecheck`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ecoflow/README.md ecoflow/docs/api.md ecoflow/docs/protocol-river-3-plus.md
git commit -m "docs: document ecoflow api and protocol notes"
```

## Task 7: Live Probe Command

**Files:**
- Modify: `src/local/probe-adapter.ts`
- Modify: `docs/protocol-river-3-plus.md`
- Create: `tests/probe-adapter.test.ts`

- [ ] **Step 1: Write failing probe tests**

```ts
import { describe, expect, it } from "vitest";
import { ProbeEcoFlowAdapter } from "../src/local/probe-adapter.js";

describe("ProbeEcoFlowAdapter", () => {
  it("returns diagnostics without changing device state", async () => {
    const adapter = new ProbeEcoFlowAdapter({ host: "192.168.8.112" });

    const diagnostics = await adapter.getDiagnostics();

    expect(diagnostics.deviceIp).toBe("192.168.8.112");
    expect(diagnostics.observations[0]).toMatchObject({
      transport: "probe",
      direction: "inbound"
    });
  });
});
```

- [ ] **Step 2: Run test**

Run: `npm test -- tests/probe-adapter.test.ts`

Expected: PASS with the scaffold from Task 3. This locks in that diagnostics is safe and read-only before live probing is expanded.

- [ ] **Step 3: Add non-destructive TCP port probe to `src/local/probe-adapter.ts`**

Replace the file with:

```ts
import net from "node:net";
import type {
  ControlResponse,
  DeviceInfo,
  DeviceStatus,
  DiagnosticsSnapshot,
  OutputState,
  OutputTarget
} from "../domain/types.js";
import type { AdapterOptions, EcoFlowAdapter } from "./adapter.js";

const candidateTcpPorts = [80, 443, 8055, 8056];

async function probeTcpPort(host: string, port: number, timeoutMs = 750): Promise<boolean> {
  return await new Promise((resolve) => {
    const socket = net.createConnection({ host, port });
    const done = (open: boolean) => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(open);
    };

    socket.setTimeout(timeoutMs);
    socket.once("connect", () => done(true));
    socket.once("timeout", () => done(false));
    socket.once("error", () => done(false));
  });
}

export class ProbeEcoFlowAdapter implements EcoFlowAdapter {
  private readonly host: string;

  constructor(options: AdapterOptions) {
    this.host = options.host;
  }

  async getDeviceInfo(): Promise<DeviceInfo> {
    return {
      device: {
        name: "EcoFlow River 3 Plus",
        model: "river_3_plus",
        ip: this.host,
        serialNumber: null,
        firmwareVersion: null
      },
      capabilities: {
        outputs: { ac: "unknown", dc: "unknown", usb: "unknown" },
        shutdown: "unknown",
        diagnostics: "supported"
      }
    };
  }

  async getStatus(): Promise<DeviceStatus> {
    const now = new Date().toISOString();

    return {
      battery: { percent: null, state: "unknown" },
      power: { inputWatts: null, outputWatts: null, netWatts: null },
      outputs: {
        ac: { state: "unknown", watts: null },
        dc: { state: "unknown", watts: null },
        usb: { state: "unknown", watts: null }
      },
      updatedAt: now
    };
  }

  async getDiagnostics(): Promise<DiagnosticsSnapshot> {
    const observations = [];

    for (const port of candidateTcpPorts) {
      const open = await probeTcpPort(this.host, port);
      observations.push({
        timestamp: new Date().toISOString(),
        transport: `tcp:${port}`,
        direction: "inbound" as const,
        raw: "",
        decoded: { open },
        notes: open ? "TCP port accepted a connection." : "TCP port did not accept a connection."
      });
    }

    return {
      deviceIp: this.host,
      observations
    };
  }

  async setOutput(target: OutputTarget, state: Exclude<OutputState, "unknown">): Promise<ControlResponse> {
    return {
      target,
      requestedState: state,
      result: "unknown",
      observedState: "unknown",
      message: "Local control command has not been verified for this device yet."
    };
  }

  async shutdown(): Promise<ControlResponse> {
    return {
      target: "device",
      requestedState: "shutdown",
      result: "unsupported",
      observedState: "unknown",
      message: "Whole-device shutdown is not exposed by the verified local protocol."
    };
  }
}
```

- [ ] **Step 4: Update `docs/protocol-river-3-plus.md`**

Append:

```md
## Non-Destructive Probe Ports

The live probe checks TCP ports `80`, `443`, `8055`, and `8056` with short connection timeouts. These probes only attempt to connect and do not send control payloads.
```

- [ ] **Step 5: Run offline checks**

Run: `npm test`

Expected: PASS.

Run: `npm run typecheck`

Expected: PASS.

- [ ] **Step 6: Optional live diagnostics**

Run only when on the same LAN as the River 3 Plus:

```bash
npm run dev -- diagnostics --host 192.168.8.112
```

Expected: JSON diagnostics showing whether candidate TCP ports accepted a connection. If sandbox networking blocks access, rerun with approved network permissions rather than changing code.

- [ ] **Step 7: Commit**

```bash
git add ecoflow/src/local/probe-adapter.ts ecoflow/tests/probe-adapter.test.ts ecoflow/docs/protocol-river-3-plus.md
git commit -m "feat: add non-destructive local probe"
```

## Task 8: Final Verification

**Files:**
- No code changes unless checks reveal a concrete issue.

- [ ] **Step 1: Run full unit tests**

Run: `npm test`

Expected: PASS.

- [ ] **Step 2: Run typecheck**

Run: `npm run typecheck`

Expected: PASS.

- [ ] **Step 3: Run build**

Run: `npm run build`

Expected: PASS and `dist/` is generated.

- [ ] **Step 4: Smoke-test CLI with probe adapter**

Run: `node dist/cli.js status --host 192.168.8.112`

Expected: JSON with `unknown` telemetry fields, not a crash.

- [ ] **Step 5: Smoke-test HTTP server startup**

Run: `node dist/cli.js serve --host 192.168.8.112 --listen 127.0.0.1:8787`

Expected: prints `{"listening":"127.0.0.1:8787","deviceHost":"192.168.8.112"}` and keeps running. Stop it with Ctrl-C after confirming startup.

- [ ] **Step 6: Commit verification fixes if needed**

If any checks required code or doc fixes:

```bash
git add ecoflow
git commit -m "fix: stabilize ecoflow local cli api"
```

If no fixes were needed, do not create an empty commit.

## Self-Review

- Spec coverage: Tasks cover project scaffold, portable domain types, explicit command result semantics, HTTP API endpoints, JSON-first CLI, diagnostics, protocol documentation, and safety around unverified controls.
- Placeholder scan: This plan intentionally leaves live protocol mapping as a later verified discovery task because the approved design requires local-only probing first and no false success. There are no placeholder markers in the implementation steps.
- Type consistency: Domain names match across tests, fake adapter, HTTP server, CLI, and docs: `Capability`, `CommandResult`, `OutputTarget`, `DeviceStatus`, `ControlResponse`, and `/v1` endpoint shapes are consistent.
