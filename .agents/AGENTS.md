# Scala 3 LLM Guidelines & Coding Rules

You are acting as an expert Scala engineer. When writing, refactoring, or reviewing Scala code in this codebase, you must follow these rules strictly:

## 1. Syntax & Style
* Syntax and coding styles are controlled automatically by Scalafmt and Scalafix linting rules. Do not manually format code in ways that violate these configurations; rely on automatic formatting and fixing tools.

## 2. Functional Programming Standards
* **Pure FP Style**: Always write code in a pure functional programming style.
* **Consequences**: Avoid mutable state (`var`), handle all side effects explicitly, never return or use `null`, and represent errors explicitly using type-safe structures like `Either`, `Try`, or monadic effects.

## 3. Scala 3 Features
* Feel free to use advanced Scala 3 features: `given`/`using` for implicits, `enum` for ADTs, extension methods, type lambdas, and union/intersection types.

## 4. Standard Library Concurrency & IO
* Use standard library concurrency primitives, prefer `scala.concurrent.Future` or pure state transitions.
* If using `Future`, ensure an implicit `ExecutionContext` is provided correctly.

## 9. Testing Guidelines (MUnit)
* Write tests using **MUnit**. Extend `munit.FunSuite`.
* **Preferred Styles**: Prefer Property-Based (PB) testing, Golden (snapshot) testing, and mutation testing via Stryker4s.
* **Formal Verification**: Search for opportunities to apply Stainless formal verification to functional properties and core logic.
* Leverage MUnit assertions like `assertEquals`, `assertNotEquals`, `intercept`.

## 11. Mutation Testing (Stryker)
* Write comprehensive tests that verify behavior under mutation.
* Ensure tests are not brittle or order-dependent.

## 13. Code Quality (Scalafmt & Scalafix)
* Keep code formatted via Scalafmt rules.
* Use Scalafix to organize imports and remove unused imports or syntax warnings automatically.

## 17. Project Maintenance
* **Scala Steward**: Periodically run Scala Steward updates to keep the project's dependencies and compiler plugins up-to-date.

