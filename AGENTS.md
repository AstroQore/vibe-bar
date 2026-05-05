# Vibe Bar Agent Maintenance Manual

This file is the operating manual for any agent maintaining this repository.
Follow it for every change unless the user explicitly gives a different
instruction in the current task.

## Mandatory Workflow

1. Read the relevant source before editing.
2. Keep changes scoped to the user's request.
3. Run the relevant validation for the touched area.
4. After every maintenance change, build the macOS app bundle into `.build`:

   ```bash
   ./Scripts/build_app.sh
   ```

   The expected artifact is:

   ```text
   .build/Vibe Bar.app
   ```

5. Commit every modification. Do not leave local edits uncommitted after a
   maintenance task is complete.
6. Push every committed change to the private GitHub repository:

   ```bash
   git push origin HEAD
   ```

## Review-Only Tasks

If the user explicitly asks for read-only review or investigation and no files
are changed, do not create a commit and do not push. Report findings only.

## Build Notes

- `swift test` is useful for core parser and utility changes.
- `./Scripts/build_app.sh` is still required after maintenance, even if tests
  pass, because this project ships as a menu-bar `.app` bundle.
- The build script creates a release app bundle by default and ad-hoc signs it.

## Git Notes

- Use clear, narrow commit messages.
- Check `git status --short` before committing.
- Do not revert user changes unless the user explicitly asks.
- The canonical remote is the private GitHub repository at
  `https://github.com/AstroQore/vibe-bar.git`.
