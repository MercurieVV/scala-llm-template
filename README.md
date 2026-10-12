# Scala LLM Project Guidelines (README.md)

This file contains compilation commands, project maintenance routines, and development guidelines for this workspace. AI assistants (like Claude, Antigravity, and Cursor) must consult this file before making changes.

---

## 1. Key Commands

Use the following commands to build, test, and format the project:

| Operation | Command |
| :--- | :--- |
| **Compile Project** | `mill app.compile` |
| **Run Application** | `mill app.run` |
| **Run Unit Tests** | `mill app.test` |
| **Run Mutation Tests** | `stryker4s run` |
| **Format Code** | `mill mill.scalalib.ScalafmtModule/reformat` |

---

## 2. Project Generation & Update Tool

The project is generated and updated dynamically using an interactive Scala CLI script.

*   **Setup Script:** `Setup.scala` (runs on Scala 3 + `os-lib`).
*   **Run command (local script):**
    ```bash
    scala-cli run /path/to/Setup.scala -- .
    ```
*   **Run command (arrowstep protocol mode):**
    ```bash
    scala-cli run /path/to/Setup.scala -- --agent .
    ```
    In protocol mode the script writes machine-readable arrowstep JSON on stdout only. Human progress output stays on stderr. If answers are missing, it exits with code `2` and records/reads setup answers from `.agents/answers.json`.
*   **Provide answers non-interactively:**
    ```bash
    scala-cli run /path/to/Setup.scala -- --agent --answers '{"build-tool":"mill","scala-version":"3.8.4"}' .
    ```
*   **Run command (internet remote):**
    ```bash
    scala-cli run https://raw.githubusercontent.com/MercurieVV/scala-llm-template/master/Setup.scala -- .
    ```

### Idempotent Updates:
If you run `Setup.scala` in an existing project, it automatically updates configurations without breaking your custom code:
1.  Allows selecting new features/dependencies.
2.  Updates `scalaVersion` using regex pattern matching.
3.  Injects new `ivyDeps` or compiler plugins only if they do not already exist in [build.sc](file:///Users/viktorskalinins/IdeaProjects/my/scala-llm-template/build.sc).
4.  Stages all modifications in Git (`git add .`) for user verification.

---

## 3. LLM Configuration & Shared Rules

This repository avoids local rule files (`.cursorrules`, `.agents/AGENTS.md`) to prevent codebase clutter.

*   **Master Rules File:** Located globally in the shared directory: `~/.config/llm-rules/scala-rules.md`
*   **Applying Guidelines:** When writing Scala code in this project, you must fetch and follow the rules stored in `~/.config/llm-rules/scala-rules.md` (or write code matching Scala 3 optional braces syntax, pure immutability, and explicit type-safe error handling using `Either` or `Try`).

---

## 4. Reengineering Kit

Brings a project under the kit — the `AllowedShape` scalafix rule with its build wiring, the six process skills and
the `R-n` digest — in one installed commit:

```bash
scala-cli run Setup.scala --server=false -- --agent --answers '{"kit":"yes","build-tool":"mill"}' <target-dir>
```

`build-tool` takes `mill`, `sbt` or `scala-cli`. Run it **from a local checkout of this repository**: the kit's files
are read from `kit/` at run time, so the remote one-liner above cannot install them.

The exit code is not the install's verdict: agent mode ends with `=== Setup Completed Successfully! ===` and exit 0
even when a step reported `failed`, so check the JSON's per-step `status` on stdout, not only the exit code.

The procedure that follows the install — read the ground and get the module list approved, baseline the gate,
reshape one module through the four skills, record, repeat to the exit condition — is [`kit/apply.md`](kit/apply.md).

## Agent evaluation

The gate A/B harness (`eval/gate-ab`, sh + python) was retired on 2026-10-12. Its successor, generalized to any
agent and ported to scala-cli, is `harness/` in [scala-coding-guidelines](https://github.com/MercurieVV/scala-coding-guidelines);
gate-ab's last version is at commit `98f5652` of this repository.
