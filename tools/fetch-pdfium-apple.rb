require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

module InkSignPdfAppleSdk
  module_function

  def command(*arguments)
    output, error, status = Open3.capture3(*arguments)
    raise "PDFium SDK: #{arguments.first} failed: #{error.strip}" unless status.success?
    output
  end

  def valid_sdk?(directory, release)
    stamp = File.join(directory, 'artifact.json')
    return false unless File.file?(stamp)
    return false unless JSON.parse(File.read(stamp)) == identity(release)
    validate_structure(directory)
    true
  rescue JSON::ParserError, KeyError, RuntimeError, Errno::ENOENT
    false
  end

  def identity(release)
    { 'asset' => release.fetch('appleAsset'), 'sha256' => release.fetch('appleAssetSha256') }
  end

  def validate_structure(directory)
    framework = File.join(directory, 'PDFium.xcframework')
    info = JSON.parse(command('/usr/bin/plutil', '-convert', 'json', '-o', '-',
                              File.join(framework, 'Info.plist')))
    libraries = info.fetch('AvailableLibraries')
    device = libraries.find { |entry| entry['SupportedPlatform'] == 'ios' && !entry['SupportedPlatformVariant'] }
    simulator = libraries.find { |entry| entry['SupportedPlatform'] == 'ios' && entry['SupportedPlatformVariant'] == 'simulator' }
    unless device && device.fetch('SupportedArchitectures').include?('arm64') &&
           simulator && %w[arm64 x86_64].all? { |arch| simulator.fetch('SupportedArchitectures').include?(arch) }
      raise 'PDFium SDK: missing iOS device or simulator architecture'
    end
    [device, simulator].each do |entry|
      slice = File.join(framework, entry.fetch('LibraryIdentifier'))
      library = File.join(slice, entry.fetch('LibraryPath'))
      headers = File.join(slice, entry.fetch('HeadersPath'))
      unless File.file?(library) && File.size(library).positive? &&
             %w[fpdfview.h fpdf_text.h fpdf_edit.h fpdf_save.h fpdf_ppo.h].all? { |name| File.file?(File.join(headers, name)) }
        raise 'PDFium SDK: incomplete static library or headers'
      end
    end
    raise 'PDFium SDK: missing license' unless File.file?(File.join(directory, 'LICENSE'))
  end

  def prepare(root)
    manifest = JSON.parse(File.read(File.join(root, 'core/third_party/pdfium/manifest.json')))
    release = manifest.fetch('distribution').fetch('staticRelease')
    cache = File.join(root, 'ios/build/pdfium')
    sdk = File.join(cache, 'sdk')
    FileUtils.mkdir_p(cache)
    File.open(File.join(cache, '.prepare.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      return sdk if valid_sdk?(sdk, release)
      Dir.mktmpdir('prepare-', cache) do |scratch|
        archive = File.join(scratch, release.fetch('appleAsset'))
        url = "#{release.fetch('repository')}/releases/download/#{release.fetch('tag')}/#{release.fetch('appleAsset')}"
        puts "PDFium: downloading #{release.fetch('appleAsset')}"
        command('/usr/bin/curl', '--fail', '--location', '--retry', '2', '--silent', '--show-error',
                '--output', archive, url)
        unless File.size(archive) == release.fetch('appleAssetBytes') &&
               Digest::SHA256.file(archive).hexdigest == release.fetch('appleAssetSha256')
          raise 'PDFium SDK: archive size or SHA-256 mismatch'
        end
        entries = command('/usr/bin/tar', '-tzf', archive).lines.map(&:strip)
        if entries.any? { |name| name.start_with?('/') || name.split('/').include?('..') }
          raise 'PDFium SDK: archive contains an unsafe path'
        end
        extracted = File.join(scratch, 'sdk')
        FileUtils.mkdir_p(extracted)
        command('/usr/bin/tar', '-xzf', archive, '-C', extracted)
        validate_structure(extracted)
        File.write(File.join(extracted, 'artifact.json'), JSON.generate(identity(release)))
        FileUtils.rm_rf(sdk)
        File.rename(extracted, sdk)
      end
    end
    sdk
  end
end
