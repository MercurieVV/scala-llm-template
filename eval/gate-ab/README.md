# eval/gate-ab — Gate A/B Evaluation Harness

## Purpose

A/B evaluation framework to measure whether a code-gate helps a headless Claude agent complete skreeep2 tasks. This is the evaluation harness described in the gate-evaluation specification in `.superpowers/sdd/2026-10-03-gate-evaluation/`.

## File Structure

```
eval/gate-ab/
├── lib.sh              # Shared shell variables and functions
├── timeout.py          # Process timeout with group killing
├── README.md           # This file
├── tests/
│   └── shell-test.sh   # Shell library and timeout tests
├── warm-cache.sh       # (forthcoming) Prebuild cache
├── prepare.sh          # (forthcoming) Prepare task environment
├── campaign.sh         # (forthcoming) Run evaluation campaign
└── report.py           # (forthcoming) Generate reports
```

## Workflow

### 1. Warm the cache (one-time)

```bash
sh eval/gate-ab/warm-cache.sh
```

Prebuild necessary components.

### 2. Prepare each task

```bash
sh eval/gate-ab/prepare.sh noise
sh eval/gate-ab/prepare.sh mixer-modes
sh eval/gate-ab/prepare.sh mcu
sh eval/gate-ab/prepare.sh note-ring
sh eval/gate-ab/prepare.sh backpressure
sh eval/gate-ab/prepare.sh scope-view
sh eval/gate-ab/prepare.sh modes
sh eval/gate-ab/prepare.sh midi-synth
```

Each task needs preparation (e.g., environment setup).

### 3. Smoke test

```bash
sh eval/gate-ab/campaign.sh --smoke
```

Verify setup with a minimal run (useful for debugging before full campaign).

### 4. Run the full campaign

```bash
sh eval/gate-ab/campaign.sh
```

Execute the A/B evaluation across all tasks and replications.

### 5. Generate reports

```bash
python3 eval/gate-ab/report.py ~/gate-eval/runs
```

Analyze results and produce summary.

## Results

Results are stored in `~/gate-eval/runs/`:

```
~/gate-eval/runs/
└── <run-id>/
    ├── <task>-g-<rep>/     # Gated arm
    ├── <task>-u-<rep>/     # Ungated arm
    └── <run-id>.json       # Metadata and summary
```

Where:
- `<run-id>` = timestamp + variant (e.g., `20261003-142315-baseline`)
- `<task>` = one of: noise, mixer-modes, mcu, note-ring, backpressure, scope-view, modes, midi-synth
- `<arm>` = g (gated) or u (ungated)
- `<rep>` = replication number 1–9

## Testing

```bash
# Test under sh
sh eval/gate-ab/tests/shell-test.sh

# Test under dash
SH=dash dash eval/gate-ab/tests/shell-test.sh
```

Expected: 8 passed, 0 failed (both shells).
