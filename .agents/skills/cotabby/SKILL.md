```markdown
# cotabby Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches you the core development patterns and conventions used in the `cotabby` TypeScript codebase. You'll learn how to structure files, write imports and exports, follow commit message standards, and write tests in line with the project's established style. This guide is ideal for contributors aiming for consistency and maintainability.

## Coding Conventions

### File Naming
- Use **camelCase** for file names.
  - Example: `userProfile.ts`, `dataFetcher.test.ts`

### Import Style
- Use **relative imports** for referencing modules.
  - Example:
    ```typescript
    import { fetchData } from './dataFetcher';
    ```

### Export Style
- Use **named exports** rather than default exports.
  - Example:
    ```typescript
    // dataFetcher.ts
    export function fetchData() { ... }

    // Usage
    import { fetchData } from './dataFetcher';
    ```

### Commit Messages
- Follow **conventional commit** format.
- Use prefixes such as `ci`.
- Keep commit messages concise (average 51 characters).
  - Example:
    ```
    ci: update build pipeline for TypeScript 4.9
    ```

## Workflows

### Commit Code
**Trigger:** When making any code change  
**Command:** `/commit`

1. Make your code changes following the coding conventions.
2. Stage your changes:  
   ```
   git add .
   ```
3. Write a conventional commit message, e.g.:
   ```
   git commit -m "ci: fix deployment script"
   ```
4. Push your changes:
   ```
   git push
   ```

### Run Tests
**Trigger:** Before pushing or merging code  
**Command:** `/test`

1. Identify test files (pattern: `*.test.*`).
2. Run your test runner (framework is unknown; adjust as needed):
   ```
   # Example for Jest (if used)
   npx jest
   ```
3. Review the output and fix any failing tests.

## Testing Patterns

- Test files follow the pattern: `*.test.*` (e.g., `userProfile.test.ts`).
- The specific testing framework is not detected; use the project's preferred runner.
- Example test file structure:
  ```typescript
  // userProfile.test.ts
  import { getUserProfile } from './userProfile';

  describe('getUserProfile', () => {
    it('returns correct user data', () => {
      // test implementation
    });
  });
  ```

## Commands
| Command   | Purpose                                 |
|-----------|-----------------------------------------|
| /commit   | Guide for making conventional commits   |
| /test     | Instructions for running the test suite |
```
