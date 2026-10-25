// Persona steering at run time: which steer messages fall due as snapshot
// tool calls complete. The schedule is indexed once, up front; the executor
// reports each completion and queues whatever comes back.

import type { PersonaSteer } from "./types.js";

export interface Steering {
  /** Completed snapshot tool calls counted so far. */
  readonly completed: number;
  /** Count one completed snapshot tool call; returns the messages due at the new count, in persona order. */
  toolCompleted(): string[];
}

export function createSteering(steer: readonly PersonaSteer[]): Steering {
  const due = new Map<number, string[]>();
  for (const s of steer) {
    for (const n of s.afterToolCalls) due.set(n, [...(due.get(n) ?? []), s.text]);
  }
  let completed = 0;
  return {
    get completed() {
      return completed;
    },
    toolCompleted() {
      completed += 1;
      return due.get(completed) ?? [];
    },
  };
}
