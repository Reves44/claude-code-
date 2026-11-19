// useScanHub.js
// One shared hub for the whole app, plus a React hook so any screen
// re-renders the moment a new body scan comes in.
import { useEffect, useState } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage'; // web app: use a localStorage wrapper instead
import { createScanHub } from './scanHub';

export const scanHub = createScanHub(AsyncStorage);
scanHub.load();

export function useScanHub() {
  const [state, setState] = useState(scanHub.getState());
  useEffect(() => scanHub.subscribe(setState), []);
  return state;
}
