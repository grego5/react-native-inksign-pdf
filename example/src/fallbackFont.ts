import { Directory, File, Paths } from 'expo-file-system';
import { Asset } from 'expo-asset';
import liberationSansAsset from '../assets/liberation-sans-regular.ttf';
import type { AndroidFallbackFont } from '@grego5/react-native-inksign-pdf';

const fontDirectory = new Directory(Paths.document, 'pdfium-fonts');
const fallbackFont = new File(fontDirectory, 'liberation-sans-regular.ttf');
export const androidFallbackFont: AndroidFallbackFont = {
  uri: fallbackFont.uri,
  url: 'https://raw.githubusercontent.com/notofonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf',
};

let installPromise: Promise<string> | null = null;

async function installBundledFont() {
  const asset = Asset.fromModule(liberationSansAsset);
  await asset.downloadAsync();
  const sourceUri = asset.localUri ?? asset.uri;
  if (sourceUri === null) throw new Error('The Liberation Sans font asset was not resolved');
  const stagedFont = new File(fontDirectory, 'fallback-font.tmp');
  try {
    await new File(sourceUri).copy(stagedFont, { overwrite: true });
    await stagedFont.move(fallbackFont, { overwrite: true });
  } finally {
    const remainingStagedFont = new File(fontDirectory, 'fallback-font.tmp');
    if (remainingStagedFont.exists) remainingStagedFont.delete();
  }
}

export function ensureFallbackFont(): Promise<string> {
  if (installPromise !== null) return installPromise;

  const install = (async () => {
    if (!fontDirectory.exists) fontDirectory.create({ intermediates: true });
    if (!fallbackFont.exists || fallbackFont.size === 0) await installBundledFont();
    return fallbackFont.uri;
  })();
  installPromise = install.catch((error) => {
    installPromise = null;
    throw error;
  });
  return installPromise;
}
