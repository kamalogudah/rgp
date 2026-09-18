# Construct measurement catalog

This document lists the Ruby constructs that the deterministic analyzer
measures. It corresponds to the First Analyzer Gate constructs in
[`plan.md`](../plan.md) (sections 13, 27 Phase 3, 28, and 35) and is exercised
by the AST fixture tests.

## Catalog

The analyzer currently supports **23 distinct construct measurements**.

### Conditionals

| Construct | AST node | Notes |
| --- | --- | --- |
| `if` | `PM_IF_NODE` | Includes `elsif` branches and modifier form. |
| `unless` | `PM_UNLESS_NODE` | Includes modifier form. |
| `case` | `PM_CASE_NODE`, `PM_CASE_MATCH_NODE` | Includes pattern-matching `case`. |

### Loops and iteration

| Construct | AST node / call | Notes |
| --- | --- | --- |
| `while` | `PM_WHILE_NODE` | Condition-controlled loop. |
| `until` | `PM_UNTIL_NODE` | Condition-controlled loop. |
| `for` | `PM_FOR_NODE` | `for item in collection` form. |
| `each` | `PM_CALL_NODE` | Detected by message name; receiver kind is recorded. |
| `times` | `PM_CALL_NODE` | Detected by message name; receiver kind is recorded. |

### Collection methods

| Construct | AST node / call | Notes |
| --- | --- | --- |
| `map` | `PM_CALL_NODE` | Transformation. |
| `collect` | `PM_CALL_NODE` | Alias for `map`. |
| `select` | `PM_CALL_NODE` | Filtering. |
| `filter` | `PM_CALL_NODE` | Alias for `select`. |
| `reject` | `PM_CALL_NODE` | Inverse filtering. |
| `reduce` | `PM_CALL_NODE` | Aggregation. |
| `inject` | `PM_CALL_NODE` | Alias for `reduce`. |
| `size` | `PM_CALL_NODE` | Cardinality; receiver kind distinguishes usage. |
| `length` | `PM_CALL_NODE` | Cardinality; receiver kind distinguishes usage. |
| `count` | `PM_CALL_NODE` | Cardinality; receiver kind distinguishes usage. |

### Definitions and object structure

| Construct | AST node | Notes |
| --- | --- | --- |
| `def` | `PM_DEF_NODE` | Method definition. |
| `class` | `PM_CLASS_NODE` | Class definition. |
| `module` | `PM_MODULE_NODE` | Module definition. |

### Blocks

| Construct | AST node | Notes |
| --- | --- | --- |
| `block` | `PM_BLOCK_NODE` | Generic block observation. The `block_syntax` attribute records whether the block uses `braces` (`{}`) or `do_end`. |

### Exceptions

| Construct | AST node | Notes |
| --- | --- | --- |
| `rescue` | `PM_RESCUE_NODE` | Exception handler. |

## Receiver semantics

For tracked method calls, the analyzer records the receiver kind so that
call-name frequencies can be compared across semantic contexts:

- `array` — literal array receiver (`[1,2,3].map`)
- `hash` — literal hash receiver
- `string` — literal string receiver (`"hello".length`)
- `integer` — literal integer receiver (`3.times`)
- `local_variable` — local variable receiver (`items.each`)
- `instance_variable` — instance variable receiver
- `call` — chained call receiver
- `other` — any other receiver expression

## Fixture coverage

`fixtures/parser/construct_catalog.rb` contains one occurrence of each
catalog construct arranged so the AST tests can assert exact counts and
receiver kinds. The test suite verifies:

- every construct in the table above is observed;
- the total number of observations matches the sum of expected counts;
- receiver kinds are distinguished for collection calls;
- block syntax forms (`{}` vs `do-end`) are recorded.

## Taxonomy mapping

`taxonomy.toml` maps these constructs to user-facing learning topics:

- `conditionals` — `if`, `unless`, `case`
- `loops_and_iteration` — `while`, `until`, `for`, `each`, `times`
- `collections.cardinality` — `size`, `length`, `count`
- `collections.transformation` — `map`, `collect`
- `collections.filtering` — `select`, `filter`, `reject`
- `collections.aggregation` — `reduce`, `inject`
- `methods` — `def`
- `oop` — `class`, `module`
- `blocks` — `block`
- `exceptions` — `rescue`

## Validation

Run the construct catalog tests as part of the offline suite:

```sh
zig build test
```

The fixture-based tests assert exact counts and receiver semantics without
network access.
