// Required-check gate, matching v1 lib/ci.sh: every required name must be
// present, completed, and concluded "success". Anything else that completed
// (failure, cancelled, timed_out, action_required, and also skipped and
// neutral) counts as failing, because v1 compared the conclusion to
// "success" and nothing else. A required check that was skipped does not
// prove the code is green.

import type { CheckRunFact, CiState } from "./types.js";

export function evaluateCi(checkRuns: CheckRunFact[], required: string[]): CiState {
  if (required.length === 0) return { state: "none" };

  // v1 took the most recently started run per name. GitHub lists the latest
  // run per name first-class (filter=latest), and CheckRunFact carries no
  // timestamps, so the last listed run for a name wins.
  const latest = new Map<string, CheckRunFact>();
  for (const run of checkRuns) latest.set(run.name, run);

  const waitingOn: string[] = [];
  const failing: string[] = [];
  for (const name of required) {
    const run = latest.get(name);
    if (!run || run.status !== "completed") waitingOn.push(name);
    else if (run.conclusion !== "success") failing.push(name);
  }
  // v1 order: missing/running beats failing, so a partly failed suite still
  // waits for its remaining required checks before requesting changes.
  if (waitingOn.length > 0) return { state: "pending", waitingOn };
  if (failing.length > 0) return { state: "failing", failing };
  return { state: "success", checks: [...required] };
}
