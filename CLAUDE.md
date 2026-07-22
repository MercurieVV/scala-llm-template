# Scala LLM Project Guidelines (CLAUDE.md)

This file contains compilation commands, project maintenance routines, and development guidelines for this workspace. AI assistants (like Claude, Antigravity, and Cursor) must consult this file before making changes.

---

## 1. Key Commands

Use the following commands to build, test, and format the project:

| Operation | Command |
| :--- | :--- |
| **Compile Project** | `scala-cli compile .` |
| **Run Application** | `scala-cli run .` |
| **Run Unit Tests** | `scala-cli test .` |
| **Run Scala Steward** | `scala-steward` |
| **Local Dependency Update** | `scala-cli run scripts/dependency-update.scala -- [target-dir]` |
| **Run Mutation Tests** | `stryker4s run` |
| **Format Code** | `scala-cli fmt .` |
| **Lint Code** | `scala-cli --power scalafix .` |
| **Compile Docs (Mdoc)** | `scala-cli run mdoc-docs/src/main/scala/DocsMain.scala -- .` |
| **Start Git Worktree** | `scala-cli run scripts/worktree-start.scala -- <branch>` |
| **Finish Git Worktree** | `scala-cli run scripts/worktree-finish.scala` |

---

## 2. Project Generation & Update Tool

The project is generated and updated dynamically using an interactive Scala CLI script.

*   **Setup Script:** `Setup.scala` (runs on Scala 3 + `os-lib`).
*   **Run command (local script):**
    ```bash
    scala-cli run /path/to/Setup.scala -- .
    ```
*   **Run command (internet remote):**
    ```bash
    scala-cli run https://raw.githubusercontent.com/MercurieVV/scala-llm-template/master/Setup.scala -- .
    ```


---

## 3. LLM Configuration & Workspace Rules

This project uses local LLM instructions and workspace rules tailored to the selected features:
*   **Antigravity/Gemini Rules:** [.agents/AGENTS.md](.agents/AGENTS.md)
*   **Cursor Rules:** [.cursorrules](.cursorrules)
*   **Global/Generic Rules:** [scala-rules.md](scala-rules.md)
*   **ScalaSemantic MCP configuration:** [.agents/mcp_config.json](.agents/mcp_config.json) (runs compile-aware AI search).
*   **Mdoc documentation:** [docs/index.md](docs/index.md) (source markdown compiled by mdoc).
*   **Start Worktree Script:** [scripts/worktree-start.scala](scripts/worktree-start.scala) (creates isolated task branch + worktree).
*   **Finish Worktree Script:** [scripts/worktree-finish.scala](scripts/worktree-finish.scala) (commits, merges, and cleans up the worktree).

All rules and guidelines are automatically kept in sync by the `Setup.scala` tool when features are added or removed.
