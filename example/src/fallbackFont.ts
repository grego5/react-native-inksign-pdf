import { Image, Platform } from 'react-native';
import RNFS from 'react-native-fs';
import liberationSansAsset from './assets/LiberationSans-Regular.ttf';

export const fallbackFontPath =
  `${RNFS.DocumentDirectoryPath}/pdfium-fonts/LiberationSans-Regular.ttf`;

let installPromise: Promise<string> | null = null;

async function copyBundledFont(destination: string) {
  const asset = Image.resolveAssetSource(liberationSansAsset);
  if (asset === null) throw new Error('The Liberation Sans font asset was not resolved');

  const sourceUri = asset.uri.split('?')[0];
  if (Platform.OS === 'android' && !sourceUri.includes('://')) {
    await RNFS.copyFileRes(`${sourceUri}.ttf`, destination);
    return;
  }

  if (sourceUri.startsWith('file://')) {
    await RNFS.copyFile(decodeURIComponent(sourceUri.slice('file://'.length)), destination);
    return;
  }

  const download = await RNFS.downloadFile({
    fromUrl: sourceUri,
    toFile: destination,
  }).promise;
  if (download.statusCode < 200 || download.statusCode >= 300) {
    throw new Error(`Unable to download the font asset: ${download.statusCode}`);
  }
}

export function ensureFallbackFont(): Promise<string> {
  if (installPromise !== null) return installPromise;

  const fontDirectory = `${RNFS.DocumentDirectoryPath}/pdfium-fonts`;
  const install = (async () => {
    if (!(await RNFS.exists(fontDirectory))) await RNFS.mkdir(fontDirectory);
    await RNFS.unlink(fallbackFontPath).catch(() => undefined);
    await copyBundledFont(fallbackFontPath);
    return fallbackFontPath;
  })();
  installPromise = install.catch(error => {
    installPromise = null;
    throw error;
  });
  return installPromise;
}
