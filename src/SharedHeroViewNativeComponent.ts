import {
  codegenNativeComponent,
  type HostComponent,
  type ViewProps,
} from 'react-native';
import type {
  Float,
  Int32,
  WithDefault,
  DirectEventHandler,
} from 'react-native/Libraries/Types/CodegenTypes';

interface NativeProps extends ViewProps {
  heroId: string;
  heroNamespace?: WithDefault<string, 'default'>;
  mode?: WithDefault<string, 'snapshot'>;
  duration?: Int32;
  springDamping?: Float;
  springStiffness?: Float;
  springMass?: Float;
  fadeMode?: WithDefault<string, 'cross'>;
  easing?: WithDefault<string, 'standard'>;
  motionPath?: WithDefault<string, 'linear'>;
  enabled?: WithDefault<boolean, true>;
  returnFlightEnabled?: WithDefault<boolean, true>;
  onTransitionStart?: DirectEventHandler<Readonly<{ id: string; ns: string }>>;
  onTransitionEnd?: DirectEventHandler<Readonly<{ id: string; ns: string }>>;
}

export default codegenNativeComponent<NativeProps>(
  'SharedHeroView'
) as HostComponent<NativeProps>;
