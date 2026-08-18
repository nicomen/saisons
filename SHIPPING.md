# Shipping a single `saisons` binary

## How it works

`saisons` ships as a **fatpacked** Perl script — a single self-contained executable
that bundles all non-core dependencies inline. No CPAN install required on the target
machine; just copy the file and run it.

### The fatpack pipeline

```
bin/saisons  +  lib/**/*.pm  +  fatlib/**/*.pm
        │
        ▼
  maint/pack.pl          ← custom bundler (replaces App::FatPacker's packer)
        │
        ▼
     saisons              ← committed executable (~98KB)
```

**Step-by-step** (what `make fatpack` does):

1. **`fatpack trace bin/saisons`** — runs the script under a tracing shim that records
   every `require`d module path into `fatpacker.trace`.

2. **Filter to non-core** — `Module::CoreList` strips modules that ship with Perl itself
   (POSIX, Scalar::Util, etc.), leaving only modules the target machine might not have.
   Result: `non-core.trace`.

3. **`fatpack packlists-for ...`** — finds the installed `.packlist` file for each
   non-core module, which tells fatpack where the `.pm` files live.

4. **`fatpack tree ...`** — copies those `.pm` files into `fatlib/`.

5. **`maint/pack.pl`** — custom bundler (replaces the standard `fatpack pack`):
   - Reads all `.pm` files from `fatlib/` and `lib/`
   - Runs each through a PPI-based minifier: strips comments, POD, and whitespace;
     renames local variables to single-letter names
   - Inlines adapter class names (removes `Module::Pluggable` dependency)
   - Prefills `%INC` so Perl thinks all modules are already loaded
   - Prepends a `#!/usr/bin/perl` shebang
   - Writes everything as one concatenated script to stdout → `saisons`

### Why a custom bundler instead of `fatpack pack`?

`fatpack pack` works fine and produces a correct binary (~111KB). The custom
`maint/pack.pl` adds PPI-based minification to shrink it to ~79KB. However:

- **PPI is memory-hungry** — on large inputs it can be OOM-killed (happened during
  development). If `make fatpack` hangs or is killed, try `fatpack pack bin/saisons > saisons`
  directly as a fallback (correct but larger output).
- **`maint/minify.pl`** is a simpler standalone minifier (strips comments/whitespace
  only, no variable renaming) used during earlier development.

### What gets bundled

Only **non-core** modules end up in `fatlib/`. Currently that means:
- `JSON::PP` — JSON parsing for session files
- `Term::ANSIColor` — terminal color output
- `Module::Pluggable` — adapter discovery (actually inlined away by `pack.pl`)

Core modules used (not bundled): `POSIX`, `Scalar::Util`, `List::Util`, `File::Find`,
`Time::Local`, `File::Spec`, `File::Copy`.

### The `saisons` file in the repo

The compiled `saisons` binary is **committed to the repo**. This means:

- Users can `curl` or `wget` it directly from GitHub raw and run it immediately
- No build step needed to install
- It must be **rebuilt and recommitted** after any change to `bin/saisons` or `lib/`

### Rebuilding after code changes

```bash
make fatpack
# or, if maint/pack.pl OOMs:
fatpack trace bin/saisons
perl -MModule::CoreList -e '...' < fatpacker.trace > non-core.trace
fatpack packlists-for $(cat non-core.trace) > packlists
fatpack tree $(cat packlists)
fatpack pack bin/saisons > saisons
chmod +x saisons
rm -f fatpacker.trace non-core.trace packlists
rm -rf fatlib
```

### Install for end users

```bash
# Linux
curl -L https://raw.githubusercontent.com/nicomen/saisons/main/saisons \
  -o ~/.local/bin/saisons && chmod +x ~/.local/bin/saisons

# macOS (Homebrew Perl)
curl -L https://raw.githubusercontent.com/nicomen/saisons/main/saisons \
  -o /usr/local/bin/saisons && chmod +x /usr/local/bin/saisons
```

## Files

| File | Purpose |
|------|---------|
| `saisons` | Committed fatpacked binary — the thing users download |
| `bin/saisons` | Source entrypoint — edit this, not `saisons` |
| `lib/App/Saisons.pm` | Version constant |
| `lib/App/Saisons/UI.pm` | TUI rendering and input loop |
| `lib/App/Saisons/Launcher.pm` | Terminal multiplexer integration |
| `lib/App/Saisons/Adapter/*.pm` | One adapter per AI agent (Claude, Codex, Aider, Gemini, opencode) |
| `maint/pack.pl` | Custom PPI-based bundler+minifier |
| `maint/minify.pl` | Simpler minifier (strips comments/whitespace only) |
| `Makefile.PL` | CPAN dist config; defines `make fatpack` target |
| `fatlib/` | Temporary — created by `fatpack tree`, deleted after packing |

## Gotchas

- **Edit `bin/saisons` and `lib/`, not `saisons`** — the binary is generated output.
- **`saisons` and `saisons.new` may diverge** — `saisons.new` is a scratch file from
  manual rebuild attempts; `saisons` is the canonical committed binary.
- **`Module::Pluggable` is inlined away** — `pack.pl` replaces the `plugins()` call
  with a hardcoded list of adapter class names, so the fatpacked binary has no runtime
  plugin discovery overhead.
- **Adding a new adapter** — add `lib/App/Saisons/Adapter/Foo.pm`, then rebuild
  `saisons` with `make fatpack`. The adapter list is auto-detected from filenames.
