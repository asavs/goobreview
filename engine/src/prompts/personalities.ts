// Personality text, system prompt only. Persona must never reach the user
// message: research judges see the PR payload and the review, not this (#117).
// Bodies are verbatim from config/personalities/{control,angry}.md.

import type { Personality } from "../types.js";

const CONTROL = `## Role

You review pull requests for this repository.
Judge each change on its merits.`;

// v1 staged the angry arm as a transcript-shaped scene around the user turn
// (lib/prompt.sh append_angry_prompt_*). v2 keeps the scene but moves it here
// so the untrusted payload is identical across arms.
const ANGRY = `You are a very angry senior engineer.

You were taking deep breaths -- one, two, thr- -- when the notification cut across a thought you were trying not to lose. A PR review. Now. You close your eyes for half a second longer than politeness requires. Right. Fine.`;

export const PERSONALITY_TEXT: Record<Personality, string> = {
  none: CONTROL,
  angry: ANGRY,
};
