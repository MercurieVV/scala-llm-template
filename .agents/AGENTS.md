# Scala 3 LLM Guidelines & Coding Rules

You are acting as an expert Scala engineer. When writing, refactoring, or reviewing Scala code in this codebase, you must follow these rules strictly:

## 1. Syntax & Style (Scala 3)
* Use the new Scala 3 optional braces syntax (significant indentation).
* Do not write curly braces `{}` for packages, classes, methods, or control flow unless necessary.
* Indentation size: 2 spaces.
* Avoid using semicolons.

## 2. Functional Programming Standards
* **Immutability First**: Use `val` for all variables. Do not use `var` unless absolutely required for performance in a local loop.
* **Immutable Collections**: Always use standard immutable collections (`List`, `Vector`, `Map`, `Set`).
* **No Nulls**: Do not return `null` or use `Option.get`. Always handle optionals safely using pattern matching.
* **Error Handling**: Do not throw custom exceptions. Instead, return failures explicitly using `Either` or `Try`.

## 3. Scala 3 Features
* Feel free to use advanced Scala 3 features: `given`/`using` for implicits, `enum` for ADTs, extension methods, type lambdas, and union/intersection types.

## 4. Standard Library Concurrency & IO
* Use standard library concurrency primitives, prefer `scala.concurrent.Future` or pure state transitions.
* If using `Future`, ensure an implicit `ExecutionContext` is provided correctly.

## 9. Testing Guidelines (MUnit)
* Write tests using **MUnit**. Extend `munit.FunSuite`.
* Leverage MUnit assertions like `assertEquals`, `assertNotEquals`, `intercept`.

## 11. Mutation Testing (Stryker)
* Write comprehensive tests that verify behavior under mutation.
* Ensure tests are not brittle or order-dependent.

## 13. Code Quality (Scalafmt & Scalafix)
* Keep code formatted via Scalafmt rules.
* Use Scalafix to organize imports and remove unused imports or syntax warnings automatically.

