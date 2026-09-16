# Parser fixture corpus

Each `.rb` file is a small, self-contained source-provenance fixture used by
the offline parser regression suite. Fixtures deliberately cover both accepted
and rejected input; their paths identify the expected classification.

| Fixture | Purpose |
| --- | --- |
| `phase1_constructs.rb` | Conditionals, loops, definitions, classes/modules, calls, blocks, arrays/hashes, assignments, and rescue. |
| `nested_multiline.rb` | Nested multiline blocks and one-based source-span regression coverage. |
| `ambiguous_calls.rb` | Ruby command-call, regexp, and division forms whose interpretation depends on syntax context. |
| `ruby_2_7_pattern_matching.rb` | Ruby 2.7+ pattern-matching syntax. |
| `invalid_unclosed_definition.rb` | Deliberately invalid syntax and deterministic diagnostics. |

Run the fixtures with the full offline regression suite:

```bash
zig build test
```

For a single structured report:

```bash
zig build run -- parse fixtures/parser/phase1_constructs.rb
