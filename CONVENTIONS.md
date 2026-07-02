# Scala LLM Project Guidelines (CONVENTIONS.md)

This file contains compilation commands, project maintenance routines, and development guidelines for this workspace. AI assistants (like Claude, Antigravity, and Cursor) must consult this file before making changes.

---

## 1. Key Commands

Use the following commands to build, test, and format the project:

| Operation | Command |
| :--- | :--- |
| **Compile Project** | `scala-cli compile .` |
| **Run Application** | `scala-cli run .` |
| **Run Unit Tests** | `scala-cli test .` |
| **Run Mutation Tests** | `stryker4s run` |
| **Format Code** | `scala-cli fmt .` |
| **Lint Code** | `scala-cli --power scalafix .` |

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
    scala-cli run https://raw.githubusercontent.com/your-username/my-scala-rules/main/Setup.scala -- .
    ```

### Idempotent Updates:
If you run `Setup.scala` in an existing project, it automatically updates configurations without breaking your custom code:
1.  Allows selecting new features/dependencies.
2.  Updates `scalaVersion` using regex pattern matching.
3.  Injects new `ivyDeps` or compiler plugins only if they do not already exist in [build.sc](file:///Users/viktorskalinins/IdeaProjects/my/scala-llm-template/build.sc).
4.  Stages all modifications in Git (`git add .`) for user verification.

---

## 3. LLM Configuration & Workspace Rules

This project uses local LLM instructions and workspace rules tailored to the selected features:
*   **Antigravity/Gemini Rules:** [.agents/AGENTS.md](.agents/AGENTS.md)
*   **Cursor Rules:** [.cursorrules](.cursorrules)
*   **Global/Generic Rules:** [scala-rules.md](scala-rules.md)

All rules and guidelines are automatically kept in sync by the `Setup.scala` tool when features are added or removed.
