import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import https from 'node:https'

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const manifestPath = path.join(packageRoot, 'third_party', 'pdfium', 'manifest.json')
const xcframeworkPath = path.join(packageRoot, 'third_party', 'pdfium', 'ios', 'PDFium.xcframework')
const required = process.env.INKSIGN_PDFIUM_IOS_STATIC_REQUIRED === '1'

if (process.platform !== 'darwin') {
  process.exit(0)
}

function hasStaticArchive(filePath) {
  try {
    const magic = fs.readFileSync(filePath).subarray(0, 8).toString('ascii')
    return magic === '!<arch>\n'
  } catch {
    return false
  }
}

function isStaticXCFramework() {
  return [
    'ios-arm64',
    'ios-arm64-simulator',
    'ios-x86_64-simulator',
  ].every((slice) => hasStaticArchive(
    path.join(xcframeworkPath, slice, 'PDFium.framework', 'PDFium'),
  ))
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

function checksumFor(checksumText, assetName) {
  const line = checksumText.split(/\r?\n/).find((candidate) => {
    const trimmed = candidate.trim()
    return trimmed.endsWith(`  ${assetName}`) || trimmed.endsWith(` *${assetName}`)
  })
  return line?.trim().split(/\s+/)[0]?.toLowerCase()
}

async function main() {
  if (isStaticXCFramework()) {
    return
  }

  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  const release = manifest.distribution?.staticRelease
  if (!release?.repository || !release?.tag || !release?.iosAsset || !release?.checksumsAsset) {
    throw new Error('PDFium static iOS release metadata is incomplete')
  }

  const baseUrl = `${release.repository}/releases/download/${release.tag}`
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'inksign-pdfium-'))
  const archivePath = path.join(temporaryDirectory, release.iosAsset)
  const checksumPath = path.join(temporaryDirectory, release.checksumsAsset)
  const extractedPath = path.join(temporaryDirectory, 'extracted')
  fs.mkdirSync(extractedPath)

  await download(`${baseUrl}/${release.iosAsset}`, archivePath)
  await download(`${baseUrl}/${release.checksumsAsset}`, checksumPath)

  const expected = checksumFor(fs.readFileSync(checksumPath, 'utf8'), release.iosAsset)
  const actual = sha256(archivePath)
  if (!expected || expected !== actual) {
    throw new Error(`PDFium iOS checksum mismatch: expected ${expected ?? 'missing'}, got ${actual}`)
  }

  execFileSync('tar', ['-xzf', archivePath, '-C', extractedPath], { stdio: 'inherit' })
  const downloadedXCFramework = path.join(extractedPath, 'PDFium.xcframework')
  if (!isStaticXCFrameworkAt(downloadedXCFramework)) {
    throw new Error('Downloaded PDFium XCFramework is not static or is missing a requested slice')
  }

  const dynamicBackup = path.join(path.dirname(xcframeworkPath), 'PDFium.dynamic.xcframework')
  if (fs.existsSync(xcframeworkPath) && !fs.existsSync(dynamicBackup)) {
    fs.renameSync(xcframeworkPath, dynamicBackup)
  } else {
    fs.rmSync(xcframeworkPath, { recursive: true, force: true })
  }
  fs.renameSync(downloadedXCFramework, xcframeworkPath)
  console.log(`Installed static PDFium iOS XCFramework from ${baseUrl}/${release.iosAsset}`)
}

function isStaticXCFrameworkAt(root) {
  return [
    'ios-arm64',
    'ios-arm64-simulator',
    'ios-x86_64-simulator',
  ].every((slice) => hasStaticArchive(
    path.join(root, slice, 'PDFium.framework', 'PDFium'),
  ))
}

main().catch((error) => {
  if (required) {
    console.error(error)
    process.exitCode = 1
  } else {
    console.warn(`PDFium static iOS download skipped: ${error.message}`)
    console.warn('The experimental dynamic XCFramework remains in use.')
  }
})
