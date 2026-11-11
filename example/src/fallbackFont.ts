import { Asset } from 'expo-asset';
import liberationSansAsset from '../assets/liberation-sans-regular.ttf';
import type { AndroidFallbackFont } from '@grego5/react-native-inksign-pdf';

const asset = Asset.fromModule(liberationSansAsset);
export const androidFallbackFont: AndroidFallbackFont = {
  uri: asset.localUri ?? asset.uri,
};
