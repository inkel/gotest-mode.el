# gotest-mode.el

An Emacs minor mode for running Go tests and benchmarks via a [Transient](https://github.com/magit/transient) menu.

## Project Structure

Single-file package: `gotest-mode.el`. No build system, no test suite, no Makefile.

## Architecture

The package is organized into these layers:

- **Compilation mode** (`gotest-compilation-mode`): derives from `compilation-mode`, adds regexp patterns for Go test failure lines and panic stack frames, with a custom file locator (`gotest--find-file`) that searches recursively from the module root.
- **Core runner** (`gotest--run`): builds and executes the `go test` command via `compilation-start`, runs from the module root (`go.mod` directory), hides the output buffer on success and shows elapsed time in the minibuffer.
- **Transient UI**: two prefixes — `gotest-dispatch` (main menu, `C-c t`) and `gotest-benchmark-dispatch` (benchmark sub-menu). Infix arguments defined with `transient-define-argument`.
- **Overlays**: clickable `mouse-1` overlays on every `func Test*` / `func Benchmark*` declaration line. Refreshed via a 0.5s idle timer after buffer changes.
- **Minor mode** (`gotest-mode`): activates the keymap and overlays; `gotest-maybe-enable` auto-enables it for `go-mode` buffers.

## Key Conventions

- **Main keybinding**: `C-c t` opens the Transient menu; `C-u C-c t` runs the function at point directly.
- **Package flag**: `-package=` is a pseudo-flag handled internally — stripped from args before invoking `go test` and used as the package pattern. It is NOT a real `go test` flag.
- **Benchmark listing quirk**: `go test -list` only lists benchmarks when `-bench=.` is also passed. `gotest--list-functions` adds this automatically when the prefix is `"Benchmark"`.
- **Benchmark run**: benchmarks always get `-run=^$` prepended (via `extra-flags`) to suppress tests. Any user-supplied `-run=` overrides this because `extra-flags` comes first.
- **Module root**: all `go` commands run with `default-directory` set to the `go.mod` directory, found via `locate-dominating-file`.

## Emacs Lisp Style

- `lexical-binding: t` is required.
- Public API symbols are prefixed `gotest-`; private helpers use `gotest--` (double dash).
- Transient infixes follow the naming convention `gotest:--flagname`.
- All interactive commands that should be autoloaded carry `;;;###autoload`.
- No external dependencies beyond `transient`, `compile`, and `cl-lib` (all standard or widely available).

## Allowed Tools

- `Bash(emacs --version)`
- `Bash(find ~/.emacs.d/elpa -name magit*.el)`
- `Bash(find ~/.emacs.d/elpa -name go-*.el -o -name *golang*.el)`

## Development Notes

- There are no automated tests. Validate changes by loading the file in Emacs (`M-x load-file`) and exercising the UI in a Go project buffer.
- To reload after edits: `M-x eval-buffer` in `gotest-mode.el`, or `(load-file "gotest-mode.el")` from the scratch buffer.
- The package targets Emacs 28.1+ and transient 0.6.0+.
