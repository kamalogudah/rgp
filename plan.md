# RGP --- Ruby: The Good Parts

## Architecture Decision Record and Development Plan

**Status:** Proposed\
**Date:** 2026-09-16\
**Working name:** `rgp`\
**Primary implementation language:** Zig\
**Ruby parser:** libprism\
**Coding-agent integration:** Pluggable adapter layer; fx is the initial/default adapter\
**Primary purpose:** Empirical Ruby analysis + adaptive Ruby learning +
code explanation

------------------------------------------------------------------------

# 1. Decision Summary

We will build **RGP (Ruby: The Good Parts)** as a Zig application that
studies real-world Ruby code and turns the resulting evidence into a
learning and exploration system for Ruby developers at different
experience levels.

RGP will have four primary product modes:

1.  **Analyze** --- analyze Ruby repositories and record how language
    constructs and idioms are used.
2.  **Learn** --- teach Ruby through a structured curriculum informed by
    real-world Ruby usage.
3.  **Practice** --- analyze learner solutions and provide
    level-appropriate feedback and exercises.
4.  **Explain** --- explain unfamiliar Ruby code, idioms, trade-offs,
    and alternative formulations.

The system will use **libprism** as the authoritative Ruby syntax
parser. Zig will own repository ingestion, AST traversal, idiom
detection, aggregation, persistence, reporting, curriculum integration,
and the CLI.

The system will also incorporate ideas and, where technically
appropriate, reusable components from **vercel-labs/fx**, a Zig-based,
model-agnostic, embeddable coding-agent harness. The goal is not to
replace deterministic analysis with an LLM. Instead:

-   libprism and RGP analyzers establish facts.
-   the corpus establishes empirical evidence.
-   the learning engine establishes curriculum and learner state.
-   the agent layer explains, tutors, asks questions, generates
    exercises, and navigates the evidence.

The LLM must never be the source of truth for construct counts.

------------------------------------------------------------------------

# 2. Context

Traditional Ruby tutorials teach syntax from an author's perspective.
Style tools generally encode predefined rules. Neither directly answers
questions such as:

-   How often do established Ruby projects use `each` compared with
    `for`?
-   For fixed iteration, how common is `Integer#times` compared with
    `while`?
-   When dealing with Arrays, how often are `size`, `length`, and
    `count` used?
-   How does usage change for Active Record relations?
-   Is `select` preferred over manually accumulating matching values?
-   How often is postfix `if` used for guard clauses?
-   Which Enumerable methods appear most frequently in production Ruby?
-   How do Rails, Hanami, Sidekiq, RSpec, RuboCop, and other ecosystems
    differ?
-   How has Ruby style changed between older and newer versions?

RGP should answer these questions from code rather than opinion.

The same information is valuable for teaching. Beginners should learn
the full language, but should also learn to recognize intent:

-   iteration
-   transformation
-   filtering
-   aggregation
-   predicates
-   guards
-   nil handling
-   object composition
-   exception handling

A learner should progress from merely knowing Ruby syntax to
understanding how Ruby developers express common programming ideas.

------------------------------------------------------------------------

# 3. Product Vision

> **Learn Ruby from how Ruby is actually written.**

RGP is simultaneously:

-   a Ruby corpus-analysis tool;
-   an empirical reference for Ruby idioms;
-   a beginner-to-advanced Ruby curriculum;
-   an interactive practice environment;
-   a code-explanation tool;
-   a research platform for the evolution of Ruby usage.

The intended long-term relationship is:

``` text
Open-source Ruby
       |
       v
  Zig + libprism
       |
       v
 Raw AST observations
       |
       v
  Idiom detection
       |
       v
 Empirical corpus
   /         \
  v           v
Explore     Curriculum
              |
              v
           Learner
              |
              v
        Learner code
              |
              v
        Zig + libprism
              |
              v
       Evidence-backed
          feedback
```

------------------------------------------------------------------------

# 4. Coding-Agent Plugin Architecture

Coding agents are **replaceable infrastructure**, not part of RGP's domain
core.

RGP will define its own stable `CodingAgent` contract. Agent-specific code
lives behind adapters:

```text
                    RGP Core
                       |
                 Agent Service
                       |
              CodingAgent interface
                       |
        +--------------+---------------+
        |              |               |
        v              v               v
    FxAdapter     FutureAdapter    FutureAdapter
      (v1)          (later)          (later)
        |
        v
       fx
```

The initial implementation ships with `FxAdapter`, but all higher-level RGP
features depend only on the RGP-owned interface.

Conceptual Zig interface:

```zig
pub const CodingAgent = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        startSession: *const fn (*anyopaque, SessionConfig) anyerror!SessionId,
        send: *const fn (*anyopaque, SessionId, AgentRequest) anyerror!AgentResponse,
        stream: ?*const fn (*anyopaque, SessionId, AgentRequest, StreamSink) anyerror!void,
        cancel: *const fn (*anyopaque, SessionId) anyerror!void,
        capabilities: *const fn (*anyopaque) AgentCapabilities,
        shutdown: *const fn (*anyopaque) void,
    };
};
```

The exact Zig API may change during implementation, but the architectural
boundary is mandatory.

## 4.1 Agent capabilities

Not every coding agent supports the same features. Adapters advertise
capabilities rather than forcing the core to assume them:

```text
chat
streaming
tool_calling
sessions
resume_session
file_read
file_write
shell
permissions
subagents
skills
mcp
acp
context_compaction
local_models
```

RGP features can then degrade gracefully.

For example, the learning tutor may require only:

```text
chat + tool_calling + sessions
```

while an advanced repository refactoring mode may additionally require:

```text
file_write + shell + permissions
```

## 4.2 RGP owns the tools

Coding agents consume RGP tools; agents do not own RGP analysis.

```text
Coding Agent
     |
     v
RGP Agent Gateway
     |
     +-- rgp.parse_file
     +-- rgp.analyze_file
     +-- rgp.get_stats
     +-- rgp.compare
     +-- rgp.find_examples
     +-- rgp.get_lesson
     +-- rgp.get_progress
     +-- rgp.submit_exercise
```

This is the critical portability boundary. Switching from fx to another agent
must not change corpus semantics or learning data.

## 4.3 Adapter configuration

A future configuration could look like:

```toml
[agent]
adapter = "fx"

[agents.fx]
command = "fx"

# Future example:
# [agents.other]
# command = "other-agent"
```

CLI selection should eventually support:

```bash
rgp agent list
rgp agent use fx
rgp agent status
rgp ask "Explain this method"
rgp ask --agent fx "Explain this method"
```

The default for the first release with agent support is `fx`.

## 4.4 Adapter lifecycle

Each adapter is responsible for translating between RGP's normalized protocol
and the external agent:

```text
RGP AgentRequest
      |
      v
adapter.translateRequest()
      |
      v
external coding agent
      |
      v
adapter.translateResponse()
      |
      v
RGP AgentResponse
```

Adapters own agent-specific:

- process spawning or embedding;
- authentication handoff;
- session identifiers;
- protocol conversion;
- streaming conversion;
- tool-call conversion;
- permission mapping;
- cancellation;
- error normalization.

RGP owns:

- learner identity and competency;
- curriculum;
- corpus evidence;
- tool definitions;
- repository analysis;
- policy for what the tutor may do;
- persistent educational state.

## 4.5 Initial fx adapter

`FxAdapter` is the reference implementation.

Prefer the least-coupled integration that provides the required capabilities.
Possible integration surfaces should be evaluated in this order:

1. stable process/protocol boundary;
2. ACP or another documented interoperability surface;
3. embeddable fx API/library;
4. direct internal fx dependencies only if unavoidable.

This keeps fx upgrades from forcing changes throughout RGP.

`FxAdapter` is the accepted first adapter behind `CodingAgent`; it is not a
decision to embed fx or make it a runtime dependency. That integration choice
is deferred until the analyzer is stable and a dedicated follow-up ADR has
accepted a specific boundary. Until then, the deterministic CLI/core remains
independent and must operate without an agent installation or network access.

---

## 4.6 Why fx Is the Initial Adapter

`vercel-labs/fx` is a particularly relevant reference because it is
itself written in Zig and describes itself as a small, open, embeddable,
model-agnostic coding-agent harness with a Unix-like CLI. It supports
interactive and one-shot agent use, model/provider abstraction, tool
use, saved sessions, context compaction, permissions, skills, MCP,
subagents, ACP, and native/WebAssembly embedding.

RGP should borrow the **agent harness architecture**, not delegate Ruby
understanding to it.

### 4.6.1 What RGP should learn from fx

#### Model-provider abstraction

RGP should avoid coupling tutoring to one AI provider. The agent layer
should have a provider interface so users can eventually choose:

-   hosted providers;
-   local OpenAI-compatible endpoints;
-   institutional models;
-   offline/local models where feasible.

The deterministic RGP engine must work without an LLM.

#### Interactive shell

RGP should eventually offer:

``` text
$ rgp

rgp> analyze rails/rails
rgp> compare each for
rgp> explain app/services/order_processor.rb
rgp> learn collections
rgp> practice map
rgp> why map instead of each here?
```

The shell can maintain context about the repository, current lesson,
learner level, and prior questions.

#### One-shot interface

The Unix-style interface should remain composable:

``` bash
rgp analyze https://github.com/rails/rails
rgp report collections
rgp compare size count length
rgp explain example.rb
rgp ask "How does this project normally filter collections?"
```

Structured output should be available:

``` bash
rgp analyze . --json
rgp report iteration --json
```

#### Tool-oriented agent

The tutor should not receive an entire repository and guess. It should
call deterministic RGP tools such as:

``` text
parse_file
find_constructs
find_idioms
get_corpus_stats
get_project_stats
get_examples
compare_constructs
get_curriculum_topic
get_learner_progress
run_exercise
explain_ast_region
```

This makes the AI a consumer of RGP evidence.

#### Sessions

Learning requires continuity. Sessions should preserve:

-   current topic;
-   learner level;
-   exercises attempted;
-   concepts demonstrated;
-   misconceptions encountered;
-   repository being explored;
-   prior explanations.

#### Context compaction

Long learning and code-exploration sessions will exceed model context.
RGP can adopt the fx principle of compacting older interaction state
while retaining structured learner state separately.

Critical learning state must live in the database, not only in
conversational context.

#### Permissions

An explanatory tutor should have fewer permissions than an agent editing
a repository.

Possible modes:

``` text
observe
learn
suggest
edit
agent
```

For a beginner, the default should be `learn`: inspect code, explain,
ask questions, run exercises, but do not automatically rewrite the
learner's solution.

#### Skills

RGP can expose teaching behaviors as skills:

``` text
skills/
  beginner-tutor/
  ruby-collections/
  ruby-blocks/
  ruby-oop/
  rails-reader/
  code-review/
  socratic-mode/
  interview-practice/
```

#### MCP / external tools

Later, RGP can expose its corpus as an MCP server or consume external
tools through MCP. This makes RGP's empirical Ruby knowledge usable from
editors and other agents.

#### Subagents

Subagents are useful later for complex repository learning:

``` text
Ruby Tutor
   |
   +-- Syntax Explainer
   +-- Idiom Researcher
   +-- Repository Navigator
   +-- Exercise Generator
   +-- Test Runner
```

They should not be required for the MVP.

#### Embedding

fx's embeddability is especially relevant if RGP later has:

-   a terminal CLI;
-   a web learning application;
-   an editor integration;
-   a classroom platform;
-   a WASM-based browser experience.

### 4.6.2 Integration decision

Do **not** begin by forking fx and putting all RGP functionality inside
it.

Instead:

1.  design RGP's core as an independent Zig library;
2.  design a clean agent/tool interface;
3.  initially implement the RGP CLI directly;
4.  study/reuse fx patterns for sessions, provider abstraction,
    permissions and tool dispatch;
5.  evaluate direct fx embedding after the deterministic analyzer is
    stable.

This prevents a fast-moving experimental agent project from becoming a
hard dependency of the corpus engine.

------------------------------------------------------------------------

# 5. Architectural Principles

## 5.1 Deterministic core, probabilistic assistant

``` text
          SOURCE OF TRUTH
               |
       Zig + libprism
               |
      Corpus + classifiers
               |
        structured facts
               |
               v
          Agent / LLM
               |
        explanation only
```

Counts, AST facts, source locations, classifications, repository
metadata, and learner exercise results must not be invented by an LLM.

## 5.2 Observe before judging

The analyzer records observations first.

Bad:

``` text
for_loop => bad_ruby
```

Good:

``` text
construct = for_loop
topic = iteration
context = collection_iteration
```

A later report may state that `each` is much more common for a
comparable intent, with evidence.

## 5.3 Compare intent, not merely syntax

Raw frequencies can mislead.

`User.count` and `[1,2,3].count` are syntactically similar but may
represent database and in-memory operations.

The analysis hierarchy is therefore:

``` text
AST node
   |
   v
Observation
   |
   v
Semantic context
   |
   v
Idiom
   |
   v
Comparison group
   |
   v
Curriculum topic
```

## 5.4 Provenance everywhere

Every observation should retain:

-   repository;
-   commit SHA;
-   file;
-   source location;
-   repository category;
-   production/test/example classification;
-   Ruby version when inferable;
-   framework/library context when inferable.

## 5.5 Learning feedback should reveal progressively

For beginners, RGP should not immediately replace working code with an
expert one-liner.

Progression:

``` text
hint -> concept -> partial example -> solution -> ecosystem evidence
```

------------------------------------------------------------------------

# 6. High-Level Architecture

``` text
                     +-----------------------+
                     | GitHub / local source |
                     +-----------+-----------+
                                 |
                                 v
                     +-----------------------+
                     | Corpus / Repo Manager |
                     +-----------+-----------+
                                 |
                         Ruby source files
                                 |
                                 v
                     +-----------------------+
                     |       libprism        |
                     +-----------+-----------+
                                 |
                              AST/CST
                                 |
                                 v
                    +-------------------------+
                    | Zig AST Visitor         |
                    | Observation Extraction  |
                    +------------+------------+
                                 |
                                 v
                    +-------------------------+
                    | Idiom Detection Engine  |
                    +------------+------------+
                                 |
                +----------------+----------------+
                |                                 |
                v                                 v
       +------------------+              +------------------+
       | Corpus Database  |              | Learning Engine  |
       +--------+---------+              +---------+--------+
                |                                  |
                v                                  v
       +------------------+              +------------------+
       | Stats / Reports  |              | Progress / Tasks |
       +--------+---------+              +---------+--------+
                \                                  /
                 \                                /
                  +---------------+--------------+
                                  |
                                  v
                         +------------------+
                         | Agent Tool Layer |
                         +--------+---------+
                                  |
                                  v
                         +------------------+
                         | CodingAgent Layer|
                         | Tutor / Explain  |
                         +--------+---------+
                                  |
             +--------------------+-------------------+
             |                    |                   |
             v                    v                   v
            CLI                  Web                Editor
```

------------------------------------------------------------------------

# 7. Core Modules

Recommended repository structure:

``` text
rgp/
├── build.zig
├── build.zig.zon
├── README.md
├── plan.md
├── corpus.toml
├── taxonomy.toml
├── idioms.toml
├── curriculum/
│   ├── foundations/
│   ├── control-flow/
│   ├── collections/
│   ├── methods/
│   ├── blocks/
│   ├── oop/
│   ├── exceptions/
│   ├── pattern-matching/
│   ├── metaprogramming/
│   ├── concurrency/
│   └── real-world-ruby/
├── src/
│   ├── main.zig
│   ├── core.zig
│   ├── cli/
│   │   ├── analyze.zig
│   │   ├── corpus.zig
│   │   ├── report.zig
│   │   ├── compare.zig
│   │   ├── explain.zig
│   │   ├── learn.zig
│   │   ├── practice.zig
│   │   └── ask.zig
│   ├── repository/
│   │   ├── clone.zig
│   │   ├── metadata.zig
│   │   ├── discovery.zig
│   │   └── classification.zig
│   ├── prism/
│   │   ├── bindings.zig
│   │   ├── parser.zig
│   │   ├── node.zig
│   │   └── visitor.zig
│   ├── analysis/
│   │   ├── observation.zig
│   │   ├── context.zig
│   │   ├── idiom.zig
│   │   ├── classifier.zig
│   │   └── analyzers/
│   │       ├── conditionals.zig
│   │       ├── iteration.zig
│   │       ├── collections.zig
│   │       ├── methods.zig
│   │       ├── blocks.zig
│   │       ├── oop.zig
│   │       ├── exceptions.zig
│   │       ├── pattern_matching.zig
│   │       └── metaprogramming.zig
│   ├── storage/
│   │   ├── sqlite.zig
│   │   ├── migrations.zig
│   │   └── queries.zig
│   ├── reports/
│   │   ├── terminal.zig
│   │   ├── json.zig
│   │   ├── markdown.zig
│   │   └── statistics.zig
│   ├── learning/
│   │   ├── taxonomy.zig
│   │   ├── curriculum.zig
│   │   ├── lesson.zig
│   │   ├── exercise.zig
│   │   ├── assessment.zig
│   │   ├── competency.zig
│   │   └── feedback.zig
│   ├── agent/
│   │   ├── service.zig
│   │   ├── interface.zig
│   │   ├── capabilities.zig
│   │   ├── session.zig
│   │   ├── permissions.zig
│   │   ├── tools.zig
│   │   └── tutor.zig
│   └── agents/
│       ├── registry.zig
│       └── fx/
│           ├── adapter.zig
│           ├── protocol.zig
│           └── process.zig
├── tests/
└── fixtures/
```

------------------------------------------------------------------------

# 8. libprism Integration

libprism is responsible for parsing Ruby.

RGP must not implement Ruby parsing with regexes.

For each `.rb` file:

``` text
source
  |
  v
libprism parse
  |
  v
Prism tree
  |
  v
Zig visitor
  |
  +-- node type
  +-- source location
  +-- method name
  +-- receiver
  +-- arguments
  +-- parent context
  +-- ancestor context
  +-- block structure
  +-- assignment structure
  +-- control-flow structure
```

Example:

``` ruby
10.times do |i|
  puts i
end
```

should produce observations sufficient to classify:

``` text
topic: loops_and_iteration
intent: fixed_iteration
construct: times
receiver_type: integer_literal
block: true
```

For:

``` ruby
i = 0
while i < 10
  puts i
  i += 1
end
```

the classifier should identify a possible:

``` text
intent: fixed_iteration
construct: while
```

This allows meaningful comparison of `times` and a counter-based
`while`.

------------------------------------------------------------------------

# 9. Observation Model

Conceptual structure:

``` zig
const Observation = struct {
    repository_id: i64,
    commit_id: i64,
    file_id: i64,

    start_offset: u32,
    end_offset: u32,
    line: u32,
    column: u32,

    node_kind: NodeKind,
    construct: Construct,
    name: ?[]const u8,
    receiver_kind: ?ReceiverKind,

    context: Context,
    topic_id: ?u32,
    idiom_id: ?u32,

    production_class: ProductionClass,
};
```

Never discard the raw observation after generating an aggregate.

------------------------------------------------------------------------

# 10. Idiom Detection

The idiom engine recognizes combinations of AST nodes.

Initial idioms should include:

``` text
collection_iteration
fixed_iteration
manual_collection_transformation
collection_transformation
manual_filter
collection_filter
manual_accumulation
aggregation
guard_clause
postfix_conditional
empty_collection_check
nil_guard
safe_navigation
memoization
hash_fetch_with_default
symbol_to_proc
each_with_index
each_with_object
exception_as_control_flow
early_return
predicate_method
bang_method
mixin
class_macro
method_forwarding
```

Example:

``` ruby
names = []
users.each do |user|
  names << user.name
end
```

may be classified as:

``` text
manual_collection_transformation
```

and compared with:

``` ruby
names = users.map(&:name)
```

The analyzer must distinguish "possible alternative" from "semantically
guaranteed equivalent."

------------------------------------------------------------------------

# 11. Curriculum Taxonomy

The public learning/report hierarchy should be educational rather than
based on Prism node names.

``` text
01 Syntax & Fundamentals
02 Data Types
03 Conditionals
04 Loops & Iteration
05 Collections
06 Methods
07 Blocks, Procs & Lambdas
08 Object-Oriented Ruby
09 Exceptions
10 Pattern Matching
11 Metaprogramming
12 Files & Dependencies
13 Concurrency
14 Testing
15 Real-World Ruby Idioms
```

This taxonomy should live in `taxonomy.toml`, not be hardcoded.

The schema-version rules, validation requirements, and diagnostics for this
file are normative in [`docs/configuration.md`](docs/configuration.md). The
example below illustrates the same version-1 contract.

Example:

``` toml
schema_version = 1

[[topic]]
id = "collections.cardinality"
title = "Collection Cardinality"
section = "collections"

constructs = [
  "size",
  "length",
  "count"
]
```

------------------------------------------------------------------------

# 12. Corpus Design

Initial curated corpus may include projects such as:

``` text
rails/rails
rack/rack
sidekiq/sidekiq
rubocop/rubocop
rspec/*
heartcombo/devise
puma/puma
sinatra/sinatra
hanami/hanami
dry-rb/*
hotwired/*
ruby/rake
ruby/debug
ruby/irb
faker-ruby/faker
spree/spree
```

Do not treat all source equally.

Classify files as:

``` text
production
test
spec
benchmark
example
fixture
generated
vendor
```

Reports should support filters:

``` bash
rgp report iteration --production
rgp report iteration --tests
rgp report iteration --project rails
rgp report iteration --ruby ">=3.2"
```

Each corpus snapshot records exact commit SHAs so analysis is
reproducible.

`corpus.toml` is the versioned source of this selection. Its pinned-revision,
offline, schema, and invalid-input rules are normative in
[`docs/configuration.md`](docs/configuration.md).

------------------------------------------------------------------------

# 13. Core Empirical Questions

## Iteration

Compare:

``` text
each
for
while
until
loop
times
each_with_index
each_with_object
```

Group by intent:

``` text
collection iteration
fixed iteration
condition-controlled iteration
indexed iteration
accumulating iteration
```

## Collections

Compare:

``` text
size / length / count
select / filter / reject
map / collect
reduce / inject / sum
find / detect
any? / all? / none? / one?
empty? / size == 0 / count == 0
[] / fetch
```

## Conditionals

Compare:

``` text
if / unless
postfix / multiline
case / if-elsif
ternary / if
nil? / truthiness
guard clauses / nested conditionals
```

## Blocks

Compare:

``` text
{} / do-end
explicit block / &:symbol
yield / block.call
Proc / lambda
```

## Object-oriented Ruby

Measure:

``` text
inheritance
include
extend
prepend
composition indicators
class methods
visibility
attr_reader/writer/accessor
```

## Exceptions

Measure:

``` text
rescue forms
ensure
raise/fail
retry
inline rescue
```

------------------------------------------------------------------------

# 14. Reporting

The CLI should make empirical analysis easy.

``` bash
rgp corpus add https://github.com/rails/rails
rgp corpus sync
rgp analyze
rgp report
rgp report collections
rgp report collections.cardinality
rgp compare size count length
rgp compare each for --context collection_iteration
```

Example:

``` text
Collection Cardinality
======================

Corpus:
  repositories     428
  Ruby files   117,281
  Ruby LOC      21.7M

In-memory collection contexts:

.size        61.2%
.length      26.4%
.count       12.4%

Database/query contexts:

.count       74.1%
.size        20.3%
.length       5.6%
```

All statistics shown above are illustrative until produced by the actual
corpus.

------------------------------------------------------------------------

# 15. Learning Mode

``` bash
rgp learn
rgp learn collections
rgp learn collections.map
```

Each lesson should contain:

1.  concept;
2.  basic syntax;
3.  mental model;
4.  simple examples;
5.  corpus evidence;
6.  representative real-world examples;
7.  comparison with alternatives;
8.  exercise;
9.  feedback;
10. optional deeper explanation.

Example progression:

``` text
Learn Arrays
   |
   v
Learn each
   |
   v
Recognize transformation
   |
   v
Learn map
   |
   v
Recognize filtering
   |
   v
Learn select
   |
   v
Recognize aggregation
   |
   v
Learn sum/reduce
```

------------------------------------------------------------------------

# 16. Beginner vs Senior Learning

RGP must not assume "learning Ruby" means only beginner education.

## Beginner

Focus on:

``` text
syntax
mental models
small examples
explicit forms
guided exercises
hints
common idioms
reading simple real code
```

## Intermediate

Focus on:

``` text
Enumerable fluency
blocks
object design
error handling
testing
Ruby project structure
performance implications
framework conventions
```

## Senior / experienced developer

Focus on:

``` text
less-common Ruby constructs
metaprogramming
DSL design
Ruby internals
concurrency
API design
performance
memory behavior
cross-project comparisons
historical idiom evolution
large repository exploration
```

A senior developer coming from Java, Go, Python, JavaScript or another
ecosystem should be able to use RGP to learn "how Ruby thinks" rather
than repeat basic programming lessons.

------------------------------------------------------------------------

# 17. Competency Model

Track demonstrated competency separately from lesson completion.

Conceptual record:

``` text
Concept                  Exposure   Practice   Demonstrated

Arrays                       3          3           3
each                         3          3           3
map                          3          3           3
select                       3          2           2
reduce                       2          1           1
each_with_object             1          0           0
pattern matching             0          0           0
```

Possible levels:

``` text
0 unseen
1 introduced
2 practiced
3 demonstrated
4 fluent
```

Competency evidence can come from:

-   exercises;
-   code explanations;
-   repository-reading questions;
-   learner-written code;
-   refactoring exercises;
-   quizzes;
-   project work.

------------------------------------------------------------------------

# 18. Practice Mode

``` bash
rgp practice map
rgp practice conditionals
rgp practice --level beginner
```

Example exercise:

``` ruby
names = []

users.each do |user|
  names << user.name
end
```

Prompt:

``` text
This code transforms every user into a name.

Can you express that intention using an Enumerable method?
```

The system should provide progressively stronger hints.

After successful completion, show corpus context:

``` text
You used `map`, which expresses collection transformation.

Explore:
  rgp examples map
  rgp compare map manual_collection_transformation
```

------------------------------------------------------------------------

# 19. Explain Mode

``` bash
rgp explain file.rb
rgp explain file.rb:20-35
```

Example Ruby:

``` ruby
users
  .select(&:active?)
  .map(&:email)
  .compact
  .uniq
```

Deterministic analysis should identify:

``` text
select  -> filtering
map     -> transformation
compact -> nil removal
uniq    -> deduplication
```

The agent layer can turn that into an explanation appropriate to the
learner's level.

Beginner explanation and senior explanation should differ.

------------------------------------------------------------------------

# 20. Pluggable Agent / Tutor Architecture

The tutor should interact with RGP through explicit tools. The tutor depends
on the generic `CodingAgent` interface, never directly on fx. fx is selected
through the agent registry and `FxAdapter`.

The agent should interact with RGP through explicit tools.

Initial tool contract:

``` text
rgp.parse_file
rgp.analyze_file
rgp.analyze_repository
rgp.get_construct
rgp.get_idiom
rgp.get_topic
rgp.get_stats
rgp.compare
rgp.find_examples
rgp.get_lesson
rgp.get_exercise
rgp.submit_exercise
rgp.get_progress
rgp.record_progress
```

Example:

``` text
User:
Why is map better here?

Tutor:
   |
   +--> analyze_file
   |
   +--> identify idiom:
   |       manual_collection_transformation
   |
   +--> get comparison:
   |       map vs manual transformation
   |
   +--> get corpus stats
   |
   +--> get learner level
   |
   +--> explain
```

This makes answers grounded and inspectable.

------------------------------------------------------------------------

# 21. Agent Permissions

Suggested modes:

``` text
observe
  read/analyze only

learn
  analyze + lessons + exercises

suggest
  propose code changes but do not apply

edit
  apply explicit approved changes

agent
  perform multi-step repository work
```

`learn` should be the default for educational use.

For beginners, automatic code rewriting should be discouraged because it
can remove the learning step.

------------------------------------------------------------------------

# 22. AI Is Optional

The following commands must work without AI:

``` text
rgp analyze
rgp report
rgp compare
rgp stats
rgp examples
rgp learn <static lesson>
```

AI enhances:

``` text
rgp ask
rgp explain
adaptive hints
exercise generation
Socratic tutoring
repository walkthroughs
personalized lesson sequencing
```

This is an important architectural boundary.

------------------------------------------------------------------------

# 23. Storage

Start with SQLite.

Proposed tables:

``` text
repositories
commits
files
analysis_runs
observations
constructs
idioms
topics
observation_idioms
corpus_snapshots

learners
learning_sessions
competencies
competency_evidence
lessons
lesson_progress
exercises
exercise_attempts

agent_sessions
agent_messages
agent_tool_calls
```

Aggregates should be derived from observations or materialized as
caches.

------------------------------------------------------------------------

# 24. Representative CLI

``` text
CORPUS

rgp corpus add <github-url>
rgp corpus remove <repo>
rgp corpus list
rgp corpus sync


ANALYSIS

rgp analyze <repo-or-path>
rgp analyze
rgp analyze --corpus


EXPLORATION

rgp report
rgp report collections
rgp stats each
rgp compare each for
rgp compare size count length
rgp examples map
rgp examples guard_clause --project rails


LEARNING

rgp learn
rgp learn collections
rgp practice collections.map
rgp progress


EXPLANATION

rgp explain app/models/user.rb
rgp explain app/models/user.rb:40-65


AGENT

rgp
rgp ask "Why does this project use each_with_object here?"
```

`rgp analyze` with no arguments is exactly an alias for `rgp analyze
--corpus`: both analyze all configured, locally materialized corpus snapshots
at their pinned revisions. Neither silently analyzes the current directory or
fetches a repository. `rgp analyze <repo-or-path>` is the explicit one-off
mode. If a corpus snapshot is absent, the command reports the missing pinned
revision and directs the user to run `rgp corpus sync`; it never falls back to
a moving branch or remote checkout.

------------------------------------------------------------------------

# 25. Example Interactive Session

``` text
$ rgp learn collections

Collections
===========

You have demonstrated:
  Arrays       fluent
  each         fluent
  map          practiced
  select       introduced

Recommended next topic:
  Collection filtering with select/reject

rgp> start

Consider:

active = []
users.each do |user|
  active << user if user.active?
end

What is this code doing?

> Creating a new array with only active users.

Correct.

Ruby's Enumerable API provides a method specifically for
this intention. Which one?

> select

Correct.

Now rewrite it.
```

A senior session could instead begin:

``` text
$ rgp explore collections

Corpus snapshot: 2026-09

What would you like to compare?

> show filter_map adoption by Ruby version
```

------------------------------------------------------------------------

# 26. Web Application Later

The CLI/core should not depend on the future web application.

Potential web navigation:

``` text
Ruby: The Good Parts

Learn
Explore
Practice
Explain
Corpus
Progress
```

`Explore` can visually resemble a learning roadmap while allowing
drill-down into empirical statistics.

Example:

``` text
Collections
 |
 +-- Iteration
 +-- Transformation
 |    +-- map
 |    +-- collect
 |    +-- filter_map
 |
 +-- Filtering
 |    +-- select
 |    +-- reject
 |
 +-- Aggregation
      +-- sum
      +-- reduce
      +-- inject
```

------------------------------------------------------------------------

# 27. Development Roadmap

## Phase 0 --- Project bootstrap (Week 1)

Deliver:

-   Zig project;
-   CI;
-   formatter/lint/test workflow;
-   basic CLI command router;
-   ADR accepted;
-   versioned corpus, taxonomy, and idiom configuration contracts;
-   libprism build/link spike.

Acceptance:

``` bash
zig build
zig build test
rgp --help
```

## Phase 1 --- libprism foundation (Weeks 2--3)

Implement:

-   libprism Zig bindings;
-   source parser;
-   safe memory ownership;
-   AST traversal;
-   source locations;
-   parser-error handling;
-   fixtures for Ruby syntax.

Target constructs:

``` text
if
unless
case
while
until
for
def
class
module
method calls
blocks
arrays
hashes
assignments
rescue
```

Acceptance:

``` bash
rgp parse example.rb
```

returns deterministic structured node/observation output.

## Phase 2 --- Repository and corpus ingestion (Weeks 4--5)

Implement:

-   local repository analysis;
-   GitHub URL cloning;
-   recursive Ruby discovery;
-   exclusions;
-   commit SHA capture;
-   production/test/example classification;
-   SQLite repository;
-   incremental analysis.

Acceptance:

``` bash
rgp corpus add https://github.com/rack/rack
rgp corpus sync
rgp analyze --corpus
rgp analyze
```

The two analysis commands above are aliases; both require pinned snapshots.

## Phase 3 --- Construct statistics (Weeks 6--7)

Implement first reports:

``` text
if / unless
case / if
each / for
times / while
size / count / length
map / collect
select / filter / reject
reduce / inject
{} / do-end
```

Acceptance:

``` bash
rgp compare size count length
```

returns counts, percentages, project distribution, and provenance.

## Phase 4 --- Idiom engine (Weeks 8--10)

Implement pattern detection:

``` text
manual transformation
manual filtering
manual accumulation
guard clauses
empty checks
memoization
symbol-to-proc
fixed iteration
indexed iteration
```

Create classifier test corpus with positive and negative examples.

Acceptance:

``` bash
rgp idioms file.rb
```

identifies supported idioms with source ranges and
confidence/classification reason.

## Phase 5 --- Taxonomy and evidence-backed reports (Weeks 11--12)

Implement:

-   roadmap-style topic hierarchy;
-   `taxonomy.toml`;
-   construct -\> idiom -\> topic mapping;
-   topic reports;
-   Markdown/JSON/terminal output.

Acceptance:

``` bash
rgp report collections
rgp report loops-and-iteration
```

## Phase 6 --- Learning MVP (Weeks 13--15)

Implement lessons for:

``` text
fundamentals
conditionals
loops
arrays
hashes
Enumerable
methods
blocks
classes/modules
exceptions
```

Implement:

-   learner profile;
-   progress;
-   competency state;
-   static exercises;
-   deterministic exercise validation.

Acceptance:

A beginner can complete a coherent Ruby fundamentals path from the CLI.

## Phase 7 --- Practice and adaptive feedback (Weeks 16--18)

Implement:

-   learner code parsing;
-   idiom recognition in submissions;
-   hints;
-   alternative formulations;
-   corpus-backed feedback;
-   competency evidence.

Acceptance:

RGP can distinguish a correct manual solution from an idiomatic
Enumerable solution and teach the relevant abstraction without simply
rewriting it.

## Phase 8 --- fx-style agent foundation (Weeks 19--21)

Implement/evaluate:

-   provider abstraction;
-   tool registry;
-   interactive session;
-   permission modes;
-   persistent agent session;
-   RGP tool calling;
-   context management.

At this phase explicitly evaluate whether to:

1.  embed fx directly;
2.  depend on selected fx libraries/components;
3.  continue with an RGP-native harness modeled after fx.

Write a follow-up ADR before making fx a hard runtime dependency.

Acceptance:

``` bash
rgp ask "Explain this method to a beginner"
```

uses deterministic analysis tools before generating the explanation.

## Phase 9 --- Adaptive tutor (Weeks 22--24)

Implement:

-   learner-level-aware explanations;
-   Socratic mode;
-   adaptive exercise selection;
-   misconception tracking;
-   beginner/intermediate/senior explanation profiles;
-   lesson recommendations.

## Phase 10 --- Repository learning (Weeks 25--27)

Implement:

``` bash
rgp learn-repo https://github.com/hanami/hanami
```

Capabilities:

-   repository concept map;
-   constructs worth studying;
-   "show me examples of X";
-   guided source walkthrough;
-   compare repository conventions with corpus;
-   generate reading exercises.

## Phase 11 --- Web/API foundation (Weeks 28--32)

Expose core operations through a stable API.

Build initial web UI:

``` text
Learn
Explore
Practice
Explain
Corpus
Progress
```

Do not duplicate analyzer logic in the web layer.

------------------------------------------------------------------------

# 28. MVP Boundary

The first meaningful release should NOT require AI.

This is the **full Learning MVP gate**, reached after Phase 6. It is distinct
from the narrower First Analyzer Gate in section 35, which establishes
trustworthy corpus evidence before idiom detection and learning work begin.

MVP:

``` text
Zig CLI
libprism integration
GitHub/local repository ingestion
SQLite
20+ construct measurements
5+ idiom detectors
roadmap-style taxonomy
terminal reports
JSON output
10 beginner lessons
basic exercises
learner progress
```

This proves the central thesis:

> Real Ruby code can be converted into structured empirical evidence and
> used to improve Ruby learning.

Agentic tutoring comes after that foundation.
The full Learning MVP includes no fx runtime dependency, agent provider, or
network requirement for its core local workflow; those remain later phases.

------------------------------------------------------------------------

# 29. Testing Strategy

## Parser tests

Fixtures for every supported Ruby syntax form.

## Classifier tests

Each idiom needs:

``` text
positive examples
negative examples
ambiguous examples
nested examples
version-specific examples
```

## Corpus regression tests

Maintain a small pinned corpus and assert stable aggregate output.

## Golden report tests

Given fixed observations, generated reports must remain stable.

## Learning tests

Exercises must test:

``` text
correct solution
alternative correct solution
syntactically invalid solution
semantically wrong solution
manual but correct solution
idiomatic solution
```

## Agent grounding tests

Agent tests should verify that statistical claims originate from RGP
tool output.

------------------------------------------------------------------------

# 30. Performance

Large corpus analysis should be parallelized at the file/repository
level where safe.

Potential pipeline:

``` text
repo discovery
     |
     v
work queue
 | | | |
 v v v v
parse workers
 | | | |
 v v v v
observation batches
     |
     v
single/batched DB writer
```

Important:

-   avoid reparsing unchanged files;
-   hash files;
-   persist analysis version;
-   batch SQLite writes;
-   use prepared statements;
-   keep source text out of the main observations table unless needed;
-   cache aggregate reports;
-   pin corpus commits.

------------------------------------------------------------------------

# 31. Versioning the Analyzer

The interpretation of code will improve over time.

Every analysis run must record:

``` text
rgp_version
prism_version
classifier_version
taxonomy_version
corpus_snapshot
```

A changed classifier should not silently make old statistics
incomparable.

------------------------------------------------------------------------

# 32. Ethical / Pedagogical Guardrails

RGP should avoid turning frequency into authority.

"Common" does not necessarily mean "correct."

Reports should distinguish:

``` text
frequency
context
performance implications
semantic differences
historical convention
style convention
```

The learning system should use language such as:

``` text
"More common in this corpus"
"Common when..."
"These forms differ because..."
"Consider..."
```

rather than:

``` text
"Always..."
"Never..."
```

unless Ruby semantics actually require it.

------------------------------------------------------------------------

# 33. Risks

## Corpus bias

Rails-heavy analysis could become "Rails: The Good Parts."

Mitigation: categorize repositories and report both global and cohort
statistics.

## False idiom equivalence

Two syntactic patterns may not be semantically interchangeable.

Mitigation: conservative classifiers, explicit confidence, tests, and
semantic categories.

## AI hallucination

Tutor may invent corpus evidence.

Mitigation: tool-only access to statistics and provenance; structured
citations internally.

## fx dependency volatility

fx currently presents itself as experimental.

Mitigation: keep RGP core independent and defer hard dependency until a
dedicated integration ADR.

## Beginner over-compression

Idiomatic Ruby can become overly clever.

Mitigation: teach explicit forms first and concision later.

## Performance

Millions of observations can become expensive.

Mitigation: incremental parsing, batching, snapshots and cached
aggregates.

------------------------------------------------------------------------

# 34. Decisions

## ADR-001 --- Zig as primary implementation language

**Decision:** Accepted.

Reasons:

-   native CLI;
-   performance;
-   straightforward C interoperability with libprism;
-   good fit for large corpus processing;
-   architectural affinity with fx.

## ADR-002 --- libprism as Ruby parser

**Decision:** Accepted.

RGP will not implement a Ruby parser.

## ADR-003 --- SQLite as initial persistence

**Decision:** Accepted.

SQLite is sufficient for the CLI and local corpus. A server database can
be introduced for hosted deployment later.

## ADR-004 --- Educational taxonomy separate from parser taxonomy

**Decision:** Accepted.

Prism node types are internal. Users navigate concepts such as
Collections, Iteration and Blocks.

## ADR-005 --- Observation -\> Idiom -\> Topic architecture

**Decision:** Accepted.

Raw syntax observations must remain separate from semantic
classifications and educational grouping.

## ADR-006 --- Deterministic analysis is source of truth

**Decision:** Accepted.

LLMs may explain analysis but must not generate corpus statistics.

## ADR-007 --- AI is optional

**Decision:** Accepted.

Core analysis and basic learning must work offline without an AI
provider.

## ADR-008 --- fx-inspired agent architecture

**Decision:** Accepted with deferred dependency decision.

RGP will adopt useful architectural ideas from fx, particularly model
abstraction, tool calling, sessions, permissions, context management,
skills and embeddability.

A direct fx runtime dependency requires a later ADR after the analyzer
MVP.

## ADR-008A --- fx is the initial adapter, not the architecture

**Decision:** Accepted.

The first adapter will target fx. This choice bootstraps agent functionality
without making fx synonymous with RGP's agent architecture.

Adding a second coding agent should require:

1. a new adapter implementation;
2. capability mapping;
3. configuration/registry entry;
4. adapter contract tests.

It should require no changes to libprism analysis, corpus storage, idiom
classification, curriculum, competency models, or RGP tool definitions.

## ADR-009 --- Beginner and senior learning are first-class

**Decision:** Accepted.

The system is not merely a beginner tutorial. Content depth and feedback
adapt to experience.

## ADR-010 --- Corpus provenance is mandatory

**Decision:** Accepted.

Every published statistic must be traceable to corpus snapshot and
source observations.

------------------------------------------------------------------------

# 35. First Development Milestone

## First Analyzer Gate

This gate follows Phase 3 and is intentionally smaller than the full Learning
MVP. It proves reproducible analysis; it does not include idiom detection,
lessons, practice, agents, or a direct fx dependency.

``` text
rgp corpus add <github-url>
rgp analyze
rgp compare each for
rgp compare times while
rgp compare size count length
rgp report conditionals
rgp report collections
```

Use libprism from the beginning.

Initial database entities:

``` text
Repository
Commit
File
AnalysisRun
Observation
Construct
Topic
```

Initial constructs:

``` text
if
unless
case
while
until
for
each
times
map
select
reject
size
length
count
def
class
module
block
rescue
```

Once these statistics are trustworthy, implement idiom detection and
learning. The gate passes only when:

- the version-1 corpus, taxonomy, and idiom contracts validate with actionable
  diagnostics;
- `rgp analyze` and `rgp analyze --corpus` analyze the same pinned local
  snapshots, while a positional target remains explicit;
- observations and reports retain repository ID, source, commit SHA,
  configuration schema version, and analyzer version; and
- the analyzer can run against an already materialized corpus without network
  access.

------------------------------------------------------------------------

# 36. Definition of Success

RGP succeeds when it can answer all of these from evidence:

``` text
How do Ruby projects iterate over collections?

When do Ruby developers use `times` rather than `while`?

How are `size`, `length`, and `count` actually used?

Show me real examples of `each_with_object`.

Teach `map` to someone who only knows loops.

Explain this Rails method at beginner level.

Explain the same method to an experienced Go developer.

Give me an exercise based on a Ruby idiom I have not demonstrated.

Show how Rails and Hanami differ in their use of this construct.

Show whether use of this Ruby feature has increased over time.

Why might this code use `count` rather than `size`?

Show the evidence behind that explanation.
```

The long-term goal is not a style guide generated from popularity.

It is an **evidence-backed map of the Ruby language and ecosystem that
can teach developers how Ruby works, how Ruby is used, and how to reason
about the choices available to them.**
