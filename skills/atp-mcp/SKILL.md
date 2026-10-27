---
name: atp-mcp
description: Use automated theorem provers (E, Vampire, Leo-III, Satallax, Princess, Isabelle/HOL, and the rest of the SystemOnTPTP catalogue) through the atp_mcp MCP server. Use when a claim should be checked rather than argued; to autoformalise natural-language statements, specifications, rules or puzzles into TPTP (CNF, FOF, TFF, THF, modal NXF); to prove or refute conjectures; to find counterexamples or models; to check axioms for consistency; to validate a mathematical or logical argument step by step; or to interpret SZS verdicts such as Theorem, CounterSatisfiable or GaveUp.
---

# Theorem proving with atp_mcp

atp_mcp exposes theorem provers as MCP tools. You write a problem in TPTP,
the standard input language of automated theorem provers. A prover answers
with an **SZS status**: a verdict from a fixed vocabulary that says what was
established (`Theorem`, `CounterSatisfiable`, …) or why nothing was
(`GaveUp`, `Timeout`, …).

A prover's `Theorem` is a machine-checked fact. Your own derivation is only
an argument. Whenever correctness matters more than speed, formalise and ask
a prover.

## Setup

The tools come from the atp_mcp MCP server
(https://github.com/jcschuster/AtpMcp). If tools such as `query_backend`
and `lint_problem` are not available, the server is not connected. Ask the
user to add it to their MCP configuration, for example Claude Code's
`.mcp.json`:

```json
{
  "mcpServers": {
    "atp": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "ghcr.io/jcschuster/atp_mcp:latest"]
    }
  }
}
```

The `latest-isabelle` image tag adds Isabelle/HOL. The server sends
problems to tptp.org for the `sotptp` backend and for TPTP4X linting;
`local_exec` and `isabelle` run locally.

## Tasks this is good for

- **Autoformalisation**: translate a definition, theorem, regulation, access
  policy or puzzle into TPTP, then prove the intended consequences. Failed
  proofs and unexpected countermodels expose mistranslations and ambiguities
  in the source text.
- **Checking a proof**: formalise each step of a proof (yours, the user's or
  a paper's) as a conjecture that follows from the previous steps. The step
  that does not come back `Theorem` is the gap.
- **Refutation and counterexamples**: `CounterSatisfiable` means the
  conjecture does not follow. Model finders such as Paradox and Vampire
  can show the countermodel.
- **Consistency of specifications**: submit only the axioms. `Satisfiable`
  means they have a model; `Unsatisfiable` means they contradict each other.
- **Logic puzzles and constraint problems**: knights and knaves, scheduling,
  "who owns the zebra" style puzzles.
- **Higher-order and modal reasoning**: set-theoretic or functional
  statements in THF; necessity, knowledge or obligation in modal logic (NXF).

## Workflow

1. **Check the setup** (once per session): `list_backends`, then
   `verify_backend` for the backend you plan to use.
2. **Formalise** in the weakest dialect that expresses the problem (see below).
   Give formulas meaningful names; they show up in proofs and errors.
3. **Lint** with `lint_problem` before proving. The local pass is instant;
   the default also runs TPTP4X on SystemOnTPTP. Fix every `error`. The
   `Symbols:` section lists the types you declared, so check that they
   say what you meant.
4. **Prove** with `query_backend` or `run_prover`. Start with a short time
   limit (10–30 s).
5. **Read the verdict** (below). Decide what it means for the original
   question, not just for the formula.
6. **Iterate**: on `CounterSatisfiable` check whether the formalisation is
   missing an axiom before you conclude that the claim is false. On `GaveUp`
   or `Timeout`, try other provers with `compare_provers`, add helpful lemmas,
   or split the conjecture.

## TPTP dialects

Each annotated formula has the form `lang(name, role, formula).`. The
language keyword selects the dialect, and the roles you will use are
`axiom`, `hypothesis`, `definition`, `conjecture` and `type`. Use at most one
`conjecture` per problem. Comments start with `%`.

| Dialect | Keyword | Use for | Provers that handle it |
| --- | --- | --- | --- |
| CNF | `cnf` | Clauses (prover output, SAT-like problems) | E, Vampire, Prover9 |
| FOF | `fof` | Untyped first-order logic with equality: the default | E, Vampire, Prover9; Paradox for models |
| TFF / TF0 | `tff` | Typed first-order logic: sorts, `$int`/`$rat`/`$real` arithmetic | E (no arithmetic), Vampire, Princess |
| TFF / TF1 | `tff` | Adds polymorphic types (`!>[A: $tType]: …`) | Vampire |
| TXF | `tff` | Adds `$ite`, `$let` and boolean terms (FOOL) | Vampire |
| THF / TH0 | `thf` | Higher-order: λ-terms, functions as values, sets as predicates | Leo-III, Satallax, Vampire, E, Zipperpin, Isabelle |
| THF / TH1 | `thf` | Polymorphic higher-order | Leo-III |
| NXF / NHF | `tff` / `thf` plus a `logic` statement | Modal logics K, KD, T, S4, S5, … | Leo-III (embeds into classical HOL) |
| TCF | `tcf` | Typed clause normal form | E |

The prover columns are a guide, not a guarantee. Check `list_provers` for
what SystemOnTPTP offers today. On an unsupported dialect a prover usually
gives no verdict (the tools report "returned no output" or an
`unrecognized_output` error). It can be worse than that: a prover that does
not know an interpreted symbol such as `$ite` or `$sum` may treat it as
uninterpreted and answer `CounterSatisfiable` for a valid conjecture. Use a
prover listed for the dialect, and cross-check surprising refutations with
`compare_provers`.

### Examples

```
% FOF: untyped, variables are uppercase, functions and predicates lowercase
fof(all_humans_mortal, axiom, ! [X] : (human(X) => mortal(X))).
fof(socrates_human, axiom, human(socrates)).
fof(socrates_mortal, conjecture, mortal(socrates)).
```

```
% TF0 with arithmetic: declare every symbol's type before use
tff(c_type, type, c: $int).
tff(succ_bigger, conjecture, $greater($sum(c, 1), c)).
```

```
% TH0: application is @, λ is ^, $o is the type of formulas
thf(p_type, type, p: $i > $o).
thf(excluded_middle, conjecture, ! [X: $i] : ((p @ X) | ~ (p @ X))).
```

```
% NXF: the logic statement fixes the semantics; {$box} and {$dia} are the modalities
tff(s4, logic, $modal == [$designation == $rigid, $domains == $cumulative,
                          $modalities == $modal_system_S4]).
tff(p_type, type, p: $o).
tff(axiom_4, conjecture, ({$box} @ (p)) => ({$box} @ ({$box} @ (p)))).
```

Connectives: `~` not, `&` and, `|` or, `=>` implies, `<=>` iff, `!` for all,
`?` exists, `=` and `!=` for equality. Distinct constants are **not** assumed
unequal. State `a != b` explicitly or use `"double quoted"` distinct objects.

## Tools

| Tool | What it does |
| --- | --- |
| `list_backends` | Backends this server exposes: `sotptp`, `local_exec`, `isabelle`, `starexec` |
| `verify_backend` | Checks a backend's configuration and reachability; returns `OK` or the problem |
| `lint_problem` | Syntax and type diagnostics with line:column, hints and declared symbols. `backends: ["local"]` skips TPTP4X |
| `query_backend` | Runs a TPTP problem on any backend and returns an SZS verdict |
| `list_provers` | Every prover on SystemOnTPTP with its version (`Vampire---5.0.1`) |
| `run_prover` | Runs one SystemOnTPTP prover. A bare name (`"Vampire"`) runs the latest version |
| `compare_provers` | Runs several SystemOnTPTP provers in parallel and lists their verdicts side by side |
| `prove_isabelle` | Checks a hand-written Isabelle/HOL theory |
| `describe_szs` | Full SZS ontology with definitions |

All proving tools accept `raw: true` (except `compare_provers`). It returns
the prover's verbatim output instead of the verdict, including the proof or
model when the prover printed one.

### Backends

- **`sotptp`** (SystemOnTPTP at tptp.org) needs no setup and offers every
  prover and dialect. It needs network access, and your problem is sent to
  tptp.org. `time_limit_sec` applies here. A cancelled call keeps running
  remotely until its time limit, so keep limits short.
- **`local_exec`** runs a local prover (E by default, configurable). It is
  private and fast to start. E handles FOF, CNF and TF0 without arithmetic.
  It handles THF only if it was built with `--enable-ho`; otherwise the
  call fails with a message saying so.
- **`isabelle`** via `query_backend` translates **THF only** into an Isabelle
  theory and tries each conjecture `by auto`. FOF/CNF/TFF input yields
  `GaveUp` because nothing gets translated, which is not a real failed
  proof. For proofs that need more than `auto` (sledgehammer, induction, a
  library theory), write Isabelle directly with `prove_isabelle`. Pass only
  the theory body or a full `theory … imports … begin … end`. The first
  Isabelle call starts the HOL session and can take a minute.
- **`starexec`** runs solvers on a configured StarExec cluster. It needs
  credentials in the server's configuration.

## Reading SZS verdicts

| Verdict | Meaning | What to conclude |
| --- | --- | --- |
| `Theorem` | The conjecture follows from the axioms | Proven, relative to your axioms |
| `CounterSatisfiable` | Some model of the axioms falsifies the conjecture | It does not follow. Check the formalisation first |
| `Unsatisfiable` | No conjecture, and the axioms have no model | The axioms are inconsistent |
| `Satisfiable` | No conjecture, and the axioms have a model | The axioms are consistent |
| `ContradictoryAxioms` | The axioms alone are inconsistent, so the `Theorem` is vacuous | Fix the axioms |
| `GaveUp`, `Timeout`, `ResourceOut`, `MemoryOut` | No answer | **Not** a refutation. Try other provers, more time, or lemmas |
| `InputError`, `SyntaxError`, `TypeError` | The prover rejected the input | Run `lint_problem`, check the dialect fits the prover |

Run `describe_szs` for the complete list.

Two habits catch most formalisation errors:

- **Check the axioms on their own.** Prove the conjecture, then submit the
  axioms without it. `Unsatisfiable` there means every theorem you got was
  vacuous.
- **Try the negation too.** Proving both `C` and `~ C` from the same axioms
  also means they are inconsistent. Proving neither shows that the axioms
  leave the question open.

Every verdict is relative to the formalisation. When you report a result,
show the TPTP you proved so the user can check that it says what they meant.

## Choosing provers

- FOF/CNF: E, then Vampire. Use `compare_provers` with `["E", "Vampire",
  "Prover9"]` when one gives up.
- Arithmetic (TFF with `$int`, `$rat`, `$real`): Vampire, Princess.
- Higher-order (THF): Leo-III, Vampire, Satallax, E.
- Counterexamples and models: Paradox (FOF), Vampire, or E, which all
  report `CounterSatisfiable`/`Satisfiable` when they find a model or
  saturate.
- Modal (NXF/NHF): Leo-III.
- Hard problems: `compare_provers` across several provers. Their strengths
  differ widely, and a short limit on many provers beats a long limit on one.
