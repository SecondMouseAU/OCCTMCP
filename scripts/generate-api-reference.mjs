#!/usr/bin/env node
// Generates src/api-reference.ts from OCCTSwift sources.
// Walks ~/Projects/OCCTSwift/Sources/OCCTSwift/*.swift, extracts public func
// declarations, groups them by editorial categories, and emits a TS file.

import { readdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const SOURCES_DIR = join(homedir(), "Projects/OCCTSwift/Sources/OCCTSwift");
const OUTPUT_PATH = join(
  fileURLToPath(new URL(".", import.meta.url)),
  "..",
  "src",
  "api-reference.ts"
);

// ── Editorial: category → which (type, MARK-pattern) combinations to include ──
// markRx is matched against the trimmed MARK title (without leading "- " or
// trailing "(vX.Y.Z)").  A `null` markRx means "any MARK section" for that
// type.  `nameRx` (optional) additionally selects by function name — useful
// when OCCTSwift bundles unrelated additions under a single versioned MARK
// like "v0.51.0: BRepLib_MakeSolid, GC transforms, ChFi2d_AnaFilletAlgo".
const CATEGORIES = [
  {
    key: "primitives",
    title: "Primitives (Shape static factories)",
    rules: [{ type: "Shape", markRx: /^Primitive/ }],
    notes: "All return optional Shape. Dimensions in model units (typically mm).",
  },
  {
    key: "sweeps",
    title: "Sweeps",
    rules: [
      { type: "Shape", markRx: /^Sweep|Pipe|Variable-Section Sweep/ },
    ],
    notes:
      "Profile is a Wire (2D cross-section), path/spine is a Wire (3D path).",
  },
  {
    key: "booleans",
    title: "Boolean Operations",
    rules: [{ type: "Shape", markRx: /^Boolean|^Operators$/ }],
    notes: "Operators: + (union), - (subtract), & (intersect).",
  },
  {
    key: "modifications",
    title: "Modifications",
    rules: [
      {
        type: "Shape",
        markRx:
          /^Modifications|^Selective Fillet|^Draft Angle|^Defeaturing|^Variable Radius Fillet|^Multi-Edge Blend|^Surface Filling|^Plate Surfaces|^Advanced Plate Surfaces|^Conversion/,
      },
    ],
    notes:
      "Edge/face indices: use shape.edges().count / shape.faces().count to find counts.",
  },
  {
    key: "transforms",
    title: "Transforms",
    rules: [
      { type: "Shape", markRx: /^Transformation/ },
      // Catch transforms hidden in versioned grab-bag MARKs.
      {
        type: "Shape",
        nameRx: /^(translated|rotated|scaled|mirrored|scaledGeometry|mirroredAbout|scaledAbout)/,
      },
    ],
    notes: "All return new Shape (immutable transforms).",
  },
  {
    key: "wires",
    title: "Wire Construction",
    rules: [
      {
        type: "Wire",
        markRx:
          /Profile|3D Paths|NURBS|Wire From|Wire Composition|Curve Interpolation|Convenience|2D Fillet|2D Chamfer|Helix|Wire Explorer|Wire Edge Access|Wire Topology|CAM/,
      },
    ],
    notes:
      "Wires can be used as profiles for sweeps, or added to ScriptContext directly (shown as wireframe).",
  },
  {
    key: "curves2d",
    title: "2D Curves (Curve2D)",
    rules: [{ type: "Curve2D", markRx: null }],
    notes: "GCC solver entries provide tangent/constraint curve construction.",
  },
  {
    key: "curves3d",
    title: "3D Curves (Curve3D)",
    rules: [{ type: "Curve3D", markRx: null }],
    notes: "",
  },
  {
    key: "surfaces",
    title: "Surfaces (Surface)",
    rules: [{ type: "Surface", markRx: null }],
    notes:
      "Infinite surfaces must be trimmed before converting to BSpline.",
  },
  {
    key: "analysis",
    title: "Analysis & Measurement",
    rules: [
      {
        type: "Shape",
        markRx:
          /^Validation|^Bounds|^Shape Analysis|Measurement|Sub-Shape|Shape Type/,
      },
      { type: "Edge", markRx: null },
      { type: "Face", markRx: null },
    ],
    notes:
      "Shape properties (volume, surfaceArea, centerOfMass, bounds, isValid) are accessed as Swift computed properties.",
  },
  {
    key: "import_export",
    title: "Import/Export",
    rules: [
      { type: "Shape", markRx: /^Import|STL Import|STEP|IGES|BREP Import|OBJ Import|Robust STEP/ },
      { type: "Exporter", markRx: null },
    ],
    notes:
      "ScriptContext handles BREP + STEP export automatically. Just add shapes and call ctx.emit().",
  },
  {
    key: "topology_graph",
    // OCCTSwift v1.15.0 (#333) renamed the type to BRepGraph, keeping
    // TopologyGraph only as a deprecated typealias. A typealias declares no
    // methods, so matching on the old name silently emptied this whole
    // category (70+ decls) out of the generated reference; match the real
    // type name. The `key` stays `topology_graph` because it is the wire
    // value of get_api_reference's `category` argument.
    title: "BRepGraph Queries",
    rules: [
      {
        type: "BRepGraph",
        markRx:
          /^Topology Counts|^Geometry Counts|^Face Queries|^Edge Queries|^Vertex Queries|^Wire Queries|^CoEdge Queries|^Shell Queries|^Solid Queries|^Active Geometry|^Statistics|^Root Nodes|^Explorers|^Node Status|^Validate$|^Compact$|^Deduplicate$|^Shape Reconstruction|^Vertex Geometry|^Edge Geometry|^Face Geometry|^SameDomain|^Reference|^Product|^Edge Definition|^Face Definition|^Edge Additional|^Face Additional|^Shell Additional|^Solid Additional|^Compound\/CompSolid|^CompSolid Count|^Poly Counts|^History/,
      },
    ],
    notes:
      "Build a graph-based B-Rep topology from any Shape for fast adjacency queries, analysis, ML export, and geometry sampling. Construct with BRepGraph(shape:parallel:).",
  },
  {
    key: "topology_graph_builder",
    title: "BRepGraph Builder (Mutations)",
    rules: [
      {
        type: "BRepGraph",
        markRx: /^Builder|Copy and Transform/,
      },
    ],
    notes:
      "Mutate topology programmatically. Use beginDeferredInvalidation/endDeferredInvalidation around batch mutations.",
  },
];

// ── Swift parser ────────────────────────────────────────────────────────────

/**
 * Parse a Swift source file and return an array of declarations:
 *   { type, mark, name, signature, file, line }
 *
 * `signature` is the full "name(params) -> ReturnType" form, with multi-line
 * declarations collapsed and parameter defaults preserved.
 */
function parseSwiftFile(source, file) {
  const lines = source.split("\n");
  const out = [];

  // Track scope by scanning column-0 type-opening lines.
  // Every `(public )?(extension|class|struct|enum|final class) Name` at the
  // start of a line opens a new scope that lasts until the next such line.
  const typeOpens = []; // [{ line, type }]
  const typeRx =
    /^(?:public\s+)?(?:final\s+)?(?:extension|class|struct|enum)\s+(\w+)/;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(typeRx);
    if (m) typeOpens.push({ line: i, type: m[1] });
  }

  function typeAt(lineIdx) {
    let cur = null;
    for (const t of typeOpens) {
      if (t.line <= lineIdx) cur = t.type;
      else break;
    }
    return cur;
  }

  // Collect MARK sections with their start lines.
  const marks = []; // [{ line, mark }]
  const markRx = /\/\/\s*MARK:\s*-?\s*(.+?)\s*$/;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(markRx);
    if (m) marks.push({ line: i, mark: m[1].replace(/\s*\(v[\d.]+\)\s*$/, "") });
  }

  function markAt(lineIdx) {
    let cur = null;
    for (const mk of marks) {
      if (mk.line <= lineIdx) cur = mk.mark;
      else break;
    }
    return cur;
  }

  // Find `public func` / `public static func` declarations.
  // Match both word names (foo) and operator names (+, -, &, ==, ...).
  const funcStartRx = /^\s+public\s+(?:static\s+)?func\s+(\S+?)\s*[(<]/;
  // A `@available(*, deprecated` (possibly multi-line) right before a func
  // means the next func is a back-compat shim — drop it so the LLM only
  // sees the canonical signature.
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(funcStartRx);
    if (!m) continue;
    const name = m[1];

    // Look back past doc-comment / attribute lines for a deprecation marker.
    let deprecated = false;
    for (let k = i - 1; k >= 0 && k >= i - 6; k--) {
      const prev = lines[k];
      if (/@available\s*\(\s*\*\s*,\s*deprecated/.test(prev)) {
        deprecated = true;
        break;
      }
      // Stop scanning back at a blank line or a line that's clearly not an
      // attribute / doc-comment / attribute continuation.
      const trimmed = prev.trim();
      if (trimmed === "") break;
      if (
        !trimmed.startsWith("@") &&
        !trimmed.startsWith("///") &&
        !trimmed.startsWith("//") &&
        !/^[)"\w].*[,)]\s*$/.test(trimmed)
      ) {
        // Probably the previous declaration's body brace.
        break;
      }
    }
    if (deprecated) continue;

    // Accumulate the declaration until we hit '{' or end of decl.
    // We collect up to the first `{` at depth 0 of `()<>`.
    let buf = "";
    let parenDepth = 0;
    let angleDepth = 0;
    let foundOpenParen = false;
    let foundCloseParen = false;
    let done = false;
    let j = i;
    while (j < lines.length && !done) {
      const text = j === i
        ? lines[j].slice(lines[j].indexOf("func "))
        : lines[j];
      for (let k = 0; k < text.length; k++) {
        const c = text[k];
        if (c === "(") {
          parenDepth++;
          foundOpenParen = true;
        } else if (c === ")") {
          parenDepth--;
          if (parenDepth === 0 && foundOpenParen) foundCloseParen = true;
        } else if (c === "<") {
          // Only treat as angle bracket if we're not yet past the param list
          if (!foundCloseParen) angleDepth++;
        } else if (c === ">") {
          if (angleDepth > 0) angleDepth--;
        } else if (c === "{" && parenDepth === 0 && foundCloseParen) {
          done = true;
          break;
        }
        buf += c;
      }
      if (!done) buf += " ";
      j++;
    }

    // Normalize whitespace.
    let sig = buf
      .replace(/\s+/g, " ")
      .replace(/\(\s+/g, "(")
      .replace(/\s+\)/g, ")")
      .replace(/\s*,\s*/g, ", ")
      .trim();

    // Strip trailing "{" if present, and any trailing "where ..." we don't
    // want to keep verbose. Keep `throws` / `async` / `rethrows` / `where`.
    sig = sig.replace(/\s*\{\s*$/, "").trim();

    // Drop the leading "func " prefix — we'll prepend type ourselves.
    sig = sig.replace(/^func\s+/, "");

    out.push({
      type: typeAt(i),
      mark: markAt(i),
      name,
      signature: sig,
      file: basename(file),
      line: i + 1,
    });
  }

  // Find `public var NAME: TYPE` (and `public static var`) declarations.
  // We only capture explicitly-typed declarations so the signature is useful.
  // Computed properties (`public var x: Type { ... }`) are still captured — we
  // stop at the `{` or end-of-line and record the inferred type from the colon.
  const varRx = /^\s+public\s+(?:static\s+)?var\s+(\w+)\s*:\s*([^{=]+?)(?:\s*\{|$)/;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(varRx);
    if (!m) continue;

    // Skip deprecated shims (same back-scan as funcs).
    let deprecated = false;
    for (let k = i - 1; k >= 0 && k >= i - 6; k--) {
      const prev = lines[k];
      if (/@available\s*\(\s*\*\s*,\s*deprecated/.test(prev)) {
        deprecated = true;
        break;
      }
      const trimmed = prev.trim();
      if (trimmed === "") break;
      if (
        !trimmed.startsWith("@") &&
        !trimmed.startsWith("///") &&
        !trimmed.startsWith("//")
      ) {
        break;
      }
    }
    if (deprecated) continue;

    const name = m[1];
    const typeStr = m[2].trim();
    // Skip private-ish patterns: underscore prefix (conventionally internal).
    if (name.startsWith("_")) continue;

    out.push({
      type: typeAt(i),
      mark: markAt(i),
      name,
      // Use an arrow form so vars read like getter signatures in the output.
      signature: `${name} -> ${typeStr}`,
      kind: "var",
      file: basename(file),
      line: i + 1,
    });
  }

  return out;
}

// ── Generator ───────────────────────────────────────────────────────────────

async function main() {
  const files = (await readdir(SOURCES_DIR))
    .filter((f) => f.endsWith(".swift"))
    .sort();

  const all = [];
  for (const f of files) {
    const path = join(SOURCES_DIR, f);
    const source = await readFile(path, "utf-8");
    all.push(...parseSwiftFile(source, path));
  }

  console.error(
    `parsed ${all.length} declarations from ${files.length} files`
  );

  // Bucket declarations by category.
  const buckets = new Map(); // key → [{type, mark, signature, file, line}]
  const matched = new Set(); // index of matched declarations

  for (const cat of CATEGORIES) {
    const bucket = [];
    for (let idx = 0; idx < all.length; idx++) {
      const decl = all[idx];
      for (const rule of cat.rules) {
        if (decl.type !== rule.type) continue;
        if (rule.markRx && !(decl.mark && rule.markRx.test(decl.mark))) continue;
        if (rule.nameRx && !rule.nameRx.test(decl.name)) continue;
        bucket.push(decl);
        matched.add(idx);
        break;
      }
    }
    buckets.set(cat.key, bucket);
  }

  // Report unmatched declarations grouped by (type, mark) so we know about drift.
  const unmatchedByType = new Map();
  for (let idx = 0; idx < all.length; idx++) {
    if (matched.has(idx)) continue;
    const decl = all[idx];
    const key = `${decl.type ?? "?"} :: ${decl.mark ?? "(no MARK)"}`;
    if (!unmatchedByType.has(key)) unmatchedByType.set(key, 0);
    unmatchedByType.set(key, unmatchedByType.get(key) + 1);
  }
  if (unmatchedByType.size > 0) {
    console.error("\nUNMATCHED declarations (consider extending CATEGORIES):");
    const entries = [...unmatchedByType.entries()].sort((a, b) => b[1] - a[1]);
    for (const [k, n] of entries) console.error(`  ${n.toString().padStart(4)}  ${k}`);
  }

  // Render each category.
  function renderCategory(cat) {
    const decls = buckets.get(cat.key) ?? [];
    if (decls.length === 0) {
      return `# ${cat.title}\n(no entries)`;
    }
    // Group by MARK to preserve sub-headers.
    const byMark = new Map();
    for (const d of decls) {
      const mark = d.mark ?? "(uncategorized)";
      if (!byMark.has(mark)) byMark.set(mark, []);
      byMark.get(mark).push(d);
    }
    const lines = [`# ${cat.title}`];
    for (const [mark, ds] of byMark) {
      lines.push(`\n## ${mark}`);
      for (const d of ds) {
        lines.push(`${d.type}.${d.signature}`);
      }
    }
    if (cat.notes) {
      lines.push("");
      lines.push(cat.notes);
    }
    return lines.join("\n");
  }

  // Build output TS.
  const header = `/**
 * Auto-generated by scripts/generate-api-reference.mjs.
 * Do not edit by hand — re-run \`npm run generate:api\` after changes to
 * OCCTSwift to refresh signatures. The generator parses
 * ~/Projects/OCCTSwift/Sources/OCCTSwift/*.swift directly.
 */
export const API_REFERENCE: Record<string, string> = {`;

  const body = CATEGORIES.map((cat) => {
    const text = renderCategory(cat);
    // Use a template literal; escape backticks and \${ in the body.
    const escaped = text.replace(/\\/g, "\\\\").replace(/`/g, "\\`").replace(/\$\{/g, "\\${");
    return `  ${cat.key}: \`${escaped}\`,`;
  }).join("\n\n");

  const footer = `

  all: "", // built below
};

API_REFERENCE.all = Object.entries(API_REFERENCE)
  .filter(([k]) => k !== "all")
  .map(([, v]) => v)
  .join("\\n\\n---\\n\\n");
`;

  const out = `${header}\n${body}\n${footer}`;
  await writeFile(OUTPUT_PATH, out, "utf-8");

  console.error(
    `\nwrote ${OUTPUT_PATH} (${out.length} bytes, ${
      [...buckets.values()].reduce((a, b) => a + b.length, 0)
    } categorised decls)`
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
