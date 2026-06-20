---
title: Measurement & verification
parent: Cookbook
nav_order: 5
---

# Measurement & verification

This recipe covers the verification workflow: confirming a reconstruction is geometrically faithful to its source mesh. The key distinction that trips people up:

- **`measure_distance`** — minimum gap between two bodies. Returns ≈0 the moment bodies touch or overlap. Useful for clearance checks, useless for fidelity.
- **`measure_deviation`** — directed + symmetric surface Hausdorff. Samples tessellated surfaces in both directions and reports max/rms/mean per direction plus a single `symmetricHausdorff` worst-case. This is the right tool for certification.

Also covered: wall-thickness and assembly clearance checks.

See the tool reference for full parameter docs: [`measure_distance`](../../reference/introspection.md#measure_distance) · [`measure_deviation`](../../reference/introspection.md#measure_deviation) · [`check_thickness`](../../reference/engineering.md#check_thickness) · [`analyze_clearance`](../../reference/engineering.md#analyze_clearance).

---

## Recipe: certify a reconstruction against its source mesh

A common pattern: you have a raw scan or imported mesh as the reference, a reconstruction (a B-rep solid built to match it), and you need to prove the reconstruction is within tolerance.

### Step 1 — load the source mesh

The source mesh may not be a watertight B-rep, so pass `allowInvalid: true` to let it load as a loose-face shell.

```json
// import_file arguments
{
  "inputPath": "/Users/me/scans/bracket_scan.stl",
  "bodyId": "source_mesh",
  "allowInvalid": true
}
```

```json
// example result
{
  "bodyId": "source_mesh",
  "name": "bracket_scan",
  "faceCount": 3842,
  "valid": false,
  "message": "Loaded with allowInvalid=true (open shell)"
}
```

`allowInvalid: true` is equally available on [`read_brep`](../../reference/io.md#read_brep) for in-progress BREP reconstructions.

### Step 2 — load the reconstruction

If the reconstruction is a BREP produced by `execute_script` it is already in the scene. If it lives on disk, import it:

```json
// read_brep arguments
{
  "path": "/Users/me/reconstructions/bracket_v3.brep",
  "bodyId": "recon",
  "allowInvalid": true
}
```

```json
// example result
{
  "bodyId": "recon",
  "faceCount": 18,
  "valid": true
}
```

### Step 3 — measure surface deviation

Call `measure_deviation` with the reconstruction as `fromBodyId` and the scan as `toBodyId`.

- **`fromToTo`** — reconstruction surface vs. scan. High values here = the reconstruction extends beyond the reference (over-extension).
- **`toToFrom`** — scan surface vs. reconstruction. High values here = parts of the scan the reconstruction does not cover (under-coverage).
- **`symmetricHausdorff`** — `max(fromToTo.max, toToFrom.max)`: the single worst-case in either direction. Compare this against your tolerance spec.

<script type="module" src="https://cdn.jsdelivr.net/npm/@google/model-viewer/dist/model-viewer.min.js"></script>

<model-viewer src="models/measurement.glb" poster="images/measurement.png" alt="Source mesh (grey) and reconstruction (blue)" camera-controls auto-rotate environment-image="neutral" exposure="1.1" shadow-intensity="1" style="width:100%;max-width:480px;height:360px;background:#eef1f5;border-radius:6px"></model-viewer>

<sub>🖱️ Drag to orbit · scroll to zoom · auto-rotating. Grey = source mesh, blue = reconstruction. (Model exported via `export_scene` → glTF.)</sub>

```json
// measure_deviation arguments
{
  "fromBodyId": "recon",
  "toBodyId": "source_mesh",
  "deflection": 0.1
}
```

```json
// example result
{
  "fromToTo": {
    "max": 0.18,
    "rms": 0.06,
    "mean": 0.04,
    "worstPoint": [42.1, 7.3, 0.0]
  },
  "toToFrom": {
    "max": 0.22,
    "rms": 0.08,
    "mean": 0.05,
    "worstPoint": [41.9, 7.1, 0.0]
  },
  "symmetricHausdorff": 0.22
}
```

`symmetricHausdorff: 0.22` mm against a 0.25 mm tolerance spec = pass. The `worstPoint` coordinates tell you exactly where to look in the viewport.

`deflection` is in model units; the default (0.5% of the from-body bbox diagonal) is usually a reasonable starting point. Reduce it to tighten the bound at higher compute cost. `maxSamples` (default 20000) caps the surface samples per direction.

### Step 4 — why not just use `measure_distance`?

For completeness, here is what `measure_distance` returns on these same two bodies:

```json
// measure_distance arguments
{
  "fromBodyId": "recon",
  "toBodyId": "source_mesh"
}
```

```json
// example result
{
  "distance": 0.0
}
```

The reconstruction and scan overlap, so the minimum gap is zero — no information about how well the surfaces match. Never use `measure_distance` for fidelity certification.

---

## Wall-thickness check

After confirming fidelity, check the reconstruction is manufacturable. `check_thickness` UV-grid samples each face and casts an inward ray to the opposite wall.

```json
// check_thickness arguments
{
  "bodyId": "recon",
  "minAcceptable": 1.5,
  "samplingDensity": "fine"
}
```

```json
// example result
{
  "min": 1.1,
  "max": 4.8,
  "mean": 2.9,
  "thinRegions": [
    { "faceIndex": 3, "u": 0.25, "v": 0.5, "thickness": 1.1 }
  ]
}
```

`min: 1.1` is below the 1.5 mm floor. The single flagged region at `faceIndex: 3` is where to focus a design fix. Use `samplingDensity: "coarse"` for a quick scan on large bodies.

Full reference: [`check_thickness`](../../reference/engineering.md#check_thickness).

---

## Assembly clearance check

For multi-body scenes, `analyze_clearance` runs all pairwise gap checks in one call. A `minDistance` of 0 means touching; negative means interference.

```json
// analyze_clearance arguments
{
  "bodyIds": ["recon", "mating_part", "fastener"],
  "computeContacts": true
}
```

```json
// example result
{
  "pairs": [
    {
      "bodyA": "recon",
      "bodyB": "mating_part",
      "minDistance": 0.08,
      "contacts": [
        { "pointA": [20.0, 5.0, 0.0], "pointB": [20.08, 5.0, 0.0] }
      ]
    },
    { "bodyA": "recon",       "bodyB": "fastener",    "minDistance": 0.0  },
    { "bodyA": "mating_part", "bodyB": "fastener",    "minDistance": 1.4  }
  ]
}
```

`recon` and `fastener` are exactly touching (`minDistance: 0`); `recon` and `mating_part` have a 0.08 mm gap. For a detailed two-body gap with up to 32 contact pairs, use [`measure_distance`](../../reference/introspection.md#measure_distance) directly.

Full reference: [`analyze_clearance`](../../reference/engineering.md#analyze_clearance).
