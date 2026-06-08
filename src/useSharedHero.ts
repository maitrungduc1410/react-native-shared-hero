import { useCallback, useState } from 'react';

/**
 * Lightweight imperative helper for in-place shared-hero transitions.
 *
 * Returns `{ active, start, end, toggle }`. Conditionally render two
 * `<SharedHero id="x">` subtrees based on `active`; when you call `start()`
 * or `toggle()`, React unmounts one side and mounts the other and the
 * library auto-detects the match within one frame, animating the flight.
 *
 * For navigation-driven flights, you don't need this hook at all — the
 * library handles it automatically.
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
