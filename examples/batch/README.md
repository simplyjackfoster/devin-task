# Batch example: label every row, resume until nothing is missing

A worked `devin-task` loop for the shape of job the flags were built for: a
long list of rows to process, an output file that must survive a killed pass,
and no idea up front how many passes it will take.

```
input.jsonl   ten sample rows, one JSON object per line, each with an "id"
check.sh      what is still missing; also the --progress counter
run.sh        the loop: chunk the missing ids, hand them to Devin, repeat
dedupe.sh     collapse the duplicate ids a retry leaves behind
```

## Run it

```bash
cd examples/batch
BATCH_OUTPUT=/tmp/out.jsonl ./run.sh      # needs devin-task on PATH
BATCH_OUTPUT=/tmp/out.jsonl ./dedupe.sh   # -> /tmp/out.jsonl.dedup
```

| Env | Default | Meaning |
|---|---|---|
| `BATCH_INPUT` | `input.jsonl` | rows to process; each line a JSON object with an `id` |
| `BATCH_OUTPUT` | `output.jsonl` | append-only results file |
| `BATCH_CHUNK` | `20` | how many missing ids go into one Devin prompt |
| `BATCH_ONLY` | unset | file of ids that narrows `check.sh`'s scope; `run.sh` sets it per chunk |
| `DEVIN_TASK` | `devin-task` | path to the wrapper |

## The three ideas

**The output file is append-only.** The prompt `run.sh` writes tells Devin to
append each result as it finishes it, at least every 20 rows, and never to
rewrite the file. This is the single most important line in the prompt: a pass
that hits the 600-second `--timeout` while holding its whole result in memory
leaves nothing behind, and there is no partial credit. Append-only passes that
were killed or timed out never lost or corrupted a row; they only ever left
duplicates, which `dedupe.sh` collapses by keeping the last copy of each id.

**The check prints what is missing.** `check.sh --missing` lists the ids not
yet in the output, so `--until 'test -z "$(./check.sh --missing)"'` decides
success and the failing check's output goes into the resume prompt — Devin sees
the exact ids it still owes.

**Progress bounds the run, not a pass count.** `check.sh --count` prints how
many *distinct* ids are done, which `--progress './check.sh --count'` reads
after every pass. Distinct matters: a duplicate row appended by a retry must
not look like forward motion. A pass that raises the number resets the stall
counter and the run keeps going however long it takes; five passes in a row
that do not raise it end the run with exit 5.

The settings in `run.sh` — `--max-concurrent 5 --backoff 60 --retries 3
--timeout 1200` — are the ones that ran clean on the free tier for an hour. The
timeout is raised from the default 600 deliberately: at five concurrent, pass
durations for identical work spread 57-904s, and about a quarter exceed 600s —
the default would kill that quarter at exit 124 part-way through a chunk.
Append-only output means even that is survivable, but there is no reason to
invite it. See the throughput table in the top-level
[README](../../README.md#observed-throughput).

## Adapting it

Only `check.sh` knows what a "row" is. Point it at your own notion of done — a
directory of converted files, a database column, a git tag — and keep the two
contracts: `--missing` prints one identifier per line and nothing when
finished, `--count` prints one integer that never goes down. Everything else
carries over unchanged.

## Tests

```bash
bash ../../tests/test_examples_batch.sh
```

Sixteen checks that drive `run.sh` through the real wrapper against a stub
`devin` which appends a few missing rows per call and re-appends one every
other call. No live calls.
