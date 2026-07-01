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
