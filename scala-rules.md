# Scala 3 LLM Guidelines & Coding Rules

You are acting as an expert Scala engineer. When writing, refactoring, or reviewing Scala code in this codebase, you must follow these rules strictly:

## 1. Syntax & Style
* Syntax and coding styles are controlled automatically by Scalafmt and Scalafix linting rules.

## 2. Functional Programming Standards
* **Pure FP Style**: Always write code in a pure functional programming style.
* **Thought patterns**: Math based. Think on project as objects and relationships (category theory), ADTs. Use abstractions, layers of abstractions (from business to technical), parallel/sequential morphisms, programming on types

## 3. Scala 3 Features
* Feel free to use advanced Scala 3 features: `given`/`using` for implicits, `enum` for ADTs, extension methods, typeclasses, derivations, type lambdas, and union/intersection types.

## 4. Standard Library Concurrency & IO
* Use standard library concurrency primitives, prefer `scala.concurrent.Future` or pure state transitions.
* If using `Future`, ensure an implicit `ExecutionContext` is provided correctly.

## 9. Testing Guidelines (MUnit)
* Try/think to use most advanced testing approaches: PB, mutation, concolic...
* Write basic tests using **MUnit**. Extend `munit.FunSuite`.
* **Preferred Styles**: Prefer Property-Based (PB) testing, Golden (snapshot) testing, and mutation testing via Stryker4s.
* **Formal Verification**: Search for opportunities to apply Stainless formal verification to functional properties and core logic.
* Leverage MUnit assertions like `assertEquals`, `assertNotEquals`, `intercept`.

## 11. Mutation Testing (Stryker)
* Write comprehensive tests that verify behavior under mutation.
* Ensure tests are not brittle or order-dependent.

## 13. Code Quality (Scalafmt, Scalafix, Wartremover)
* Keep code formatted via Scalafmt rules.
* Use Scalafix to organize imports and remove unused imports or syntax warnings automatically.
* **Wartremover**: Pure functional programming safety is checked via Wartremover's Unsafe warts. Ensure your code does not trigger any unsafe warts (such as `Null`, `Var`, `Throw`, `Return`, `IsInstanceOf`, `AsInstanceOf`).

## 17. Project Maintenance
* **Scala Steward**: Periodically run Scala Steward updates to keep the project's dependencies and compiler plugins up-to-date.

## 18. Typelevel stack
* If typelevel have something what have commonly used analog in stdlib or java (for example Chain/List) - give a bit more preference to typelevel variant.
* Probably need use not only cats and cats effects, but also helper libs - kittens, alleyway cats, https://github.com/MercurieVV/minuscles/