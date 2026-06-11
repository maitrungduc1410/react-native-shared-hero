import { useCallback, useState } from 'react';

/**
 * Imperative helper for in-place (non-navigation) shared-hero transitions.
 *
 * Render two `<SharedHero id="x">` subtrees keyed on `active`; `start()`/
 * `toggle()` swaps which side is mounted, and the library matches the two
 * within a frame to run the flight. Navigation-driven flights need no hook.
 *
 * @example
 * ```tsx
 * const { active, toggle } = useSharedHero();
 * return (
 *   <Pressable onPress={toggle}>
 *     {active ? <ExpandedCard /> : <CollapsedCard />}
 *   </Pressable>
 * );
 * ```
 */
export function useSharedHero(initial = false): {
  active: boolean;
  start: () => void;
  end: () => void;
  toggle: () => void;
} {
  const [active, setActive] = useState(initial);
  const start = useCallback(() => setActive(true), []);
  const end = useCallback(() => setActive(false), []);
  const toggle = useCallback(() => setActive((a) => !a), []);
  return { active, start, end, toggle };
}
