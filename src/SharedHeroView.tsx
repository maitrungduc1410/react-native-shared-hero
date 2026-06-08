import { useMemo } from 'react';
import type { NativeSyntheticEvent } from 'react-native';
import NativeSharedHero from './SharedHeroViewNativeComponent';
import type { SharedHeroProps } from './types';

type NativeTransitionEvent = NativeSyntheticEvent<{
  id: string;
  ns: string;
}>;

export function SharedHeroView({
  id,
  namespace = 'default',
  mode = 'snapshot',
  duration,
  spring,
  fadeMode = 'cross',
  easing = 'standard',
  motionPath = 'linear',
  enabled = true,
  returnFlightEnabled = true,
  onTransitionStart,
  onTransitionEnd,
  style,
  children,
  ...rest
}: SharedHeroProps) {
  const startHandler = useMemo(() => {
    if (!onTransitionStart) return undefined;
    return (e: NativeTransitionEvent) =>
      onTransitionStart({ id: e.nativeEvent.id, namespace: e.nativeEvent.ns });
  }, [onTransitionStart]);

  const endHandler = useMemo(() => {
    if (!onTransitionEnd) return undefined;
    return (e: NativeTransitionEvent) =>
      onTransitionEnd({ id: e.nativeEvent.id, namespace: e.nativeEvent.ns });
  }, [onTransitionEnd]);

  return (
    <NativeSharedHero
      {...rest}
      style={style}
      heroId={id}
      heroNamespace={namespace}
      mode={mode}
      duration={duration}
      springDamping={spring?.damping}
      springStiffness={spring?.stiffness}
      springMass={spring?.mass}
      fadeMode={fadeMode}
      easing={easing}
      motionPath={motionPath}
      enabled={enabled}
      returnFlightEnabled={returnFlightEnabled}
      onTransitionStart={startHandler}
      onTransitionEnd={endHandler}
    >
      {children}
    </NativeSharedHero>
  );
}
