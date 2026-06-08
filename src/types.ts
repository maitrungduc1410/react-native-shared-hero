import type { ReactNode } from 'react';
import type { ViewProps } from 'react-native';

/**
 * Transition style for a shared-hero element.
 *
 * - `"snapshot"` (default): cheap clone, translate+scale, crossfade.
 * - `"morph"`: Material container transform — interpolates corner radius and
 *   background colour in addition to bounds.
 * - `"shuttle"`: alias of `snapshot` in v1; reserved for the v2 native portal
 *   that lets you render a custom React subtree mid-flight.
 * - `"zoom"`: iOS 18+ system zoom transition when the navigation context is a
 *   `UINavigationController` push. Falls back to `morph` otherwise.
 * - `"auto"`: picks `zoom` when the platform supports it natively, otherwise
 *   `morph`.
 */
export type SharedHeroMode = 'snapshot' | 'morph' | 'shuttle' | 'zoom' | 'auto';

export type FadeMode = 'cross' | 'in' | 'out' | 'through';

export type MotionPath = 'linear' | 'arc';

export type SpringConfig = {
  damping?: number;
  stiffness?: number;
  mass?: number;
};

export type EasingName =
  | 'linear'
  | 'easeIn'
  | 'easeOut'
  | 'easeInOut'
  | 'standard'
  | 'emphasized';

export type SharedHeroTransitionEvent = {
  id: string;
  namespace: string;
};

export type SharedHeroProps = ViewProps & {
  /**
   * Stable identifier matched across screens. When a SharedHero with the same
   * `id` unmounts and another mounts within ~1 native frame, a flight is run.
   */
  id: string;

  /**
   * Optional namespace, lets you run multiple isolated registries. Defaults to
   * "default".
   */
  namespace?: string;

  /**
   * Transition style.
   * - `"snapshot"` (default): cheap clone, translate+scale+crossfade.
   * - `"morph"`: Material container transform — also interpolates corner
   *   radius, background color and clip shape.
   * - `"shuttle"`: caller supplies a custom React subtree rendered mid-flight.
   */
  mode?: SharedHeroMode;

  /** Animation duration in ms. Ignored when `spring` is set. Default 320 ms. */
  duration?: number;

  /** Optional spring config; overrides `duration`. */
  spring?: SpringConfig;

  /** How source/destination content fade during the flight. Default "cross". */
  fadeMode?: FadeMode;

  /** Easing preset for time-based flights. Default "standard". */
  easing?: EasingName;

  /**
   * Motion path of the flying element's centre.
   * - `"linear"` (default): straight line from source to destination.
   * - `"arc"`: a Material-style curved arc.
   */
  motionPath?: MotionPath;

  /** Disable participation in flights without unmounting. */
  enabled?: boolean;

  /**
   * Whether this hero produces a return (back) flight when it unmounts.
   * Defaults to `true`.
   *
   * Set to `false` for a hero whose dismissal is already a self-contained
   * animation that carries the element away (e.g. a core `<Modal>` that
   * slides DOWN on dismiss). Without this, the library would fire a redundant
   * return-flight when the hero unregisters at the end of that slide, flying a
   * snapshot from the off-screen position back to the source cell. Only the
   * unregister/back-flight path honours this; the inbound (forward) flight is
   * unaffected.
   */
  returnFlightEnabled?: boolean;

  /** Fires on the source view when its outbound flight starts. */
  onTransitionStart?: (e: SharedHeroTransitionEvent) => void;

  /** Fires on the destination view when its inbound flight ends. */
  onTransitionEnd?: (e: SharedHeroTransitionEvent) => void;

  children?: ReactNode;
};
