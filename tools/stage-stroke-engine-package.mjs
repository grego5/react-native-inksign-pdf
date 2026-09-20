import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import https from 'node:https'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const supportedAbis = ['arm64-v8a', 'x86_64']
const defaultRepository = 'https://github.com/grego5/react-native-inksign-pdf'

function usage() {
  console.log(`Usage:
  node tools/stage-stroke-engine-package.mjs --release-tag <tag>
    [--release-archive <zip> --checksums <SHA256SUMS>]
    [--release-directory <extracted-release-directory>]
    [--destination <path>] [--repository <url>]
    [--expected-source-revision <sha>] [--expected-ndk-version <version>]
    [--force]

The release archive and checksum list may be supplied locally, or downloaded
from the immutable GitHub release identified by --repository and --release-tag.
`)
}

function parseArguments(argv) {
  const options = {
    destination: path.join(repositoryRoot, 'android', 'stroke-engine'),
    repository: defaultRepository,
    force: false,
  }

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      usage()
      process.exit(0)
    }
    if (argument === '--force') {
      options.force = true
      continue
    }
    if (!argument.startsWith('--')) {
      throw new Error(`Unexpected argument: ${argument}`)
    }
    const value = argv[index + 1]
    if (!value || value.startsWith('--')) {
      throw new Error(`Missing value for ${argument}`)
    }
    index += 1
    const key = argument.slice(2).replaceAll('-', '')
    const names = {
      releasetag: 'releaseTag',
      releasearchive: 'releaseArchive',
      checksums: 'checksums',
      releasedirectory: 'releaseDirectory',
      destination: 'destination',
      repository: 'repository',
      expectedsourcerevision: 'expectedSourceRevision',
      expectedndkversion: 'expectedNdkVersion',
    }
    const optionName = names[key]
    if (!optionName) {
      throw new Error(`Unknown argument: ${argument}`)
    }
    options[optionName] = value
  }

  if (!options.releaseTag) {
    throw new Error('--release-tag is required')
  }
  if (options.releaseArchive && options.releaseDirectory) {
    throw new Error('Use either --release-archive or --release-directory, not both')
  }
  if (options.releaseArchive && !options.checksums) {
    throw new Error('--checksums is required with --release-archive')
  }
  if (options.releaseDirectory && !options.checksums) {
    throw new Error('--checksums is required with --release-directory')
  }
  return options
}

function sha256(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex')
}

function assertFile(filePath, label) {
  if (!fs.statSync(filePath, { throwIfNoEntry: false })?.isFile()) {
    throw new Error(`Missing ${label}: ${filePath}`)
  }
}

function parseChecksums(filePath) {
  assertFile(filePath, 'release checksum list')
  const checksums = new Map()
  for (const line of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const match = line.trim().match(/^([0-9a-fA-F]{64})\s+[* ](.+)$/)
    if (match) checksums.set(path.basename(match[2]), match[1].toLowerCase())
  }
  return checksums
}

function assertChecksum(filePath, expected, label) {
  const actual = sha256(filePath)
  if (actual !== expected) {
    throw new Error(`${label} checksum mismatch: expected ${expected}, got ${actual}`)
  }
}

function download(url, destination, redirectCount = 0) {
  if (redirectCount > 5) return Promise.reject(new Error(`Too many redirects for ${url}`))
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': 'react-native-inksign-pdf-stroke-fetcher' } }, (response) => {
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
    }).on('error', reject)
  })
}

function extractZip(archive, destination) {
  fs.mkdirSync(destination, { recursive: true })
  if (process.platform === 'win32') {
    execFileSync('tar', ['-xf', archive, '-C', destination], { stdio: 'inherit' })
  } else {
    execFileSync('unzip', ['-q', '-o', archive, '-d', destination], { stdio: 'inherit' })
  }
}

function readJson(filePath, label) {
  assertFile(filePath, label)
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'))
  } catch (error) {
    throw new Error(`Invalid ${label}: ${error.message}`)
  }
}

function readExpectedApiVersion() {
  const header = fs.readFileSync(path.join(repositoryRoot, 'cpp', 'StrokeEngineC.h'), 'utf8')
  const match = header.match(/NSE_STROKE_ENGINE_API_VERSION\s+([0-9]+)u?/)
  if (!match) throw new Error('Unable to determine the StrokeEngine C API version')
  return Number(match[1])
}

function readExpectedNdkVersion() {
  const manifest = readJson(path.join(repositoryRoot, 'third_party', 'pdfium', 'manifest.json'), 'PDFium manifest')
  const version = manifest.buildWorkflow?.androidNdk
  if (!version) throw new Error('PDFium manifest does not define the Android NDK version')
  return String(version)
}

function assertRelease(releaseRoot, checksums, options) {
  const manifest = readJson(path.join(releaseRoot, 'manifest.json'), 'stroke-engine release manifest')
  if (manifest.format !== 1 || manifest.releaseTag !== options.releaseTag) {
    throw new Error(`Stroke-engine release manifest does not identify ${options.releaseTag}`)
  }
  if (options.expectedSourceRevision && manifest.sourceRevision !== options.expectedSourceRevision) {
    throw new Error(`Stroke-engine source revision mismatch: expected ${options.expectedSourceRevision}, got ${manifest.sourceRevision}`)
  }
  const expectedNdk = options.expectedNdkVersion ?? readExpectedNdkVersion()
  if (manifest.ndkVersion !== expectedNdk) {
    throw new Error(`Stroke-engine NDK mismatch: expected ${expectedNdk}, got ${manifest.ndkVersion}`)
  }
  const expectedApi = readExpectedApiVersion()
  if (manifest.apiVersion !== expectedApi || manifest.perfettoTrace !== false) {
    throw new Error('Stroke-engine release manifest has an incompatible API or trace policy')
  }

  const artifacts = manifest.artifacts
  if (!Array.isArray(artifacts) || artifacts.length !== supportedAbis.length ||
      supportedAbis.some((abi) => !artifacts.some((artifact) => artifact.abi === abi))) {
    throw new Error(`Stroke-engine release must contain exactly: ${supportedAbis.join(', ')}`)
  }

  for (const abi of supportedAbis) {
    const archiveName = `libinkengine_${abi}.a`
    const archivePath = path.join(releaseRoot, 'android', abi, archiveName)
    const metadataPath = `${archivePath}.json`
    const metadata = readJson(metadataPath, `${abi} metadata`)
    assertFile(archivePath, `${abi} archive`)
    if (metadata.archive !== archiveName || metadata.abi !== abi ||
        metadata.apiVersion !== expectedApi || metadata.ndkVersion !== expectedNdk ||
        metadata.perfettoTrace !== false || metadata.sizeBytes !== fs.statSync(archivePath).size) {
      throw new Error(`${abi} metadata does not match the consumer contract`)
    }
    assertChecksum(archivePath, metadata.sha256, `${abi} archive`)

    const releaseArtifact = artifacts.find((artifact) => artifact.abi === abi)
    if (releaseArtifact.sha256 !== metadata.sha256 || releaseArtifact.sizeBytes !== metadata.sizeBytes ||
        releaseArtifact.sourceRevision !== metadata.sourceRevision) {
      throw new Error(`${abi} release manifest does not match its metadata`)
    }
    const releaseAssetName = `libinkengine_${abi}.a`
    const listedArchiveHash = checksums.get(releaseAssetName)
    if (!listedArchiveHash) {
      throw new Error(`Checksum list has no entry for ${releaseAssetName}`)
    }
    if (listedArchiveHash !== metadata.sha256) {
      throw new Error(`${abi} archive checksum-list entry does not match metadata`)
    }
    const metadataHash = checksums.get(`libinkengine_${abi}.a.json`)
    if (!metadataHash) {
      throw new Error(`Checksum list has no entry for libinkengine_${abi}.a.json`)
    }
    assertChecksum(metadataPath, metadataHash, `${abi} metadata`)
  }

  for (const required of ['THIRD_PARTY_NOTICES.md', 'CREDITS.md', 'GOOGLE_INK_LICENSE', 'ABSEIL_LICENSE']) {
    assertFile(path.join(releaseRoot, required), `release file ${required}`)
  }
  return { manifest, expectedNdk, expectedApi }
}

function copyRelease(releaseRoot, destination, manifest) {
  const stagingDirectory = `${destination}.staging-${process.pid}`
  fs.rmSync(stagingDirectory, { recursive: true, force: true })
  fs.mkdirSync(stagingDirectory, { recursive: true })
  for (const abi of supportedAbis) {
    const abiDirectory = path.join(stagingDirectory, abi)
    fs.mkdirSync(abiDirectory, { recursive: true })
    const archiveName = `libinkengine_${abi}.a`
    fs.copyFileSync(path.join(releaseRoot, 'android', abi, archiveName), path.join(abiDirectory, archiveName))
    fs.copyFileSync(path.join(releaseRoot, 'android', abi, `${archiveName}.json`), path.join(abiDirectory, `${archiveName}.json`))
  }
  fs.mkdirSync(path.join(stagingDirectory, 'licenses'))
  fs.copyFileSync(path.join(releaseRoot, 'THIRD_PARTY_NOTICES.md'), path.join(stagingDirectory, 'THIRD_PARTY_NOTICES.md'))
  fs.copyFileSync(path.join(releaseRoot, 'CREDITS.md'), path.join(stagingDirectory, 'CREDITS.md'))
  fs.copyFileSync(path.join(releaseRoot, 'GOOGLE_INK_LICENSE'), path.join(stagingDirectory, 'licenses', 'GOOGLE_INK_LICENSE'))
  fs.copyFileSync(path.join(releaseRoot, 'ABSEIL_LICENSE'), path.join(stagingDirectory, 'licenses', 'ABSEIL_LICENSE'))
  fs.copyFileSync(path.join(releaseRoot, 'manifest.json'), path.join(stagingDirectory, 'manifest.json'))
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  if (fs.existsSync(destination)) fs.rmSync(destination, { recursive: true, force: true })
  fs.renameSync(stagingDirectory, destination)
  console.log(`Staged stroke-engine release ${manifest.releaseTag} at ${destination}`)
}

async function main() {
  const options = parseArguments(process.argv.slice(2))
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'inksign-stroke-engine-'))
  try {
    let releaseRoot = options.releaseDirectory
    let checksumsPath = options.checksums
    if (!releaseRoot && !options.releaseArchive) {
      const archiveName = `${options.releaseTag}-android-static.zip`
      const archivePath = path.join(temporaryDirectory, archiveName)
      checksumsPath = path.join(temporaryDirectory, 'SHA256SUMS')
      const baseUrl = `${options.repository.replace(/\/$/, '')}/releases/download/${options.releaseTag}`
      await download(`${baseUrl}/${archiveName}`, archivePath)
      await download(`${baseUrl}/SHA256SUMS`, checksumsPath)
      const checksums = parseChecksums(checksumsPath)
      const expectedArchiveHash = checksums.get(archiveName)
      if (!expectedArchiveHash) throw new Error(`Checksum list has no entry for ${archiveName}`)
      assertChecksum(archivePath, expectedArchiveHash, 'stroke-engine release archive')
      releaseRoot = path.join(temporaryDirectory, 'release')
      extractZip(archivePath, releaseRoot)
    } else if (options.releaseArchive) {
      const archivePath = path.resolve(options.releaseArchive)
      assertFile(archivePath, 'stroke-engine release archive')
      releaseRoot = path.join(temporaryDirectory, 'release')
      const checksums = parseChecksums(path.resolve(options.checksums))
      const expectedArchiveHash = checksums.get(path.basename(archivePath))
      if (!expectedArchiveHash) throw new Error(`Checksum list has no entry for ${path.basename(archivePath)}`)
      assertChecksum(archivePath, expectedArchiveHash, 'stroke-engine release archive')
      extractZip(archivePath, releaseRoot)
    }

    const checksums = parseChecksums(path.resolve(checksumsPath))
    const releaseInfo = assertRelease(path.resolve(releaseRoot), checksums, options)
    const destination = path.resolve(options.destination)
    if (fs.existsSync(destination) && !options.force) {
      throw new Error(`Destination exists; pass --force to replace generated artifacts: ${destination}`)
    }
    copyRelease(path.resolve(releaseRoot), destination, releaseInfo.manifest)
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true })
  }
}

main().catch((error) => {
  console.error(`Stroke-engine package staging failed: ${error.message}`)
  process.exitCode = 1
})
