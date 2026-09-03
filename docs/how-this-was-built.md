# How this was built

Every line of CodeCat was written by AI agents. The human wrote specs, reviewed
diffs and answered questions; he did not type code. The record of that is still
in the repository, deliberately: `docs/superpowers/specs/` holds the design specs,
`docs/superpowers/plans/` the implementation plans they were broken into, and
`.superpowers/sdd/` the per-task briefs and reports the subagents actually worked
from — including the review diffs. Reading them in order is a fair account of how
the thing was made, mistakes included.

The workflow was spec-first and subagent-driven. Each feature began as a design
spec written with a brainstorming agent and argued over until the *decisions* were
in it — not just the requirements, but why each alternative lost. The spec became
a plan of numbered, independent tasks. Each task went to a fresh subagent with a
brief that assumed no prior context, and came back as a report plus a diff. That
isolation is the point: an agent that has not watched the previous six tasks go by
cannot quietly inherit their assumptions, so a brief that is missing something
fails loudly instead of being papered over. It is also what made the pace
possible — the spec was committed on 28 August at 23:10, the first code 17 minutes
later, a working build existed two days after that, and the repository reached 151
commits in five days.

The expensive lesson was about review. Reviewing each task's diff in isolation
passes work that is individually correct and collectively wrong, and three defects
survived exactly that way: they were each defensible inside their own diff. What
caught them was not more careful reading. It was rendering the actual artefact —
screenshots of the running app, the real sprite sheets measured rather than
trusted, the assembled `.app` inspected instead of the source tree — and comparing
it against ground truth gathered independently. Reasoning about whether code is
right is not the same activity as looking at what it produced, and only the second
one finds this class of bug. The checks that came out of that lesson are still in
the build: `SkinAssetsTests` measures every declared frame against the real PNG,
and `make app` re-runs it against the assembled bundle rather than the sources,
because "it works from `swift run`" and "it works in the app people download" are
different claims.
