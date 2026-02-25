# Coding Guidelines

## Functions, docstrings, and the spec
Every function should have a docstring describing what the function is aspiring to do, where it comes from in the spec, and the version of the spec it was 1. implemented with, and also the version of any subsequent edits or renamining to the function need to list the versino of the spec that triggered their update.

Any time a function is removed, the git commit message must include a list of deleted functions (or a filename is acceptable if the full file was deleted) and what in the spec change triggered that.

## TypeScript Types

### ADT-Style Types (Algebraic Data Types)

All types should follow ADT-style patterns using discriminated unions with a `tag` field:

```typescript
// Good: ADT-style with tag discriminator
type Result<T> =
  | { tag: 'success'; value: T }
  | { tag: 'error'; error: string }

type LoadState<T> =
  | { tag: 'idle' }
  | { tag: 'loading' }
  | { tag: 'loaded'; data: T }
  | { tag: 'error'; error: string }

// Usage with exhaustive matching
function handleResult<T>(result: Result<T>): void {
  switch (result.tag) {
    case 'success':
      console.log(result.value)
      break
    case 'error':
      console.error(result.error)
      break
  }
}
```

```typescript
// Avoid: Plain union types without discriminator
type Result<T> = T | Error  // Hard to distinguish at runtime

// Avoid: String literal unions for complex state
type Status = 'idle' | 'loading' | 'loaded' | 'error'  // No associated data
```

Benefits:
- Exhaustive pattern matching with TypeScript's type narrowing
- Self-documenting code - the tag describes what variant you have
- Easy to extend with new variants
- Runtime-checkable without instanceof or type guards
