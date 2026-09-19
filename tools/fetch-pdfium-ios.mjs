import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import https from 'node:https'

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const manifestPath = path.join(packageRoot, 'third_party', 'pdfium', 'manifest.json')
const xcframeworkPath = path.join(packageRoot, 'ios', 'build', 'PDFium.xcframework')

if (process.platform !== 'darwin') {
  process.exit(0)
}

function hasStaticArchive(filePath) {
  try {
    const bytes = fs.readFileSync(filePath)
    if (bytes.subarray(0, 8).toString('ascii') === '!<arch>\n') {
      return true
    }
    if (bytes.length < 8) {
      return false
    }

    const magic = bytes.readUInt32BE(0)
    const is64Bit = magic === 0xcafebabf || magic === 0xbfbafeca
    const isSwapped = magic === 0xbebafeca || magic === 0xbfbafeca
    if (!is64Bit && magic !== 0xcafebabe && magic !== 0xbebafeca) {
      return false
    }

    const readUInt32 = isSwapped
      ? (offset) => bytes.readUInt32LE(offset)
      : (offset) => bytes.readUInt32BE(offset)
    const readOffset = is64Bit
      ? (offset) => Number(isSwapped ? bytes.readBigUInt64LE(offset) : bytes.readBigUInt64BE(offset))
      : readUInt32
    const architectureCount = readUInt32(4)
    const recordSize = is64Bit ? 32 : 20
    if (architectureCount === 0 || 8 + architectureCount * recordSize > bytes.length) {
      return false
    }

    for (let index = 0; index < architectureCount; index += 1) {
      const recordOffset = 8 + index * recordSize
      const sliceOffset = readOffset(recordOffset + 8)
      if (!Number.isSafeInteger(sliceOffset) || sliceOffset < 0 || sliceOffset + 8 > bytes.length ||
          bytes.subarray(sliceOffset, sliceOffset + 8).toString('ascii') !== '!<arch>\n') {
        return false
      }
    }
    return true
  } catch {
    return false
  }
}

function download(url, destination, redirectCount = 0) {
  if (redirectCount > 5) {
    return Promise.reject(new Error(`Too many redirects while downloading ${url}`))
  }
  return new Promise((resolve, reject) => {
    const request = https.get(url, { headers: { 'User-Agent': 'react-native-inksign-pdf-pdfium-fetcher' } }, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        response.resume()
        resolve(download(new URL(response.headers.location, url).toString(), destination, redirectCount + 1))
        return
      }
      if (response.statusCode !== 200) {
        response.resume()
        reject(new Error(`Download failed (${response.statusCode}) for ${url}`))
        return
      }
      const output = fs.createWriteStream(destination)
      response.pipe(output)
      output.on('finish', () => output.close(resolve))
      output.on('error', reject)
    })
    request.on('error', reject)
  })
}

function sha256(filePath) {
  const digest = crypto.createHash('sha256')
  digest.update(fs.readFileSync(filePath))
  return digest.digest('hex')
}

function assertPinnedAsset(filePath, expectedSha256, expectedBytes, label) {
  const actualSha256 = sha256(filePath)
  if (actualSha256 !== expectedSha256?.toLowerCase()) {
    throw new Error(`PDFium ${label} checksum mismatch: expected ${expectedSha256 ?? 'missing'}, got ${actualSha256}`)
  }
  if (expectedBytes != null && fs.statSync(filePath).size !== expectedBytes) {
    throw new Error(`PDFium ${label} size mismatch: expected ${expectedBytes}, got ${fs.statSync(filePath).size}`)
  }
}

function isStaticXCFramework(artifacts) {
  return artifacts.every((artifact) => {
    const relativePath = artifact.packagedLibrary.replace(/^ios\/build\/PDFium\.xcframework[\\/]/, '')
    const binaryPath = path.join(xcframeworkPath, relativePath)
    try {
      return hasStaticArchive(binaryPath) &&
        fs.statSync(binaryPath).size === artifact.packagedLibraryBytes &&
        sha256(binaryPath) === artifact.packagedLibrarySha256.toLowerCase()
    } catch {
      return false
    }
  })
}

function checksumFor(checksumText, assetName) {
  const line = checksumText.split(/\r?\n/).find((candidate) => {
    const trimmed = candidate.trim()
    return trimmed.endsWith(`  ${assetName}`) || trimmed.endsWith(` *${assetName}`)
  })
  return line?.trim().split(/\s+/)[0]?.toLowerCase()
}

async function main() {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  const release = manifest.distribution?.staticRelease
  if (!release?.repository || !release?.tag || !release?.iosAsset || !release?.iosAssetSha256 ||
      !release?.iosAssetBytes || !release?.checksumsAsset || !release?.checksumsAssetSha256) {
    throw new Error('PDFium static iOS release metadata is incomplete')
  }
  const iosArtifacts = release.artifacts?.filter((artifact) => artifact.target === 'ios' && artifact.buildType === 'static') ?? []
  if (iosArtifacts.length === 0) {
    throw new Error('PDFium static iOS artifact metadata is incomplete')
  }
  if (isStaticXCFramework(iosArtifacts)) {
    return
  }

  const baseUrl = `${release.repository}/releases/download/${release.tag}`
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'inksign-pdfium-'))
  const archivePath = path.join(temporaryDirectory, release.iosAsset)
  const checksumPath = path.join(temporaryDirectory, release.checksumsAsset)
  const extractedPath = path.join(temporaryDirectory, 'extracted')
  fs.mkdirSync(extractedPath)

  await download(`${baseUrl}/${release.iosAsset}`, archivePath)
  await download(`${baseUrl}/${release.checksumsAsset}`, checksumPath)

  assertPinnedAsset(checksumPath, release.checksumsAssetSha256, release.checksumsAssetBytes, 'checksum-list')
  assertPinnedAsset(archivePath, release.iosAssetSha256, release.iosAssetBytes, 'iOS archive')

  const listedSha256 = checksumFor(fs.readFileSync(checksumPath, 'utf8'), release.iosAsset)
  if (listedSha256 !== release.iosAssetSha256.toLowerCase()) {
    throw new Error(`PDFium checksum-list entry mismatch: expected ${release.iosAssetSha256}, got ${listedSha256 ?? 'missing'}`)
  }

  execFileSync('tar', ['-xzf', archivePath, '-C', extractedPath], { stdio: 'inherit' })
  const downloadedXCFramework = path.join(extractedPath, 'PDFium.xcframework')
  if (!isStaticXCFrameworkAt(downloadedXCFramework, iosArtifacts)) {
    throw new Error('Downloaded PDFium XCFramework is not static or is missing a requested slice')
  }

  fs.rmSync(xcframeworkPath, { recursive: true, force: true })
  fs.mkdirSync(path.dirname(xcframeworkPath), { recursive: true })
  fs.renameSync(downloadedXCFramework, xcframeworkPath)
  console.log(`Installed static PDFium iOS XCFramework from ${baseUrl}/${release.iosAsset}`)
}

function isStaticXCFrameworkAt(root, artifacts) {
  return artifacts.every((artifact) => {
    const relativePath = artifact.packagedLibrary.replace(/^ios\/build\/PDFium\.xcframework[\\/]/, '')
    const binaryPath = path.join(root, relativePath)
    try {
      return hasStaticArchive(binaryPath) &&
        fs.statSync(binaryPath).size === artifact.packagedLibraryBytes &&
        sha256(binaryPath) === artifact.packagedLibrarySha256.toLowerCase()
    } catch {
      return false
    }
  })
}

main().catch((error) => {
  console.error(`PDFium static iOS installation failed: ${error.message}`)
  process.exitCode = 1
})
