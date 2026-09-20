import { Directory, File, Paths } from 'expo-file-system';
import { Asset } from 'expo-asset';
import liberationSansAsset from '../assets/liberation-sans-regular.ttf';
import { fileUriToPath } from './localFiles';

const fontDirectory = new Directory(Paths.document, 'pdfium-fonts');
const fallbackFont = new File(fontDirectory, 'liberation-sans-regular.ttf');
export const fallbackFontPath = fileUriToPath(fallbackFont.uri);

let installPromise: Promise<string> | null = null;

async function installBundledFont() {
  const asset = Asset.fromModule(liberationSansAsset);
  await asset.downloadAsync();
  const sourceUri = asset.localUri ?? asset.uri;
  if (sourceUri === null) throw new Error('The Liberation Sans font asset was not resolved');
  await new File(sourceUri).copy(fallbackFont, { overwrite: true });
}

export function ensureFallbackFont(): Promise<string> {
  if (installPromise !== null) return installPromise;

  const install = (async () => {
    if (!fontDirectory.exists) fontDirectory.create({ intermediates: true });
    if (fallbackFont.exists) fallbackFont.delete();
    await installBundledFont();
    return fallbackFontPath;
  })();
  installPromise = install.catch((error) => {
    installPromise = null;
    throw error;
  });
  return installPromise;
}
