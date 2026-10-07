/**
 * Unit tests for the get_api_reference(category="mcp_tools") catalog —
 * verifies that every tool registered in src/index.ts shows up with a
 * description and an introspectable JSON Schema for its input.
 *
 * Pure import-time check; no occtkit, no scene state.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";

let server;
let catalog;

before(async () => {
  const { createServer } = await import("../../dist/index.js");
  server = createServer();
  const tool = server._registeredTools.get_api_reference;
  const result = await tool.handler({ category: "mcp_tools" }, {});
  catalog = JSON.parse(result.content[0].text);
});

describe("mcp_tools catalog", () => {
  it("enumerates every registered tool", () => {
    const registeredCount = Object.keys(server._registeredTools).filter(
      (k) => server._registeredTools[k].enabled
    ).length;
    assert.equal(catalog.count, registeredCount);
    assert.ok(catalog.count >= 3000, `expected >= 30 tools, got ${catalog.count}`);
  });

  it("includes the core tools", () => {
    const names = catalog.tools.map((t) => t.name);
    for (const expected of [
      "execute_script",
      "get_scene",
      "get_api_reference",
      "compute_metrics",
      "transform_body",
      "boolean_op",
      "render_preview",
      "simplify_mesh",
      "inspect_assembly",
    ]) {
      assert.ok(names.includes(expected), `missing tool: ${expected}`);
    }
  });

  it("every entry has a name, description, and inputSchema", () => {
    for (const t of catalog.tools) {
      assert.ok(typeof t.name === "string" && t.name.length > 0);
      assert.ok(typeof t.description === "string" && t.description.length > 0, `tool ${t.name} missing description`);
      assert.ok(typeof t.inputSchema === "object" && t.inputSchema !== null);
    }
  });

  it("input schemas have the JSON Schema 'type' marker", () => {
    // Empty-input tools may have minimal schema; richer ones should advertise type
    const xform = catalog.tools.find((t) => t.name === "transform_body");
    assert.equal(xform.inputSchema.type, "object");
    assert.ok(xform.inputSchema.properties.bodyId);
    assert.ok(xform.inputSchema.required.includes("bodyId"));
  });

  it("tools are sorted alphabetically", () => {
    const names = catalog.tools.map((t) => t.name);
    const sorted = [...names].sort();
    assert.deepEqual(names, sorted);
  });
});
