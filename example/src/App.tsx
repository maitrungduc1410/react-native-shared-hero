import { Platform } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import {
  createNativeStackNavigator,
  type NativeStackNavigationOptions,
} from '@react-navigation/native-stack';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import type { RootStackParamList } from './navigation';
import HomeScreen from './screens/Home';
import BasicImageHeroList from './screens/BasicImageHero/List';
import BasicImageHeroDetail from './screens/BasicImageHero/Detail';
import TextHeroList from './screens/TextHero/List';
import TextHeroDetail from './screens/TextHero/Detail';
import CardMorphList from './screens/CardMorph/List';
import CardMorphDetail from './screens/CardMorph/Detail';
import ModalHeroList from './screens/ModalHero/List';
import ModalHeroDetail from './screens/ModalHero/Detail';
import TransparentModalHeroList from './screens/TransparentModalHero/List';
import TransparentModalHeroDetail from './screens/TransparentModalHero/Detail';
import TabsHeroRoot from './screens/TabsHero/Tabs';
import TabsHeroDetail from './screens/TabsHero/Detail';
import SheetHeroList from './screens/SheetHero/List';
import SheetHeroDetail from './screens/SheetHero/Detail';
import InPlaceToggle from './screens/InPlaceToggle';
import SpringVsDurationList from './screens/SpringVsDuration/List';
import SpringVsDurationDetail from './screens/SpringVsDuration/Detail';
import ArcPathList from './screens/ArcPath/List';
import ArcPathDetail from './screens/ArcPath/Detail';
import CustomShuttleList from './screens/CustomShuttle/List';
import CustomShuttleDetail from './screens/CustomShuttle/Detail';
import GestureReturnList from './screens/GestureReturn/List';
import GestureReturnDetail from './screens/GestureReturn/Detail';
import FlatListHeroList from './screens/FlatListHero/List';
import FlatListHeroDetail from './screens/FlatListHero/Detail';
import MultiStepList from './screens/MultiStep/List';
import MultiStepDetail from './screens/MultiStep/Detail';
import CoreModalHero from './screens/CoreModalHero';

const Stack = createNativeStackNavigator<RootStackParamList>();

// react-native-screens FADE on Android is an XML alpha animation; its
// `onAnimationEnd` at ~150 ms after the fragment transaction commits fires
// `ScreenStackFragment.onViewAnimationEnd()`, which in turn triggers
// `notifyViewAppearTransitionEnd()` + `endRemovalTransition()`. That sequence
// includes a JS event dispatch, a Fabric commit, and the removal of the
// outgoing screen fragment — a single, hot main-thread spike landing right
// around 42% of a 360 ms shared-hero flight. Our overlay animator caps the
// per-frame delta so this stall no longer manifests as a hard "jump", but the
// flight still visibly pauses while the main thread is blocked.
//
// The Android DEFAULT animation (scale 0.85→1 + brief alpha) does NOT exhibit
// this — `SpringVsDuration` (which uses it) is rock smooth. So on Android we
// deliberately fall back to DEFAULT; on iOS we keep FADE because the iOS
// default is a slide-from-right that visually competes with the hero flight.
const heroScreenOptions: NativeStackNavigationOptions = Platform.select({
  ios: {
    headerTransparent: true,
    title: '',
    animation: 'fade',
    animationDuration: 280,
  },
  android: {
    headerTransparent: true,
    title: '',
  },
  default: {
    headerTransparent: true,
    title: '',
    animation: 'fade',
    animationDuration: 280,
  },
}) as NativeStackNavigationOptions;

export default function App() {
  return (
    <SafeAreaProvider>
      <NavigationContainer>
        <Stack.Navigator>
          <Stack.Screen
            name="Home"
            component={HomeScreen}
            options={{ title: 'shared-hero examples' }}
          />
          <Stack.Screen
            name="BasicImageHero"
            component={BasicImageHeroList}
            options={{ title: 'Basic image hero' }}
          />
          <Stack.Screen
            name="BasicImageHeroDetail"
            component={BasicImageHeroDetail}
            options={heroScreenOptions}
          />
          <Stack.Screen
            name="TextHero"
            component={TextHeroList}
            options={{ title: 'Text hero' }}
          />
          <Stack.Screen
            name="TextHeroDetail"
            component={TextHeroDetail}
            options={heroScreenOptions}
          />
          <Stack.Screen
            name="CardMorph"
            component={CardMorphList}
            options={{ title: 'Card morph' }}
          />
          <Stack.Screen
            name="CardMorphDetail"
            component={CardMorphDetail}
            options={heroScreenOptions}
          />
          <Stack.Screen
            name="ModalHero"
            component={ModalHeroList}
            options={{ title: 'Modal hero' }}
          />
          <Stack.Screen
            name="ModalHeroDetail"
            component={ModalHeroDetail}
            options={{ presentation: 'modal', title: '' }}
          />
          <Stack.Screen
            name="TransparentModalHero"
            component={TransparentModalHeroList}
            options={{ title: 'Transparent modal hero' }}
          />
          <Stack.Screen
            name="TransparentModalHeroDetail"
            component={TransparentModalHeroDetail}
            options={{ presentation: 'transparentModal', headerShown: false }}
          />
          <Stack.Screen
            name="TabsHero"
            component={TabsHeroRoot}
            options={{ title: 'Tabs hero' }}
          />
          <Stack.Screen
            name="TabsHeroDetail"
            component={TabsHeroDetail}
            options={heroScreenOptions}
          />
          <Stack.Screen
            name="SheetHero"
            component={SheetHeroList}
            options={{ title: 'Sheet hero' }}
          />
          <Stack.Screen
            name="SheetHeroDetail"
            component={SheetHeroDetail}
            options={{ presentation: 'formSheet', title: '' }}
          />
          <Stack.Screen
            name="InPlaceToggle"
            component={InPlaceToggle}
            options={{ title: 'In-place toggle' }}
          />
          <Stack.Screen
            name="SpringVsDuration"
            component={SpringVsDurationList}
            options={{ title: 'Spring vs duration' }}
          />
          <Stack.Screen
            name="SpringVsDurationDetail"
            component={SpringVsDurationDetail}
            options={{ headerTransparent: true, title: '' }}
          />
          <Stack.Screen
            name="ArcPath"
            component={ArcPathList}
            options={{ title: 'Arc path' }}
          />
          <Stack.Screen
            name="ArcPathDetail"
            component={ArcPathDetail}
            options={{ headerTransparent: true, title: '' }}
          />
          <Stack.Screen
            name="CustomShuttle"
            component={CustomShuttleList}
            options={{ title: 'Custom shuttle' }}
          />
          <Stack.Screen
            name="CustomShuttleDetail"
            component={CustomShuttleDetail}
            options={{ headerTransparent: true, title: '' }}
          />
          <Stack.Screen
            name="GestureReturn"
            component={GestureReturnList}
            options={{ title: 'Gesture return' }}
          />
          <Stack.Screen
            name="GestureReturnDetail"
            component={GestureReturnDetail}
            options={heroScreenOptions}
          />
          <Stack.Screen
            name="FlatListHero"
            component={FlatListHeroList}
            options={{ title: 'FlatList (virtualized)' }}
          />
          <Stack.Screen
            name="FlatListHeroDetail"
            component={FlatListHeroDetail}
            options={heroScreenOptions}
          />
          <Stack.Screen
            name="MultiStep"
            component={MultiStepList}
            options={{ title: 'Multi-step navigation' }}
          />
          <Stack.Screen
            name="MultiStepDetail"
            component={MultiStepDetail}
            options={heroScreenOptions}
          />
          <Stack.Screen
            name="CoreModalHero"
            component={CoreModalHero}
            options={{ title: 'Core Modal (RN)' }}
          />
        </Stack.Navigator>
      </NavigationContainer>
    </SafeAreaProvider>
  );
}
